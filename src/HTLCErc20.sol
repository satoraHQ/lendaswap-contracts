// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A swap's storage key: keccak256 over all six swap parameters (see
///         `HTLCErc20.computeKey`). One key identifies one swap everywhere —
///         it indexes `swaps` and `preimages` here and is the identifier carried
///         by every lifecycle event.
type SwapKey is bytes32;

/// @title HTLCErc20
/// @notice Hash Time-Locked Contract for trustless ERC20 atomic swaps
/// @dev Uses SHA-256 for preimage hashing to stay compatible with Bitcoin HTLC scripts.
///      Each swap's lifecycle state is kept in storage permanently (None → Active →
///      Redeemed/Refunded), and a redeem also stores the revealed preimage — so an
///      observer can classify a settled swap and recover its preimage with a single
///      state read instead of scanning event logs.
///      All swap parameters must be supplied on redeem/refund and are verified via hash.
///      The `claimAddress` is part of the swap key and only that address can redeem
///      (directly via msg.sender or via EIP-712 signature), preventing front-running.
/// @dev The owner's only powers are `recoverExcessToken` and `recoverEther`.
///      `lockedAmounts` accounts for every token unit owed to an active swap, and
///      `recoverExcessToken` can move only the balance above it, so no owner action
///      can reach swap funds.
contract HTLCErc20 is Ownable2Step {
    using SafeERC20 for IERC20;

    uint8 public constant VERSION = 7;

    // -- EIP-712 --
    //
    // The domain's version string tracks VERSION. Signers must use the same value,
    // or the recovered claimAddress will not match and settlement reverts.

    bytes32 public constant TYPEHASH_REDEEM = keccak256(
        "Redeem(bytes32 preimage,uint256 amount,address token,address sender,uint256 timelock,address caller,address destination,address sweepToken,uint256 minAmountOut,bytes32 callsHash)"
    );

    bytes32 public constant TYPEHASH_REFUND =
        keccak256("Refund(bytes32 preimageHash,uint256 amount,address token,address sender,uint256 timelock)");

    bytes32 public constant TYPEHASH_REHASH = keccak256(
        "Rehash(bytes32 preimageHash,uint256 amount,address token,address sender,uint256 timelock,bytes32 newPreimageHash,uint256 newTimelock)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR = keccak256(
        abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("HTLCErc20"),
            keccak256("7"),
            block.chainid,
            address(this)
        )
    );

    // -- Errors --

    error Reentrancy();

    error ZeroAmount();
    error ZeroClaimAddress();
    error ZeroRefundAddress();
    error ZeroRecipient();
    /// @dev The timelock must already lie in the future at creation…
    error TimelockTooSoon();
    /// @dev …and must have passed before a unilateral refund.
    error TimelockNotExpired();
    /// @dev A rehash may extend the timelock but never shorten it: the claim side keeps
    ///      at least the window it was promised at creation.
    error TimelockShortened();
    /// @dev Recovery found no balance beyond what active swaps are owed.
    error NoExcess();
    error EtherTransferFailed();
    error OwnershipRequired();

    /// @dev Settlement needs the key Active; the state names which lifecycle
    ///      stage the swap is actually in (None = never created, or already
    ///      Redeemed / Refunded).
    error SwapNotActive(SwapKey key, SwapState state);

    /// @dev Creation needs the key unused; the state names what occupies it
    ///      (Active, or a terminal state whose terms are spent).
    error SwapExists(SwapKey key, SwapState state);

    // -- State --

    /// @notice Lifecycle of a swap. Terminal states are never deleted, so a key's
    ///         history stays readable from storage forever. Rehashed is terminal for
    ///         the key, not for the lock: the tokens live on under the new key named
    ///         by the `SwapRehashed` event.
    enum SwapState {
        None,
        Active,
        Redeemed,
        Refunded,
        Rehashed
    }

    /// @dev Swap lifecycle state, by swap key. A key that ever reached a terminal
    ///      state can never be created again: the preimage of a redeemed key is
    ///      public, so a second swap under the same key would be claimable by
    ///      anyone watching the chain.
    mapping(SwapKey => SwapState) public swaps;

    /// @dev Token units owed to active swaps, per token. Rises on create, falls on every
    ///      settlement, so the contract's balance minus this is owed to nobody.
    mapping(address => uint256) public lockedAmounts;

    /// @dev The preimage a redeem revealed, by swap key (the same key as `swaps`).
    ///      Zero until redeemed; the state enum, not this value, is the authority
    ///      on whether a redeem happened.
    mapping(SwapKey => bytes32) public preimages;

    // -- Events --

    /// @dev `key` commits to every swap parameter and is a swap's unique identifier.
    ///      `preimageHash` is not unique — any number of swaps may share one, each with
    ///      its own terms. Consumers must match a swap on `key`, never on `preimageHash`.
    event SwapCreated(
        bytes32 indexed preimageHash,
        address indexed refundAddress,
        address indexed claimAddress,
        address token,
        uint256 amount,
        uint256 timelock,
        SwapKey key
    );

    event SwapRedeemed(bytes32 indexed preimageHash, SwapKey indexed key, bytes32 preimage);

    event SwapRefunded(bytes32 indexed preimageHash, SwapKey indexed key);

    /// @dev The lock under `key` continues under `newKey` with a new hash and timelock;
    ///      amount, token, sender and claimAddress are unchanged. No `SwapCreated` is
    ///      emitted for `newKey` — this is the only record of its origin.
    event SwapRehashed(bytes32 indexed preimageHash, SwapKey indexed key, SwapKey indexed newKey, bytes32 newPreimageHash);

    event ExcessTokenRecovered(address indexed token, address indexed to, uint256 amount);

    event EtherRecovered(address indexed to, uint256 amount);

    // -- Constructor --

    constructor(address initialOwner) Ownable(initialOwner) {}

    // -- Reentrancy guard via transient storage (EIP-1153) --

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(0) {
                mstore(0, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(0, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(0, 0)
        }
    }

    // -- External functions --

    /// @notice Lock ERC20 tokens into a new hash time-locked swap
    /// @dev Convenience wrapper — uses msg.sender as the sender (refund address)
    /// @param preimageHash SHA-256 hash of the secret preimage — an indexed event topic,
    ///                      not an identifier: swaps may share one, and `key` tells them apart
    /// @param amount Token amount to lock (caller must have approved this contract)
    /// @param token ERC20 token address to lock
    /// @param claimAddress Address authorized to redeem the locked tokens
    /// @param timelock Unix timestamp after which the sender can reclaim tokens
    function create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock
    ) external nonReentrant {
        _create(preimageHash, amount, token, msg.sender, claimAddress, timelock);
    }

    /// @notice Lock ERC20 tokens with an explicit refund address
    /// @dev Tokens are always pulled from msg.sender. The refundAddress param controls
    ///      who can call refund — useful for coordinators/routers acting on behalf of a user.
    /// @param preimageHash SHA-256 hash of the secret preimage
    /// @param amount Token amount to lock (caller must have approved this contract)
    /// @param token ERC20 token address to lock
    /// @param refundAddress Address that can refund after timelock (does not have to be msg.sender)
    /// @param claimAddress Address authorized to redeem the locked tokens
    /// @param timelock Unix timestamp after which the refund address can reclaim tokens
    function create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock
    ) external nonReentrant {
        _create(preimageHash, amount, token, refundAddress, claimAddress, timelock);
    }

    /// @notice Redeem tokens by revealing the correct preimage (direct claim)
    /// @dev Only the designated claimAddress can call this — msg.sender is used as
    ///      claimAddress in the key lookup. Tokens are sent to msg.sender.
    /// @param preimage Secret whose SHA-256 hash matches the preimageHash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param sender Address that created the swap
    /// @param timelock Timelock that was set at creation
    function redeem(
        bytes32 preimage,
        uint256 amount,
        address token,
        address sender,
        uint256 timelock
    ) external nonReentrant {
        bytes32 preimageHash = sha256(abi.encodePacked(preimage));

        // msg.sender is used as claimAddress — only the designated address can claim
        SwapKey key = _key(preimageHash, amount, token, sender, msg.sender, timelock);
        SwapState state = swaps[key];
        if (state != SwapState.Active) revert SwapNotActive(key, state);

        swaps[key] = SwapState.Redeemed;
        preimages[key] = preimage;
        lockedAmounts[token] -= amount;

        emit SwapRedeemed(preimageHash, key, preimage);

        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Redeem tokens using an EIP-712 signature from the claimAddress (gasless / delegated)
    /// @dev Anyone can call this function. The claimAddress is recovered from the signature
    ///      which includes msg.sender as the authorized caller, destination, sweepToken,
    ///      minAmountOut, and callsHash. Tokens are sent to msg.sender (not claimAddress).
    ///      All execution parameters are cryptographically bound to the signature, so the
    ///      outcome is guaranteed by the signer regardless of who submits the transaction.
    /// @param preimage Secret whose SHA-256 hash matches the preimageHash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param sender Address that created the swap
    /// @param timelock Timelock that was set at creation
    /// @param destination Address where the caller intends to route tokens after redeem
    /// @param sweepToken Token the caller will sweep to destination (bound to signature)
    /// @param minAmountOut Minimum amount of sweepToken required (bound to signature)
    /// @param callsHash Hash of the calls array (bound to signature, prevents call substitution)
    /// @param v ECDSA recovery id
    /// @param r ECDSA signature component
    /// @param s ECDSA signature component
    /// @return claimAddress The address recovered from the signature
    function redeemBySig(
        bytes32 preimage,
        uint256 amount,
        address token,
        address sender,
        uint256 timelock,
        address destination,
        address sweepToken,
        uint256 minAmountOut,
        bytes32 callsHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (address claimAddress) {
        bytes32 preimageHash = sha256(abi.encodePacked(preimage));

        // Scoped to reduce stack depth: compute digest and recover signer
        {
            bytes32 structHash = keccak256(
                abi.encode(
                    TYPEHASH_REDEEM, preimage, amount, token, sender, timelock,
                    msg.sender, destination, sweepToken, minAmountOut, callsHash
                )
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
            claimAddress = ECDSA.recover(digest, v, r, s);
        }

        SwapKey key = _key(preimageHash, amount, token, sender, claimAddress, timelock);
        SwapState state = swaps[key];
        if (state != SwapState.Active) revert SwapNotActive(key, state);

        swaps[key] = SwapState.Redeemed;
        preimages[key] = preimage;
        lockedAmounts[token] -= amount;

        emit SwapRedeemed(preimageHash, key, preimage);

        // Tokens go to msg.sender (the authorized caller), not claimAddress
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Reclaim tokens after the timelock has expired
    /// @dev Convenience wrapper — tokens are sent back to msg.sender
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param claimAddress Claim address that was set at creation
    /// @param timelock Timelock that was set at creation
    function refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock
    ) external nonReentrant {
        _refund(preimageHash, amount, token, msg.sender, claimAddress, timelock);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Refund an expired swap on the sender's behalf; the tokens go to the sender
    /// @dev Permissionless: anyone may call once the timelock has passed, and the only
    ///      thing the caller decides is to pay the gas. The key names `sender`, and the
    ///      tokens can only go there, so a wrong `sender` addresses a swap that does not
    ///      exist rather than redirecting one that does. Lets a service sweep expired
    ///      locks back to depositors who cannot submit a transaction themselves.
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param sender Sender (refund address) that was set at creation; receives the tokens
    /// @param claimAddress Claim address that was set at creation
    /// @param timelock Timelock that was set at creation
    function refundFor(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) external nonReentrant {
        _refund(preimageHash, amount, token, sender, claimAddress, timelock);
        IERC20(token).safeTransfer(sender, amount);
    }

    /// @notice Reclaim tokens after the timelock has expired, sending to a specified destination
    /// @dev msg.sender must still be the original sender (enforced via the hash).
    ///      Useful for sending tokens to a coordinator/router for further processing.
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param claimAddress Claim address that was set at creation
    /// @param timelock Timelock that was set at creation
    /// @param destination Address to receive the refunded tokens
    function refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address claimAddress,
        uint256 timelock,
        address destination
    ) external nonReentrant {
        _refund(preimageHash, amount, token, msg.sender, claimAddress, timelock);
        IERC20(token).safeTransfer(destination, amount);
    }

    /// @notice Refund before the timelock: the sender calls, the claimAddress signs
    /// @dev Collaborative refund. Both parties consent — the sender by being msg.sender
    ///      (exactly as in `refund`), the claimAddress by an EIP-712 signature over the
    ///      swap terms with `sender = msg.sender`. The signature only waives the timelock;
    ///      it moves nothing on its own. A claimAddress that signs and then calls with
    ///      itself as sender addresses a key it never funded, so it cannot route the
    ///      locked tokens to itself. Tokens go to msg.sender.
    ///      No expiry on the signature, on purpose: it is bound to one key, and that key
    ///      can leave Active exactly once, so every signature over it dies with the first
    ///      settlement that lands.
    /// @param preimageHash The preimage hash used at creation (not the preimage — the
    ///                     sender does not know it)
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param timelock Timelock that was set at creation
    /// @param v ECDSA recovery id
    /// @param r ECDSA signature component
    /// @param s ECDSA signature component
    /// @return claimAddress The address recovered from the signature
    function refundBySig(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        uint256 timelock,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (address claimAddress) {
        {
            bytes32 structHash =
                keccak256(abi.encode(TYPEHASH_REFUND, preimageHash, amount, token, msg.sender, timelock));
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
            claimAddress = ECDSA.recover(digest, v, r, s);
        }

        SwapKey key = _key(preimageHash, amount, token, msg.sender, claimAddress, timelock);
        SwapState state = swaps[key];
        if (state != SwapState.Active) revert SwapNotActive(key, state);

        swaps[key] = SwapState.Refunded;
        lockedAmounts[token] -= amount;

        emit SwapRefunded(preimageHash, key);

        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Replace the hash lock and timelock of an active swap, keeping the tokens locked
    /// @dev Collaborative rehash, consented to exactly like `refundBySig`: the sender by
    ///      being msg.sender, the claimAddress by an EIP-712 signature over the old terms
    ///      (with `sender = msg.sender`) and the new ones. Lets a swap whose far side
    ///      failed (an unpayable Lightning invoice, say) be retried under a fresh hash
    ///      without unwinding the lock. Nothing is transferred and `lockedAmounts` does
    ///      not move: the old key becomes Rehashed and the new key Active, with the same
    ///      amount, token, sender and claimAddress.
    ///      The new timelock must lie in the future, as at creation, and must not be
    ///      shorter than the current one: a rehash never shortens the timelock, so the
    ///      claimAddress keeps at least the claim window it was promised, whatever it
    ///      signed. Equal or later is accepted.
    ///      No `SwapCreated` fires for the new key — consumers follow `SwapRehashed`.
    ///      The new key is taken on a first-come basis like any other: a third party who
    ///      learns the agreed terms can `create` under them first and make this call
    ///      revert with `SwapExists`. That costs them a lock the claimAddress may redeem
    ///      and leaves the original untouched, so the parties simply agree on fresh terms.
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param token Token that was locked
    /// @param timelock Timelock that was set at creation
    /// @param newPreimageHash Preimage hash the lock continues under
    /// @param newTimelock Timelock the lock continues under
    /// @param v ECDSA recovery id
    /// @param r ECDSA signature component
    /// @param s ECDSA signature component
    /// @return claimAddress The address recovered from the signature
    /// @return newKey The key the lock continues under
    function rehash(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        uint256 timelock,
        bytes32 newPreimageHash,
        uint256 newTimelock,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (address claimAddress, SwapKey newKey) {
        if (newTimelock <= block.timestamp) revert TimelockTooSoon();
        if (newTimelock < timelock) revert TimelockShortened();

        {
            bytes32 structHash = keccak256(
                abi.encode(
                    TYPEHASH_REHASH, preimageHash, amount, token, msg.sender, timelock, newPreimageHash, newTimelock
                )
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
            claimAddress = ECDSA.recover(digest, v, r, s);
        }

        SwapKey key = _key(preimageHash, amount, token, msg.sender, claimAddress, timelock);
        SwapState state = swaps[key];
        if (state != SwapState.Active) revert SwapNotActive(key, state);

        newKey = _key(newPreimageHash, amount, token, msg.sender, claimAddress, newTimelock);
        // Same rule as create: a settled key's terms are spent, an active one is taken.
        SwapState newState = swaps[newKey];
        if (newState != SwapState.None) revert SwapExists(newKey, newState);

        swaps[key] = SwapState.Rehashed;
        swaps[newKey] = SwapState.Active;

        emit SwapRehashed(preimageHash, key, newKey, newPreimageHash);
    }

    // -- Owner functions --

    /// @notice Recover the token balance held beyond what active swaps are owed
    /// @dev An ERC20 transfer into this contract cannot be refused, so the balance can
    ///      exceed `lockedAmounts[token]`. Only that difference is movable: the subtraction
    ///      floors at what every active swap is owed, so no call here can reduce the balance
    ///      below the amount its settlements will need.
    /// @param token Token to recover the excess of
    /// @param to Recipient of the recovered tokens
    function recoverExcessToken(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroRecipient();

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 locked = lockedAmounts[token];
        if (balance <= locked) revert NoExcess();

        uint256 excess = balance - locked;

        emit ExcessTokenRecovered(token, to, excess);

        IERC20(token).safeTransfer(to, excess);
    }

    /// @notice Recover ether held by this contract
    /// @dev No function here is payable, so a balance can only come from a force-send
    ///      (selfdestruct, coinbase, or a transfer to the address before deployment). None of
    ///      it belongs to a swap, so the full balance is recoverable.
    /// @param to Recipient of the recovered ether
    function recoverEther(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroRecipient();

        uint256 balance = address(this).balance;
        if (balance == 0) revert NoExcess();

        emit EtherRecovered(to, balance);

        (bool sent,) = to.call{value: balance}("");
        if (!sent) revert EtherTransferFailed();
    }

    /// @dev Disabled: recovery is owner-gated, so an ownerless contract could never release
    ///      a mis-sent balance again. Use `transferOwnership` / `acceptOwnership` instead.
    function renounceOwnership() public pure override {
        revert OwnershipRequired();
    }

    // -- View functions --

    /// @notice Check whether a swap with the given parameters is active
    function isActive(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) external view returns (bool) {
        return swaps[_key(preimageHash, amount, token, sender, claimAddress, timelock)] == SwapState.Active;
    }

    /// @notice A swap's lifecycle state and (if redeemed) its revealed preimage,
    ///         by swap key — one read classifies a settled swap without log scans
    /// @param key The swap key (see `computeKey`, or the `key` field of `SwapCreated`)
    function swapState(SwapKey key) external view returns (SwapState state, bytes32 preimage) {
        return (swaps[key], preimages[key]);
    }

    /// @notice Compute the storage key for a swap from its parameters
    function computeKey(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) external pure returns (SwapKey) {
        return _key(preimageHash, amount, token, sender, claimAddress, timelock);
    }

    // -- Internal --

    function _refund(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) internal {
        if (block.timestamp < timelock) revert TimelockNotExpired();

        SwapKey key = _key(preimageHash, amount, token, sender, claimAddress, timelock);
        SwapState state = swaps[key];
        if (state != SwapState.Active) revert SwapNotActive(key, state);

        swaps[key] = SwapState.Refunded;
        lockedAmounts[token] -= amount;

        emit SwapRefunded(preimageHash, key);
    }

    function _create(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock
    ) internal {
        if (amount == 0) revert ZeroAmount();
        if (timelock <= block.timestamp) revert TimelockTooSoon();
        // Neither party may be address(0). It is the address a failed signature recovery
        // resolves to, so it must never be a claimAddress that a key commits to, and a
        // zero refundAddress could never reclaim the swap once its timelock expires.
        if (claimAddress == address(0)) revert ZeroClaimAddress();
        if (refundAddress == address(0)) revert ZeroRefundAddress();

        SwapKey key = _key(preimageHash, amount, token, refundAddress, claimAddress, timelock);
        // Also rejects settled keys: the key's terms are spent — a redeemed key's
        // preimage is public, so tokens locked under it again would be claimable
        // by anyone. New swaps must use a fresh preimageHash (or other terms).
        SwapState state = swaps[key];
        if (state != SwapState.None) revert SwapExists(key, state);

        swaps[key] = SwapState.Active;
        lockedAmounts[token] += amount;

        emit SwapCreated(preimageHash, refundAddress, claimAddress, token, amount, timelock, key);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Compute the storage key from all swap parameters using assembly for gas efficiency
    function _key(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address refundAddress,
        address claimAddress,
        uint256 timelock
    ) internal pure returns (SwapKey) {
        bytes32 result;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, preimageHash)
            mstore(add(ptr, 0x20), amount)
            mstore(add(ptr, 0x40), token)
            mstore(add(ptr, 0x60), refundAddress)
            mstore(add(ptr, 0x80), claimAddress)
            mstore(add(ptr, 0xa0), timelock)
            result := keccak256(ptr, 0xc0)
        }
        return SwapKey.wrap(result);
    }
}
