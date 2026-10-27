// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeCoordinatorFixture} from "./utils/NativeCoordinatorFixture.sol";
import {HTLCNative} from "../src/HTLCNative.sol";
import {HTLCNativeCoordinator} from "../src/HTLCNativeCoordinator.sol";
import {CallExecutor} from "../src/CallExecutor.sol";

/// @notice A depositor contract with no receive hook. refundTo cannot pay it: the
///         coordinator has no refund path that runs calls, so such a depositor must
///         not lock through it.
contract NonReceivingDepositor {
    HTLCNativeCoordinator immutable c;

    constructor(HTLCNativeCoordinator _c) {
        c = _c;
    }

    function lock(bytes32 h, uint256 amount, address claim, uint256 tl) external payable {
        CallExecutor.Call[] memory calls;
        c.executeAndCreate{value: msg.value}(calls, h, amount, claim, tl);
    }

}

contract HTLCNativeCoordinatorRefundTest is NativeCoordinatorFixture {
    address stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        _lock();
    }

    function test_refundTo_byStranger_paysDepositor() public {
        vm.warp(timelock);
        vm.prank(stranger);
        coordinator.refundTo(preimageHash, amount, bob, timelock);

        assertEq(alice.balance, 10 ether, "alice made whole");
        assertEq(coordinator.deposits(_key(amount)), address(0), "deposit cleared");
        (HTLCNative.SwapState state,) = htlc.swapState(_key(amount));
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Refunded), "refunded");
    }

    function test_refundTo_beforeExpiry_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(HTLCNative.TimelockNotExpired.selector);
        coordinator.refundTo(preimageHash, amount, bob, timelock);
        assertEq(coordinator.deposits(_key(amount)), alice, "deposit intact after revert");
    }

    function test_refundTo_unknownKey_reverts() public {
        vm.warp(timelock);
        vm.expectRevert(HTLCNativeCoordinator.UnknownHtlc.selector);
        coordinator.refundTo(preimageHash, amount + 1, bob, timelock);
    }

    function test_refundTo_twice_reverts() public {
        vm.warp(timelock);
        coordinator.refundTo(preimageHash, amount, bob, timelock);
        vm.expectRevert(HTLCNativeCoordinator.UnknownHtlc.selector);
        coordinator.refundTo(preimageHash, amount, bob, timelock);
    }

    function test_refundAfterRedeem_reverts() public {
        _redeemVia(noCalls, address(0), amount, bob);
        vm.warp(timelock);
        // The redeem cleared the deposit record, so the coordinator rejects
        // the refund before the HTLC would (SwapNotActive).
        vm.expectRevert(HTLCNativeCoordinator.UnknownHtlc.selector);
        coordinator.refundTo(preimageHash, amount, bob, timelock);
    }

    function test_redeemAfterRefund_reverts() public {
        vm.warp(timelock);
        coordinator.refundTo(preimageHash, amount, bob, timelock);
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(0), amount, _callsHash(noCalls));
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, _key(amount), HTLCNative.SwapState.Refunded)
        );
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, noCalls, address(0), amount, bob, v, r, s
        );
    }

    function test_nonReceivableDepositor_refundToReverts() public {
        NonReceivingDepositor nr = new NonReceivingDepositor(coordinator);
        vm.deal(address(nr), 2 ether);
        bytes32 h2 = sha256(abi.encodePacked(bytes32(uint256(0xcafe))));
        nr.lock{value: amount}(h2, amount, bob, timelock);

        vm.warp(timelock);
        vm.prank(stranger);
        vm.expectRevert(HTLCNative.EtherTransferFailed.selector);
        coordinator.refundTo(h2, amount, bob, timelock);
    }
}
