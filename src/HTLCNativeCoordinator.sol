// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CallExecutor} from "./CallExecutor.sol";
import {HTLCNative} from "./HTLCNative.sol";

/// @title HTLCNativeCoordinator
/// @notice Coordinates arbitrary call execution with HTLCNative create and redeem
/// @dev Two flows, mirroring `HTLCCoordinator` for the ERC20 pair:
///   1. executeAndCreate – run arbitrary calls funded by `msg.value`, then lock exactly
///      `amount` of the native coin in an HTLC with the depositor as sender.
///   2. redeemAndExecute – redeem the coin from an HTLC via the claimant's EIP-712
///      signature, run arbitrary calls, then sweep the result to the signed destination.
///   There is no refund flow: the HTLC names the depositor as its sender, so the
///   depositor settles it straight on the HTLC (`refund`, and whatever else the HTLC
///   lets its sender do), and the coordinator keeps no record of the swaps it created.
///   The coordinator holds no long-lived funds and has no owner. Any balance that lands
///   here outside a flow (`receive`) is swept to the next redeemer's destination, and can
///   never become part of a lock.
contract HTLCNativeCoordinator is CallExecutor {
    uint8 public constant VERSION = 2;

    /// @dev Canonical Permit2. This coordinator never uses it, but a call must not be
    ///      able to spend approvals a user may have granted for the ERC20 coordinator.
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // -- Errors --

    /// @dev The calls spent balance that was not part of `msg.value`.
    error CallsOverspent();

    // -- Immutables --

    HTLCNative public immutable HTLC_NATIVE;

    // -- Constructor --

    constructor(address htlcNative) {
        HTLC_NATIVE = HTLCNative(htlcNative);
    }

    // -- External functions --

    /// @notice Run arbitrary calls funded by `msg.value`, then lock exactly `amount` of
    ///         the native coin in an HTLC with the depositor as sender
    /// @dev Sending the value is the authorisation: `msg.sender` is the depositor, and
    ///      `msg.value` is the only input. The calls may spend it (`Call.value`, e.g. a
    ///      DEX swap paid in the coin) and produce native coin; what they may not do is
    ///      touch balance that was here before the call. Whatever they net above
    ///      `amount` is returned to the depositor, so the lock is exact and its key is
    ///      known before the transaction is sent. A plain lock is `calls = []`,
    ///      `amount == msg.value`. The coordinator holds nothing between transactions:
    ///      a token sent here ahead of a call is a stray anyone can sweep, so ERC20
    ///      input is not supported (an atomic smart-account batch is the caller's
    ///      concern, not this contract's).
    ///      The depositor is the HTLC's refund address: the swap key carries `msg.sender`,
    ///      and any refund is the depositor's own call on the HTLC. A contract depositor
    ///      with no receive hook must lock the exact amount (any excess is returned to it)
    ///      and refunds through the HTLC's destination variant.
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

        HTLC_NATIVE.create{value: amount}(preimageHash, msg.sender, claimAddress, timelock);

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
    /// @param htlcSender   The HTLC's sender / refund address (the depositor, for a swap
    ///                     created through this coordinator)
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
        HTLC_NATIVE.redeemBySig(
            preimage, amount, htlcSender, timelock, destination, sweepToken, minAmountOut, callsHash, v, r, s
        );

        _executeCalls(calls);
        _sweep(destination, sweepToken, minAmountOut);
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
