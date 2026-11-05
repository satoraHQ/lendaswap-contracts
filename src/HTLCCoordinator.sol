// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {HTLCErc20} from "./HTLCErc20.sol";

/// @title HTLCCoordinator
/// @notice Coordinates arbitrary call execution with HTLCErc20 create and redeem
/// @dev Two flows:
///   1. executeAndCreate – run arbitrary calls (e.g. DEX swap), then lock the
///      resulting token balance in an HTLC with the depositor as refund address.
///   2. redeemAndExecute – redeem tokens from an HTLC via EIP-712 signature,
///      run arbitrary calls (e.g. DEX swap), then sweep the result to the signed
///      destination. Front-running safe: the HTLC-level signature binds to this
///      coordinator as caller and to the sweep terms.
///   There is no refund flow. The HTLC names the depositor as its sender, so the
///   depositor settles it straight on the HTLC (`refund`, `refundBySig`, and whatever
///   else the HTLC lets its sender do), and the coordinator keeps no record of the
///   swaps it created.
contract HTLCCoordinator {
    using SafeERC20 for IERC20;

    uint8 public constant VERSION = 5;

    bytes32 public constant TYPEHASH_EXECUTE_AND_CREATE = keccak256(
        "ExecuteAndCreate(bytes32 preimageHash,address token,address claimAddress,address refundAddress,uint256 timelock,bytes32 callsHash)"
    );

    string public constant TYPESTRING_EXECUTE_AND_CREATE =
        "ExecuteAndCreate witness)ExecuteAndCreate(bytes32 preimageHash,address token,address claimAddress,address refundAddress,uint256 timelock,bytes32 callsHash)TokenPermissions(address token,uint256 amount)";

    // -- Errors --

    error Reentrancy();

    /// @dev The router's balance is below the required minimum for the operation.
    error InsufficientBalance();
    /// @dev One of the arbitrary calls failed; carries its index in the batch.
    error CallFailed(uint256 index);
    error EtherTransferFailed();
    /// @dev A sweep to address(0) would burn the balance (a native transfer
    ///      there succeeds); a signed or recorded zero destination is a bug.
    error ZeroDestination();
    /// @dev The call targets a contract calls must never touch (HTLC, self, Permit2).
    error RestrictedTarget(address target);
    /// @dev The calldata starts with a transferFrom-family selector that could
    ///      drain third-party approvals.
    error DangerousSelector(bytes4 selector);

    // -- Types --

    /// @param target   Contract address to call
    /// @param value    ETH to forward with the call
    /// @param callData ABI-encoded function calldata
    struct Call {
        address target;
        uint256 value;
        bytes callData;
    }

    // -- Immutables --

    HTLCErc20 public immutable HTLC;
    ISignatureTransfer public immutable PERMIT2;

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

    // -- Constructor --

    constructor(address htlc, address permit2) {
        HTLC = HTLCErc20(htlc);
        PERMIT2 = ISignatureTransfer(permit2);
    }

    // -- External functions --

    /// @notice Pull tokens from depositor via Permit2, execute arbitrary calls, then
    ///         lock the resulting balance in an HTLC with the depositor as sender
    /// @dev The depositor is the HTLC's refund address, so the swap key carries the
    ///      depositor, not this contract: `redeemAndExecute` is passed the depositor as
    ///      `htlcSender`, and any refund is the depositor's own call on the HTLC. The
    ///      Permit2 witness binds `refundAddress = depositor`, so the signer consents to
    ///      exactly that.
    /// @param calls        Arbitrary calls to execute (e.g. DEX swap)
    /// @param preimageHash SHA-256 preimage hash for the HTLC
    /// @param token        Output ERC20 token to lock in the HTLC (e.g. WBTC after a USDC→WBTC swap).
    ///                     The input token is specified in permit.permitted.token.
    /// @param claimAddress Address authorized to redeem the HTLC
    /// @param timelock     Unix timestamp after which a refund is possible
    /// @param depositor    Address whose tokens are pulled via Permit2
    /// @param permit       Permit2 permit data (input token, amount, nonce, deadline)
    /// @param signature    Permit2 signature from the depositor
    function executeAndCreateWithPermit2(
        Call[] calldata calls,
        bytes32 preimageHash,
        address token,
        address claimAddress,
        uint256 timelock,
        address depositor,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        _permit2Transfer(token, preimageHash, claimAddress, depositor, timelock, calls, depositor, permit, signature);

        _executeCalls(calls);

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert InsufficientBalance();

        IERC20(token).forceApprove(address(HTLC), balance);
        HTLC.create(preimageHash, balance, token, depositor, claimAddress, timelock);
    }

    /// @notice Redeem tokens from an HTLC via EIP-712 signature, execute arbitrary
    ///         calls, then sweep the resulting balance to a signed destination
    /// @dev The claimAddress signs an HTLC-level EIP-712 message authorizing this
    ///      coordinator as the caller and binding the destination address. Anyone can
    ///      submit the transaction, but the destination is cryptographically guaranteed
    ///      by the claimAddress's signature. If a malicious submitter changes the
    ///      destination, ecrecover returns the wrong address → swap key mismatch → revert.
    /// @param preimage     Secret that SHA-256 hashes to the HTLC's preimageHash
    /// @param amount       Token amount locked in the HTLC
    /// @param token        ERC20 token locked in the HTLC
    /// @param htlcSender   The HTLC's sender / refund address (the depositor, for a swap
    ///                     created through this coordinator)
    /// @param timelock     Timelock set at HTLC creation
    /// @param calls        Arbitrary calls to execute after redeem (e.g. DEX swap)
    /// @param sweepToken   Token to sweep to the destination (address(0) for ETH)
    /// @param minAmountOut Minimum balance required before sweeping
    /// @param destination  Address to receive swept tokens (signed by claimAddress)
    /// @param v            ECDSA recovery id (HTLC-level signature)
    /// @param r            ECDSA signature component (HTLC-level signature)
    /// @param s            ECDSA signature component (HTLC-level signature)
    function redeemAndExecute(
        bytes32 preimage,
        uint256 amount,
        address token,
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
        // HTLC.redeemBySig recovers claimAddress from the signature and sends tokens
        // to msg.sender (this coordinator). The signature includes address(this) as
        // caller, destination, sweepToken, and minAmountOut — no separate claimAddress
        // check needed, and execution parameters cannot be tampered with.
        bytes32 callsHash = _computeCallsHash(calls);
        HTLC.redeemBySig(preimage, amount, token, htlcSender, timelock, destination, sweepToken, minAmountOut, callsHash, v, r, s);

        _executeCalls(calls);
        _sweep(destination, sweepToken, minAmountOut);
    }

    // -- Internal helpers --

    function _executeCalls(Call[] calldata calls) internal {
        uint256 length = calls.length;
        for (uint256 i = 0; i < length; i++) {
            Call calldata c = calls[i];
            _revertIfRestricted(c.target);
            _revertIfDangerousSelector(c.callData);

            (bool success,) = c.target.call{value: c.value}(c.callData);
            if (!success) revert CallFailed(i);
        }
    }

    function _sweep(address destination, address token, uint256 minAmountOut) internal {
        if (destination == address(0)) revert ZeroDestination();

        uint256 balance;
        if (token == address(0)) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }

        if (balance < minAmountOut) revert InsufficientBalance();
        if (balance == 0) return;

        if (token == address(0)) {
            (bool success,) = payable(destination).call{value: balance}("");
            if (!success) revert EtherTransferFailed();
        } else {
            IERC20(token).safeTransfer(destination, balance);
        }
    }

    function _permit2Transfer(
        address token,
        bytes32 preimageHash,
        address claimAddress,
        address refundAddress,
        uint256 timelock,
        Call[] calldata calls,
        address signer,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) internal {
        bytes32 callsHash = _computeCallsHash(calls);

        bytes32 witness;
        {
            bytes32 typeHash = TYPEHASH_EXECUTE_AND_CREATE;
            assembly ("memory-safe") {
                let ptr := mload(0x40)
                mstore(ptr, typeHash)
                mstore(add(ptr, 0x20), preimageHash)
                mstore(add(ptr, 0x40), token)
                mstore(add(ptr, 0x60), claimAddress)
                mstore(add(ptr, 0x80), refundAddress)
                mstore(add(ptr, 0xa0), timelock)
                mstore(add(ptr, 0xc0), callsHash)
                witness := keccak256(ptr, 0xe0)
                mstore(0x40, add(ptr, 0xe0))
            }
        }

        PERMIT2.permitWitnessTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: permit.permitted.amount}),
            signer,
            witness,
            TYPESTRING_EXECUTE_AND_CREATE,
            signature
        );
    }

    function _computeCallsHash(Call[] calldata calls) internal pure returns (bytes32 callsHash) {
        bytes memory callsData = abi.encode(calls);
        assembly ("memory-safe") {
            callsHash := keccak256(add(callsData, 0x20), mload(callsData))
        }
    }

    /// @dev Defense-in-depth: block transferFrom-family selectors that could drain
    ///      third-party approvals. Even though Permit2 is the primary token-pull
    ///      mechanism, this prevents any residual risk from arbitrary call execution.
    function _revertIfDangerousSelector(bytes calldata callData) internal pure {
        if (callData.length >= 4) {
            bytes4 selector = bytes4(callData[:4]);
            if (
                // ERC-20/721 transferFrom
                selector == bytes4(0x23b872dd)
                // ERC-721 safeTransferFrom(address,address,uint256)
                || selector == bytes4(0x42842e0e)
                // ERC-721 safeTransferFrom(address,address,uint256,bytes)
                || selector == bytes4(0xb88d4fde)
                // ERC-1155 safeTransferFrom
                || selector == bytes4(0xf242432a)
                // ERC-1155 safeBatchTransferFrom
                || selector == bytes4(0x2eb2c2d6)
            ) {
                revert DangerousSelector(selector);
            }
        }
    }

    function _revertIfRestricted(address target) internal view {
        if (target == address(HTLC) || target == address(this) || target == address(PERMIT2)) {
            revert RestrictedTarget(target);
        }
    }

    /// @dev Accept ETH (e.g. from Uniswap refunds or WETH unwrapping)
    receive() external payable {}
}
