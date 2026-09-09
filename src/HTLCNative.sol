// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A swap's storage key: keccak256 over the six words of a swap's terms (see
///         `HTLCNative.computeKey`) — preimage hash, amount, an asset word that is
///         always `address(0)` for the native coin, refund address, claim address and
///         timelock. One key identifies one swap everywhere — it indexes `swaps` and
///         `preimages` here and the coordinator's `deposits`, and is the identifier
///         carried by every lifecycle event.
type SwapKey is bytes32;

/// @title HTLCNative
/// @notice Hash Time-Locked Contract for trustless atomic swaps of the chain's native coin
/// @dev The locked asset is the chain's native coin: the amount is `msg.value` on create
///      and every payout is a plain `call{value:}` with all remaining gas. The swap key
///      reserves an asset word that is always `address(0)`, and the read-only views take
///      it as a `token` argument, so one off-chain key format and one event decoder
///      serve every HTLC of this family; the write paths have no token parameter.
///      Uses SHA-256 for preimage hashing to stay compatible with Bitcoin HTLC scripts.
///      Each swap's lifecycle state is kept in storage permanently (None → Active →
///      Redeemed/Refunded), and a redeem also stores the revealed preimage — so an
///      observer can classify a settled swap and recover its preimage with a single
///      state read instead of scanning event logs.
///      All swap parameters must be supplied on redeem/refund and are verified via hash.
///      The `claimAddress` is part of the swap key and only that address can redeem
///      (directly via msg.sender or via EIP-712 signature), preventing front-running.
/// @dev The owner's only powers are `recoverExcess` and `recoverToken`. `lockedTotal`
///      accounts for every wei owed to an active swap, `recoverExcess` can move only the
///      balance above it, and no swap ever holds a token, so no owner action can reach
///      swap funds. There is no `receive` / `fallback`: the
///      two `create` overloads are the only payable entries, so any balance above
///      `lockedTotal` came from a force-send and belongs to nobody.
contract HTLCNative is Ownable2Step {
    using SafeERC20 for IERC20;

    uint8 public constant VERSION = 1;

    // -- EIP-712 --
    //
    // The domain's version string tracks VERSION. Signers must use the same value,
    // or the recovered claimAddress will not match and settlement reverts.
    // The domain name and the struct shape are specific to this contract, so a
    // signature made for any other HTLC never recovers to the claimant here.

    bytes32 public constant TYPEHASH_REDEEM = keccak256(
        "Redeem(bytes32 preimage,uint256 amount,address sender,uint256 timelock,address caller,address destination,address sweepToken,uint256 minAmountOut,bytes32 callsHash)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR = keccak256(
        abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("HTLCNative"),
            keccak256("1"),
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
    /// @dev Recovery found no balance beyond what active swaps are owed.
    error NoExcess();
    error EtherTransferFailed();
    error OwnershipRequired();
    /// @dev The asset word of a native swap key is always `address(0)`, so a view called
    ///      with any other `token` can never name a swap here.
    error TokenMustBeZero();

    /// @dev Settlement needs the key Active; the state names which lifecycle
    ///      stage the swap is actually in (None = never created, or already
    ///      Redeemed / Refunded).
    error SwapNotActive(SwapKey key, SwapState state);

    /// @dev Creation needs the key unused; the state names what occupies it
    ///      (Active, or a terminal state whose terms are spent).
    error SwapExists(SwapKey key, SwapState state);

    // -- State --

    /// @notice Lifecycle of a swap. Terminal states are never deleted, so a key's
    ///         history stays readable from storage forever.
    enum SwapState {
        None,
        Active,
        Redeemed,
        Refunded
    }

    /// @dev Swap lifecycle state, by swap key. A key that ever reached a terminal
    ///      state can never be created again: the preimage of a redeemed key is
    ///      public, so a second swap under the same key would be claimable by
    ///      anyone watching the chain.
    mapping(SwapKey => SwapState) public swaps;

    /// @dev Wei owed to active swaps. Rises on create, falls on every settlement,
    ///      so the contract's balance minus this is owed to nobody.
    uint256 public lockedTotal;

    /// @dev The preimage a redeem revealed, by swap key (the same key as `swaps`).
    ///      Zero until redeemed; the state enum, not this value, is the authority
    ///      on whether a redeem happened.
    mapping(SwapKey => bytes32) public preimages;

    // -- Events --

    /// @dev `key` commits to every swap parameter and is a swap's unique identifier.
    ///      `preimageHash` is not unique — any number of swaps may share one, each with
    ///      its own terms. Consumers must match a swap on `key`, never on `preimageHash`.
    ///      `token` is always `address(0)`: the native coin has no contract address, and
    ///      the field keeps the event shape shared across this HTLC family.
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

    event ExcessRecovered(address indexed to, uint256 amount);

    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

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

    /// @notice Lock `msg.value` of the native coin into a new hash time-locked swap
    /// @dev Convenience wrapper — uses msg.sender as the sender (refund address)
    /// @param preimageHash SHA-256 hash of the secret preimage — an indexed event topic,
    ///                      not an identifier: swaps may share one, and `key` tells them apart
    /// @param claimAddress Address authorized to redeem the locked coins
    /// @param timelock Unix timestamp after which the sender can reclaim the coins
    function create(bytes32 preimageHash, address claimAddress, uint256 timelock) external payable nonReentrant {
        _create(preimageHash, msg.sender, claimAddress, timelock);
    }

    /// @notice Lock `msg.value` of the native coin with an explicit refund address
    /// @dev The value always comes from msg.sender. The refundAddress param controls
    ///      who can call refund — useful for coordinators/routers acting on behalf of a user.
    /// @param preimageHash SHA-256 hash of the secret preimage
    /// @param refundAddress Address that can refund after timelock (does not have to be msg.sender)
    /// @param claimAddress Address authorized to redeem the locked coins
    /// @param timelock Unix timestamp after which the refund address can reclaim the coins
    function create(bytes32 preimageHash, address refundAddress, address claimAddress, uint256 timelock)
        external
        payable
        nonReentrant
    {
        _create(preimageHash, refundAddress, claimAddress, timelock);
    }

    /// @notice Redeem the coins by revealing the correct preimage (direct claim)
    /// @dev Only the designated claimAddress can call this — msg.sender is used as
    ///      claimAddress in the key lookup. The coins are sent to msg.sender.
    /// @param preimage Secret whose SHA-256 hash matches the preimageHash used at creation
    /// @param amount Amount that was locked
    /// @param sender Address that created the swap
    /// @param timelock Timelock that was set at creation
    function redeem(bytes32 preimage, uint256 amount, address sender, uint256 timelock) external nonReentrant {
        bytes32 preimageHash = sha256(abi.encodePacked(preimage));

        // msg.sender is used as claimAddress — only the designated address can claim
        SwapKey key = _key(preimageHash, amount, sender, msg.sender, timelock);
        SwapState state = swaps[key];
        if (state != SwapState.Active) revert SwapNotActive(key, state);

        swaps[key] = SwapState.Redeemed;
        preimages[key] = preimage;
        lockedTotal -= amount;

        emit SwapRedeemed(preimageHash, key, preimage);

        _pay(msg.sender, amount);
    }

    /// @notice Redeem the coins using an EIP-712 signature from the claimAddress (gasless / delegated)
    /// @dev Anyone may submit this call, but the signature binds `caller` to `msg.sender`,
    ///      so only the address the claimant named can settle with it. The coins are paid
    ///      to that caller unconditionally: `destination`, `sweepToken`, `minAmountOut` and
    ///      `callsHash` are hashed into the signed message so the caller cannot alter them,
    ///      but this contract does not act on them. They are guarantees only when `caller`
    ///      is a contract that enforces them after receiving the coins (the coordinator).
    ///      A signature whose `caller` is an EOA hands the swap amount to that EOA.
    /// @param preimage Secret whose SHA-256 hash matches the preimageHash used at creation
    /// @param amount Amount that was locked
    /// @param sender Address that created the swap
    /// @param timelock Timelock that was set at creation
    /// @param destination Address where the caller intends to route funds after redeem (bound to signature, enforced by `caller`, not here)
    /// @param sweepToken Token the caller will sweep to destination (bound to signature, enforced by `caller`, not here)
    /// @param minAmountOut Minimum amount of sweepToken required (bound to signature, enforced by `caller`, not here)
    /// @param callsHash Hash of the calls array (bound to signature, enforced by `caller`, not here)
    /// @param v ECDSA recovery id
    /// @param r ECDSA signature component
    /// @param s ECDSA signature component
    /// @return claimAddress The address recovered from the signature
    function redeemBySig(
        bytes32 preimage,
        uint256 amount,
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
                    TYPEHASH_REDEEM,
                    preimage,
                    amount,
                    sender,
                    timelock,
                    msg.sender,
                    destination,
                    sweepToken,
                    minAmountOut,
                    callsHash
                )
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
            claimAddress = ECDSA.recover(digest, v, r, s);
        }

        SwapKey key = _key(preimageHash, amount, sender, claimAddress, timelock);
        SwapState state = swaps[key];
        if (state != SwapState.Active) revert SwapNotActive(key, state);

        swaps[key] = SwapState.Redeemed;
        preimages[key] = preimage;
        lockedTotal -= amount;

        emit SwapRedeemed(preimageHash, key, preimage);

        // Coins go to msg.sender (the authorized caller), not claimAddress
        _pay(msg.sender, amount);
    }

    /// @notice Reclaim the coins after the timelock has expired
    /// @dev Convenience wrapper — the coins are sent back to msg.sender
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param claimAddress Claim address that was set at creation
    /// @param timelock Timelock that was set at creation
    function refund(bytes32 preimageHash, uint256 amount, address claimAddress, uint256 timelock)
        external
        nonReentrant
    {
        _refund(preimageHash, amount, claimAddress, timelock);
        _pay(msg.sender, amount);
    }

    /// @notice Reclaim the coins after the timelock has expired, sending to a specified destination
    /// @dev msg.sender must still be the original sender (enforced via the hash).
    ///      Useful for sending the coins to a coordinator/router for further processing,
    ///      or for a sender that cannot itself receive the native coin.
    /// @param preimageHash The preimage hash used at creation
    /// @param amount Amount that was locked
    /// @param claimAddress Claim address that was set at creation
    /// @param timelock Timelock that was set at creation
    /// @param destination Address to receive the refunded coins
    function refund(bytes32 preimageHash, uint256 amount, address claimAddress, uint256 timelock, address destination)
        external
        nonReentrant
    {
        // A native transfer to address(0) succeeds and burns the coins; nothing
        // downstream would reject it, so reject it here.
        if (destination == address(0)) revert ZeroRecipient();
        _refund(preimageHash, amount, claimAddress, timelock);
        _pay(destination, amount);
    }

    // -- Owner functions --

    /// @notice Recover the balance held beyond what active swaps are owed
    /// @dev Nothing here accepts a plain transfer, so the balance can only exceed
    ///      `lockedTotal` through a force-send (selfdestruct, coinbase, or a transfer to the
    ///      address before deployment). Only that difference is movable: the subtraction
    ///      floors at what every active swap is owed, so no call here can reduce the balance
    ///      below the amount its settlements will need.
    /// @param to Recipient of the recovered coins
    function recoverExcess(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroRecipient();

        uint256 balance = address(this).balance;
        uint256 locked = lockedTotal;
        if (balance <= locked) revert NoExcess();

        uint256 excess = balance - locked;

        emit ExcessRecovered(to, excess);

        _pay(to, excess);
    }

    /// @notice Recover ERC20 tokens sent to this contract by mistake
    /// @dev No swap here ever holds a token — the locked asset is the native coin — so
    ///      the full balance of any token belongs to nobody and is movable. An ERC20
    ///      transfer into this contract cannot be refused, hence this escape hatch.
    /// @param token Token to recover
    /// @param to Recipient of the recovered tokens
    function recoverToken(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroRecipient();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NoExcess();

        emit TokenRecovered(token, to, balance);

        IERC20(token).safeTransfer(to, balance);
    }

    /// @dev Disabled: recovery is owner-gated, so an ownerless contract could never release
    ///      a mis-sent balance again. Use `transferOwnership` / `acceptOwnership` instead.
    function renounceOwnership() public pure override {
        revert OwnershipRequired();
    }

    // -- View functions --

    /// @notice Check whether a swap with the given parameters is active
    /// @dev Takes the shared six-word key layout so batch readers work unchanged;
    ///      `token` must be `address(0)`.
    function isActive(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) external view returns (bool) {
        if (token != address(0)) revert TokenMustBeZero();
        return swaps[_key(preimageHash, amount, sender, claimAddress, timelock)] == SwapState.Active;
    }

    /// @notice A swap's lifecycle state and (if redeemed) its revealed preimage,
    ///         by swap key — one read classifies a settled swap without log scans
    /// @param key The swap key (see `computeKey`, or the `key` field of `SwapCreated`)
    function swapState(SwapKey key) external view returns (SwapState state, bytes32 preimage) {
        return (swaps[key], preimages[key]);
    }

    /// @notice Compute the storage key for a swap from its parameters
    /// @dev Takes the shared six-word key layout; `token` must be `address(0)`.
    function computeKey(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) external pure returns (SwapKey) {
        if (token != address(0)) revert TokenMustBeZero();
        return _key(preimageHash, amount, sender, claimAddress, timelock);
    }

    // -- Internal --

    function _refund(bytes32 preimageHash, uint256 amount, address claimAddress, uint256 timelock) internal {
        if (block.timestamp < timelock) revert TimelockNotExpired();

        SwapKey key = _key(preimageHash, amount, msg.sender, claimAddress, timelock);
        SwapState state = swaps[key];
        if (state != SwapState.Active) revert SwapNotActive(key, state);

        swaps[key] = SwapState.Refunded;
        lockedTotal -= amount;

        emit SwapRefunded(preimageHash, key);
    }

    function _create(bytes32 preimageHash, address refundAddress, address claimAddress, uint256 timelock) internal {
        // The amount is exactly what arrived with the call, so the key is known up front.
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();
        if (timelock <= block.timestamp) revert TimelockTooSoon();
        // Neither party may be address(0). It is the address a failed signature recovery
        // resolves to, so it must never be a claimAddress that a key commits to, and a
        // zero refundAddress could never reclaim the swap once its timelock expires.
        if (claimAddress == address(0)) revert ZeroClaimAddress();
        if (refundAddress == address(0)) revert ZeroRefundAddress();

        SwapKey key = _key(preimageHash, amount, refundAddress, claimAddress, timelock);
        // Also rejects settled keys: the key's terms are spent — a redeemed key's
        // preimage is public, so coins locked under it again would be claimable
        // by anyone. New swaps must use a fresh preimageHash (or other terms).
        SwapState state = swaps[key];
        if (state != SwapState.None) revert SwapExists(key, state);

        swaps[key] = SwapState.Active;
        lockedTotal += amount;

        emit SwapCreated(preimageHash, refundAddress, claimAddress, address(0), amount, timelock, key);
    }

    /// @dev Pay out native coin with all remaining gas so contract recipients (smart
    ///      accounts, coordinators) can run their receive hook. Callers have already
    ///      moved the swap to its terminal state and released `lockedTotal`, and the
    ///      reentrancy guard keeps the hook out of every state-changing entry point.
    function _pay(address to, uint256 amount) internal {
        (bool sent,) = to.call{value: amount}("");
        if (!sent) revert EtherTransferFailed();
    }

    /// @dev Compute the storage key from all swap parameters using assembly for gas
    ///      efficiency. Six words: preimageHash, amount, the asset word (always zero
    ///      for the native coin), refundAddress, claimAddress, timelock.
    function _key(bytes32 preimageHash, uint256 amount, address refundAddress, address claimAddress, uint256 timelock)
        internal
        pure
        returns (SwapKey)
    {
        bytes32 result;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, preimageHash)
            mstore(add(ptr, 0x20), amount)
            mstore(add(ptr, 0x40), 0) // asset word: always address(0) for the native coin
            mstore(add(ptr, 0x60), refundAddress)
            mstore(add(ptr, 0x80), claimAddress)
            mstore(add(ptr, 0xa0), timelock)
            result := keccak256(ptr, 0xc0)
        }
        return SwapKey.wrap(result);
    }
}
