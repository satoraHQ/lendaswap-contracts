// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CallExecutor
/// @notice Shared base for coordinators that run a caller-supplied batch of calls
///         around an HTLC settlement and then sweep the resulting balance.
/// @dev Extracted from `HTLCCoordinator` (v4) with unchanged semantics so that every
///      coordinator of the HTLC family executes and sweeps identically. Nothing in
///      here knows which HTLC kind the concrete coordinator wraps: the concrete
///      contract supplies the restricted target set via `_revertIfRestricted` and
///      owns the settlement logic. A single transient-storage reentrancy guard covers
///      all entry points of the concrete contract.
abstract contract CallExecutor {
    using SafeERC20 for IERC20;

    // -- Errors --

    error Reentrancy();

    /// @dev The coordinator's balance is below the required minimum for the operation.
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
    /// @param value    Native coin to forward with the call
    /// @param callData ABI-encoded function calldata
    struct Call {
        address target;
        uint256 value;
        bytes callData;
    }

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

    // -- Internal helpers --

    /// @dev Run every call in order with this contract as `msg.sender`, forwarding
    ///      `Call.value` from this contract's balance. The first failure reverts the
    ///      whole batch with its index.
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

    /// @dev Move this contract's whole balance of `token` (`address(0)` = native coin)
    ///      to `destination`, requiring at least `minAmountOut`. A zero balance that
    ///      satisfies the minimum is a no-op.
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
            _transferNative(destination, balance);
        } else {
            IERC20(token).safeTransfer(destination, balance);
        }
    }

    /// @dev Pay out the native coin with all remaining gas so contract recipients can
    ///      run their receive hook; the reentrancy guard keeps that hook out of every
    ///      entry point of the concrete coordinator.
    function _transferNative(address to, uint256 amount) internal {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert EtherTransferFailed();
    }

    function _computeCallsHash(Call[] calldata calls) internal pure returns (bytes32 callsHash) {
        bytes memory callsData = abi.encode(calls);
        assembly ("memory-safe") {
            callsHash := keccak256(add(callsData, 0x20), mload(callsData))
        }
    }

    /// @dev Defense-in-depth: block transferFrom-family selectors that could drain
    ///      third-party approvals granted to this contract's address.
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

    /// @dev The concrete coordinator names the contracts a call may never target:
    ///      at least its HTLC, itself, and any approval-holding contract it uses.
    function _revertIfRestricted(address target) internal view virtual;
}
