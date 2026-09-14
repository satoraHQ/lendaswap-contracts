// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeCoordinatorFixture} from "./utils/NativeCoordinatorFixture.sol";
import {HTLCNativeCoordinator} from "../src/HTLCNativeCoordinator.sol";
import {CallExecutor} from "../src/CallExecutor.sol";

/// @notice A sweep destination that re-enters the coordinator from its receive hook.
contract ReenteringDestination {
    HTLCNativeCoordinator immutable c;
    bytes32 preimageHash;
    uint256 amount;
    address claim;
    uint256 timelock;

    bool public hookRan;
    bytes4 public reentryError;
    bool public reentrySucceeded;

    constructor(HTLCNativeCoordinator _c) {
        c = _c;
    }

    function arm(bytes32 _h, uint256 _amount, address _claim, uint256 _tl) external {
        preimageHash = _h;
        amount = _amount;
        claim = _claim;
        timelock = _tl;
    }

    receive() external payable {
        hookRan = true;
        try c.refundTo(preimageHash, amount, claim, timelock) {
            reentrySucceeded = true;
        } catch (bytes memory data) {
            reentryError = bytes4(data);
        }
    }
}

/// @notice A call target that re-enters `executeAndCreate` while a lock is in flight.
contract ReenteringTarget {
    HTLCNativeCoordinator immutable c;
    bytes4 public reentryError;
    bool public reentrySucceeded;

    constructor(HTLCNativeCoordinator _c) {
        c = _c;
    }

    function poke(bytes32 h, address claim, uint256 tl) external payable {
        CallExecutor.Call[] memory calls;
        try c.executeAndCreate{value: msg.value}(calls, h, msg.value, claim, tl) {
            reentrySucceeded = true;
        } catch (bytes memory data) {
            reentryError = bytes4(data);
        }
    }
}

contract HTLCNativeCoordinatorEdgeCasesTest is NativeCoordinatorFixture {
    function test_reentryFromSweepDestination_blocked() public {
        // Two locks: one that Bob sweeps to the reenterer, one it tries to refund mid-sweep.
        ReenteringDestination dest = new ReenteringDestination(coordinator);
        bytes32 h2 = sha256(abi.encodePacked(bytes32(uint256(0xcafe))));
        vm.prank(alice);
        coordinator.executeAndCreate{value: amount}(noCalls, h2, amount, bob, timelock);
        dest.arm(h2, amount, bob, timelock);
        _lock();
        vm.warp(timelock);

        _redeemVia(noCalls, address(0), amount, address(dest));

        assertTrue(dest.hookRan(), "hook ran");
        assertFalse(dest.reentrySucceeded(), "reentry blocked");
        assertEq(dest.reentryError(), CallExecutor.Reentrancy.selector, "guard fired");
        assertEq(address(dest).balance, amount, "sweep still paid");
        assertEq(
            coordinator.deposits(htlc.computeKey(h2, amount, address(0), address(coordinator), bob, timelock)),
            alice,
            "other deposit untouched"
        );
        assertEq(coordinator.deposits(_key(amount)), address(0), "settled deposit cleared");
    }

    function test_reentryFromCallTarget_blocked() public {
        ReenteringTarget target = new ReenteringTarget(coordinator);
        CallExecutor.Call[] memory calls = _one(
            CallExecutor.Call({
                target: address(target),
                value: 0.1 ether,
                callData: abi.encodeWithSelector(ReenteringTarget.poke.selector, preimageHash, bob, timelock)
            })
        );

        // The inner lock fails; the value the target received stays with it, so the
        // outer lock is short by 0.1 and fails too. Nothing is locked.
        vm.prank(alice);
        vm.expectRevert(CallExecutor.InsufficientBalance.selector);
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
    }

    function test_reentryFromCallTarget_guardFires() public {
        ReenteringTarget target = new ReenteringTarget(coordinator);
        CallExecutor.Call[] memory calls = _one(
            CallExecutor.Call({
                target: address(target),
                value: 0.1 ether,
                callData: abi.encodeWithSelector(ReenteringTarget.poke.selector, preimageHash, bob, timelock)
            })
        );

        vm.prank(alice);
        coordinator.executeAndCreate{value: amount + 0.1 ether}(calls, preimageHash, amount, bob, timelock);

        assertFalse(target.reentrySucceeded(), "reentry blocked");
        assertEq(target.reentryError(), CallExecutor.Reentrancy.selector, "guard fired");
        assertTrue(_isActive(amount), "outer lock landed");
    }

    function test_receive_acceptsPlainTransfers() public {
        vm.prank(alice);
        (bool ok,) = address(coordinator).call{value: 1}("");
        assertTrue(ok, "receive open");
        assertEq(address(coordinator).balance, 1);
    }

    function test_constants() public view {
        assertEq(coordinator.VERSION(), 1);
        assertEq(address(coordinator.HTLC_NATIVE()), address(htlc));
        assertEq(coordinator.PERMIT2(), 0x000000000022D473030F116dDEE9F6B43aC78BA3);
    }
}
