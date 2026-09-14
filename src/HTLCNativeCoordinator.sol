// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CallExecutor} from "./CallExecutor.sol";
import {HTLCNative, SwapKey} from "./HTLCNative.sol";

/// @title HTLCNativeCoordinator
/// @notice Coordinates arbitrary call execution with HTLCNative create, redeem and refund
/// @dev Three primary flows, mirroring `HTLCCoordinator` for the ERC20 pair:
///   1. executeAndCreate – run arbitrary calls funded by `msg.value`, then lock exactly
///      `amount` of the native coin in an HTLC with the coordinator as sender.
///   2. redeemAndExecute – redeem the coin from an HTLC via the claimant's EIP-712
///      signature, run arbitrary calls, then sweep the result to the signed destination.
///   3. refundAndExecute / refundTo – refund an expired HTLC created via this coordinator
///      to the original depositor, optionally through arbitrary calls.
///   The coordinator holds no long-lived funds and has no owner. Any balance that lands
///   here outside a flow (`receive`) is swept to the next redeemer's destination, and can
///   never become part of a lock.
contract HTLCNativeCoordinator is CallExecutor {
    uint8 public constant VERSION = 1;

    /// @dev Canonical Permit2. This coordinator never uses it, but a call must not be
    ///      able to spend approvals a user may have granted for the ERC20 coordinator.
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // -- Errors --

    /// @dev No deposit is recorded for this HTLC key.
    error UnknownHtlc();
    /// @dev msg.sender is not the recorded depositor.
    error Unauthorized();
    /// @dev The calls spent balance that was not part of `msg.value`.
    error CallsOverspent();

    // -- Immutables --

    HTLCNative public immutable HTLC_NATIVE;

    // -- Storage --

    /// @dev Maps HTLC swap key -> original depositor address.
    ///      Populated by executeAndCreate, used by refundAndExecute / refundTo.
    mapping(SwapKey => address) public deposits;

    // -- Constructor --

    constructor(address htlcNative) {
        HTLC_NATIVE = HTLCNative(htlcNative);
    }

    // -- External functions --

    /// @notice Run arbitrary calls funded by `msg.value`, then lock exactly `amount` of
    ///         the native coin in an HTLC with the coordinator as sender
    /// @dev Sending the value is the authorisation: `msg.sender` is the depositor. The
    ///      calls may consume `msg.value` (`Call.value`) and produce native coin (e.g. a
    ///      DEX swap or a WRBTC unwrap); what they may not do is touch balance that was
    ///      here before the call. Whatever they net above `amount` is returned to the
    ///      depositor, so the lock is exact and its key is known before the transaction
    ///      is sent. A plain lock is `calls = []`, `amount == msg.value`.
    ///      If the swap expires, only the depositor can call refundAndExecute; refundTo
    ///      is permissionless but always pays the depositor.
    /// @param calls        Arbitrary calls to execute before the lock
    /// @param preimageHash SHA-256 preimage hash for the HTLC
    /// @param amount       Exact amount of the native coin to lock
    /// @param claimAddress Address authorized to redeem the HTLC
    /// @param timelock     Unix timestamp after which a refund is possible
    function executeAndCreate(
        Call[] calldata calls,
        bytes32 preimageHash,
        uint256 amount,
        address claimAddress,
        uint256 timelock
    ) external payable nonReentrant {
        // msg.value is already part of the balance here, so this cannot underflow;
        // what it leaves is the stray balance, excluded from the accounting.
        uint256 before = address(this).balance - msg.value;

        _executeCalls(calls);

        uint256 after_ = address(this).balance;
        if (after_ < before) revert CallsOverspent();
        uint256 received = after_ - before;
        if (received < amount) revert InsufficientBalance();

        HTLC_NATIVE.create{value: amount}(preimageHash, claimAddress, timelock);

        SwapKey key = HTLC_NATIVE.computeKey(preimageHash, amount, address(0), address(this), claimAddress, timelock);
        deposits[key] = msg.sender;

        if (received > amount) {
            _transferNative(msg.sender, received - amount);
        }
    }

    /// @notice Redeem the coin from an HTLC via EIP-712 signature, execute arbitrary
    ///         calls, then sweep the resulting balance to a signed destination
    /// @dev The claimAddress signs an HTLC-level EIP-712 message authorizing this
    ///      coordinator as the caller and binding the destination, sweep token, minimum
    ///      and calls. Anyone can submit the transaction; a submitter that alters any of
    ///      them recovers a different signer, so the swap key does not match and the
    ///      HTLC reverts. Extra `msg.value` from the submitter funds `Call.value`.
    /// @param preimage     Secret that SHA-256 hashes to the HTLC's preimageHash
    /// @param amount       Amount locked in the HTLC
    /// @param htlcSender   Address that created the HTLC
    /// @param timelock     Timelock set at HTLC creation
    /// @param calls        Arbitrary calls to execute after redeem (e.g. wrap, DEX swap)
    /// @param sweepToken   Token to sweep to the destination (address(0) for the native coin)
    /// @param minAmountOut Minimum balance required before sweeping
    /// @param destination  Address to receive the swept balance (signed by claimAddress)
    /// @param v            ECDSA recovery id (HTLC-level signature)
    /// @param r            ECDSA signature component (HTLC-level signature)
    /// @param s            ECDSA signature component (HTLC-level signature)
    function redeemAndExecute(
        bytes32 preimage,
        uint256 amount,
        address htlcSender,
        uint256 timelock,
        Call[] calldata calls,
        address sweepToken,
        uint256 minAmountOut,
        address destination,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable nonReentrant {
        // HTLC_NATIVE.redeemBySig recovers claimAddress from the signature and pays
        // msg.sender (this coordinator). The signature covers address(this) as caller,
        // destination, sweepToken, minAmountOut and callsHash, so no separate check
        // is needed here and the execution parameters cannot be tampered with.
        bytes32 callsHash = _computeCallsHash(calls);
        address claimAddress = HTLC_NATIVE.redeemBySig(
            preimage, amount, htlcSender, timelock, destination, sweepToken, minAmountOut, callsHash, v, r, s
        );

        // A swap this coordinator created is settled now; drop its deposit
        // record so `deposits` only ever names unsettled swaps.
        if (htlcSender == address(this)) {
            bytes32 preimageHash = sha256(abi.encodePacked(preimage));
            delete deposits[
                HTLC_NATIVE.computeKey(preimageHash, amount, address(0), address(this), claimAddress, timelock)
            ];
        }

        _executeCalls(calls);
        _sweep(destination, sweepToken, minAmountOut);
    }

    /// @notice Refund an expired HTLC created via this coordinator, execute arbitrary
    ///         calls, then sweep to the original depositor
    /// @dev Restricted to the original depositor: the calls run with the coordinator as
    ///      msg.sender, so only the party whose funds are at stake may choose them.
    ///      This is the escape hatch for a depositor that cannot receive the native
    ///      coin (wrap it, sweep the ERC20). For a permissionless refund use refundTo.
    /// @param preimageHash The preimage hash used at HTLC creation
    /// @param amount       Amount locked in the HTLC
    /// @param claimAddress Claim address set at HTLC creation
    /// @param timelock     Timelock set at HTLC creation
    /// @param calls        Arbitrary calls to execute after refund
    /// @param sweepToken   Token to sweep to the depositor (address(0) for the native coin)
    /// @param minAmountOut Minimum balance required before sweeping
    function refundAndExecute(
        bytes32 preimageHash,
        uint256 amount,
        address claimAddress,
        uint256 timelock,
        Call[] calldata calls,
        address sweepToken,
        uint256 minAmountOut
    ) external nonReentrant {
        SwapKey key = HTLC_NATIVE.computeKey(preimageHash, amount, address(0), address(this), claimAddress, timelock);
        address depositor = deposits[key];
        if (depositor == address(0)) revert UnknownHtlc();
        if (msg.sender != depositor) revert Unauthorized();

        delete deposits[key];

        HTLC_NATIVE.refund(preimageHash, amount, claimAddress, timelock);

        if (calls.length > 0) {
            _executeCalls(calls);
        }

        _sweep(depositor, sweepToken, minAmountOut);
    }

    /// @notice Refund an expired coordinator-created HTLC straight to the original depositor
    /// @dev Permissionless: anyone can trigger this after timelock expiry, the coin
    ///      always goes to the depositor regardless of who calls.
    /// @param preimageHash The preimage hash used at HTLC creation
    /// @param amount       Amount locked in the HTLC
    /// @param claimAddress Claim address set at HTLC creation
    /// @param timelock     Timelock set at HTLC creation
    function refundTo(bytes32 preimageHash, uint256 amount, address claimAddress, uint256 timelock)
        external
        nonReentrant
    {
        SwapKey key = HTLC_NATIVE.computeKey(preimageHash, amount, address(0), address(this), claimAddress, timelock);
        address depositor = deposits[key];
        if (depositor == address(0)) revert UnknownHtlc();

        delete deposits[key];

        HTLC_NATIVE.refund(preimageHash, amount, claimAddress, timelock, depositor);
    }

    // -- Internal --

    function _revertIfRestricted(address target) internal view override {
        if (target == address(HTLC_NATIVE) || target == address(this) || target == PERMIT2) {
            revert RestrictedTarget(target);
        }
    }

    /// @dev Accept the native coin: HTLC payouts, DEX refunds, WRBTC unwraps and
    ///      anything else sent here. Nothing received outside a flow is ever locked.
    receive() external payable {}
}
