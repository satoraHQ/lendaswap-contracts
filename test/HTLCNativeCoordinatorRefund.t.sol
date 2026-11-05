// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeCoordinatorFixture} from "./utils/NativeCoordinatorFixture.sol";
import {HTLCNative} from "../src/HTLCNative.sol";
import {HTLCNativeCoordinator} from "../src/HTLCNativeCoordinator.sol";
import {CallExecutor} from "../src/CallExecutor.sol";

/// @notice A depositor contract with no receive hook. It is the HTLC sender of what it
///         locks, so it refunds through the HTLC's destination variant.
contract NonReceivingDepositor {
    HTLCNativeCoordinator immutable c;
    HTLCNative immutable h;

    constructor(HTLCNativeCoordinator _c, HTLCNative _h) {
        c = _c;
        h = _h;
    }

    function lock(bytes32 hash, uint256 amount, address claim, uint256 tl) external payable {
        CallExecutor.Call[] memory calls;
        c.executeAndCreate{value: msg.value}(calls, hash, amount, claim, tl);
    }

    function refund(bytes32 hash, uint256 amount, address claim, uint256 tl) external {
        h.refund(hash, amount, claim, tl);
    }

    function refundTo(bytes32 hash, uint256 amount, address claim, uint256 tl, address to) external {
        h.refund(hash, amount, claim, tl, to);
    }
}

/// @notice A swap locked through the coordinator is refunded on the HTLC by the
///         depositor, who is its sender. The coordinator has no refund path.
contract HTLCNativeCoordinatorRefundTest is NativeCoordinatorFixture {
    address stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        _lock();
    }

    function test_depositorRefundsOnTheHtlc() public {
        vm.warp(timelock);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, bob, timelock);

        assertEq(alice.balance, 10 ether, "alice made whole");
        (HTLCNative.SwapState state,) = htlc.swapState(_key(amount));
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Refunded), "refunded");
    }

    function test_refundBeforeExpiry_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCNative.TimelockNotExpired.selector);
        htlc.refund(preimageHash, amount, bob, timelock);
        assertTrue(_isActive(amount), "still locked");
    }

    function test_strangerCannotRefund() public {
        vm.warp(timelock);
        vm.prank(stranger);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refund(preimageHash, amount, bob, timelock);
        assertTrue(_isActive(amount), "still locked");
    }

    /// `refundFor` on a coordinator-created swap pays the depositor; naming the
    /// coordinator as sender addresses a key that was never created.
    function test_refundFor_paysTheDepositor() public {
        vm.warp(timelock);
        vm.prank(stranger);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refundFor(preimageHash, amount, address(coordinator), bob, timelock);

        vm.prank(stranger);
        htlc.refundFor(preimageHash, amount, alice, bob, timelock);

        assertEq(alice.balance, 10 ether, "alice made whole");
        assertEq(address(coordinator).balance, 0, "nothing landed in the coordinator");
    }

    function test_coordinatorIsNotTheSender() public {
        vm.warp(timelock);
        vm.prank(address(coordinator));
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refund(preimageHash, amount, bob, timelock);
    }

    function test_refundAfterRedeem_reverts() public {
        _redeemVia(noCalls, address(0), amount, bob);
        vm.warp(timelock);
        bytes memory err =
            abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, _key(amount), HTLCNative.SwapState.Redeemed);
        vm.prank(alice);
        vm.expectRevert(err);
        htlc.refund(preimageHash, amount, bob, timelock);
    }

    function test_redeemAfterRefund_reverts() public {
        vm.warp(timelock);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, bob, timelock);
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(0), amount, _callsHash(noCalls));
        bytes memory err =
            abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, _key(amount), HTLCNative.SwapState.Refunded);
        vm.prank(relayer);
        vm.expectRevert(err);
        coordinator.redeemAndExecute(preimage, amount, alice, timelock, noCalls, address(0), amount, bob, v, r, s);
    }

    function test_nonReceivableDepositor_refundsToADestination() public {
        NonReceivingDepositor nr = new NonReceivingDepositor(coordinator, htlc);
        vm.deal(address(nr), 2 ether);
        bytes32 h2 = sha256(abi.encodePacked(bytes32(uint256(0xcafe))));
        nr.lock{value: amount}(h2, amount, bob, timelock);

        vm.warp(timelock);
        vm.expectRevert(HTLCNative.EtherTransferFailed.selector);
        nr.refund(h2, amount, bob, timelock);

        nr.refundTo(h2, amount, bob, timelock, stranger);
        assertEq(stranger.balance, amount, "paid where the contract pointed");
    }
}
