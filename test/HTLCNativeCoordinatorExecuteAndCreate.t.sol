// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeCoordinatorFixture} from "./utils/NativeCoordinatorFixture.sol";
import {HTLCNative} from "../src/HTLCNative.sol";
import {HTLCNativeCoordinator} from "../src/HTLCNativeCoordinator.sol";
import {CallExecutor} from "../src/CallExecutor.sol";
import {MockWRBTC} from "./mocks/MockWRBTC.sol";

/// @notice A target that burns the value it is sent: the calls net less than `msg.value`.
contract Sink {
    receive() external payable {}
}

/// @notice A target that pays the coordinator more than it was sent (a favourable DEX).
contract Payer {
    receive() external payable {}

    function pay(address to, uint256 value) external {
        (bool ok,) = to.call{value: value}("");
        require(ok, "Payer: send");
    }
}

/// @notice A depositor that refuses the native coin.
contract NonReceiver {
    function lock(HTLCNativeCoordinator c, bytes32 h, uint256 amount, address claim, uint256 tl) external payable {
        CallExecutor.Call[] memory calls;
        c.executeAndCreate{value: msg.value}(calls, h, amount, claim, tl);
    }
}

contract HTLCNativeCoordinatorExecuteAndCreateTest is NativeCoordinatorFixture {
    function test_plainLock_recordsDepositAndLocksExactly() public {
        _lock();

        assertTrue(_isActive(amount), "swap active");
        assertEq(coordinator.deposits(_key(amount)), alice, "depositor recorded");
        assertEq(address(htlc).balance, amount, "htlc holds the lock");
        assertEq(htlc.lockedTotal(), amount, "lockedTotal");
        assertEq(address(coordinator).balance, 0, "coordinator keeps nothing");
        assertEq(alice.balance, 10 ether - amount, "alice paid exactly amount");
    }

    function test_noCalls_valueBelowAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(CallExecutor.InsufficientBalance.selector);
        coordinator.executeAndCreate{value: amount - 1}(noCalls, preimageHash, amount, bob, timelock);
    }

    function test_noCalls_valueAboveAmount_returnsExcess() public {
        vm.prank(alice);
        coordinator.executeAndCreate{value: amount + 0.3 ether}(noCalls, preimageHash, amount, bob, timelock);

        assertTrue(_isActive(amount), "locked exactly amount");
        assertEq(alice.balance, 10 ether - amount, "excess returned");
        assertEq(address(coordinator).balance, 0, "nothing left behind");
    }

    function test_callsConsumeValue_lockIsWhatRemains() public {
        // Alice sends amount + 0.1, a call spends 0.1 into a sink, exactly `amount` is left.
        Sink sink = new Sink();
        CallExecutor.Call[] memory calls =
            _one(CallExecutor.Call({target: address(sink), value: 0.1 ether, callData: ""}));

        vm.prank(alice);
        coordinator.executeAndCreate{value: amount + 0.1 ether}(calls, preimageHash, amount, bob, timelock);

        assertTrue(_isActive(amount), "locked amount");
        assertEq(address(sink).balance, 0.1 ether, "call spent value");
        assertEq(address(coordinator).balance, 0, "nothing left behind");
    }

    function test_callsConsumeTooMuch_reverts() public {
        Sink sink = new Sink();
        CallExecutor.Call[] memory calls =
            _one(CallExecutor.Call({target: address(sink), value: 0.1 ether, callData: ""}));

        vm.prank(alice);
        vm.expectRevert(CallExecutor.InsufficientBalance.selector);
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
    }

    function test_callsProduceValue_unwrapWithPositiveSlippage() public {
        // Alice holds WRBTC, hands it to the coordinator and unwraps it in the call
        // batch: msg.value is 0, the calls produce the coin, the excess comes back.
        vm.startPrank(alice);
        wrbtc.deposit{value: amount + 0.2 ether}();
        wrbtc.transfer(address(coordinator), amount + 0.2 ether);
        vm.stopPrank();

        CallExecutor.Call[] memory calls = _one(_unwrapCall(amount + 0.2 ether));

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        coordinator.executeAndCreate(calls, preimageHash, amount, bob, timelock);

        assertTrue(_isActive(amount), "locked amount");
        assertEq(alice.balance, aliceBefore + 0.2 ether, "positive slippage returned");
        assertEq(address(coordinator).balance, 0, "nothing left behind");
    }

    function test_callsPaidByThirdParty_countsAsReceived() public {
        Payer payer = new Payer();
        vm.deal(address(payer), 1 ether);
        CallExecutor.Call[] memory calls = _one(
            CallExecutor.Call({
                target: address(payer),
                value: 0,
                callData: abi.encodeWithSelector(Payer.pay.selector, address(coordinator), amount)
            })
        );

        vm.prank(alice);
        coordinator.executeAndCreate(calls, preimageHash, amount, bob, timelock);
        assertTrue(_isActive(amount), "locked from what the call produced");
    }

    function test_strayBalance_untouchedAndNotLocked() public {
        // A stray sits on the coordinator; the lock neither uses nor returns it.
        vm.deal(address(coordinator), 0.5 ether);

        _lock();

        assertEq(address(coordinator).balance, 0.5 ether, "stray untouched");
        assertEq(alice.balance, 10 ether - amount, "alice paid exactly amount");
    }

    function test_strayBalance_cannotFundTheLock() public {
        vm.deal(address(coordinator), 1 ether);

        vm.prank(alice);
        vm.expectRevert(CallExecutor.InsufficientBalance.selector);
        coordinator.executeAndCreate{value: amount - 1}(noCalls, preimageHash, amount, bob, timelock);
    }

    function test_callsSpendStray_reverts() public {
        // The batch spends more than msg.value: it reached into the stray.
        vm.deal(address(coordinator), 1 ether);
        Sink sink = new Sink();
        CallExecutor.Call[] memory calls =
            _one(CallExecutor.Call({target: address(sink), value: 0.1 ether, callData: ""}));

        vm.prank(alice);
        vm.expectRevert(HTLCNativeCoordinator.CallsOverspent.selector);
        coordinator.executeAndCreate{value: 0.05 ether}(calls, preimageHash, 0.05 ether, bob, timelock);
    }

    function test_restrictedTarget_htlc_reverts() public {
        // A call must not reach HTLC_NATIVE.create to plant a swap under other terms.
        CallExecutor.Call[] memory calls = _one(
            CallExecutor.Call({
                target: address(htlc),
                value: amount,
                callData: abi.encodeWithSignature(
                    "create(bytes32,address,uint256)", preimageHash, makeAddr("attacker"), timelock
                )
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CallExecutor.RestrictedTarget.selector, address(htlc)));
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
    }

    function test_restrictedTarget_self_reverts() public {
        CallExecutor.Call[] memory calls =
            _one(CallExecutor.Call({target: address(coordinator), value: 0, callData: ""}));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CallExecutor.RestrictedTarget.selector, address(coordinator)));
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
    }

    function test_restrictedTarget_permit2_reverts() public {
        CallExecutor.Call[] memory calls =
            _one(CallExecutor.Call({target: coordinator.PERMIT2(), value: 0, callData: ""}));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CallExecutor.RestrictedTarget.selector, coordinator.PERMIT2()));
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
    }

    function test_dangerousSelector_reverts() public {
        CallExecutor.Call[] memory calls = _one(
            CallExecutor.Call({
                target: address(wrbtc),
                value: 0,
                callData: abi.encodeWithSelector(bytes4(0x23b872dd), alice, address(coordinator), 1)
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CallExecutor.DangerousSelector.selector, bytes4(0x23b872dd)));
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
    }

    function test_callFails_revertsWithIndex() public {
        CallExecutor.Call[] memory calls = new CallExecutor.Call[](2);
        calls[0] = _wrapCall(0);
        calls[1] = _unwrapCall(1); // nothing to burn
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CallExecutor.CallFailed.selector, 1));
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
    }

    function test_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCNative.ZeroAmount.selector);
        coordinator.executeAndCreate(noCalls, preimageHash, 0, bob, timelock);
    }

    function test_sameKeyTwice_reverts() public {
        _lock();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HTLCNative.SwapExists.selector, _key(amount), HTLCNative.SwapState.Active)
        );
        coordinator.executeAndCreate{value: amount}(noCalls, preimageHash, amount, bob, timelock);
    }

    function test_excessToNonReceivableDepositor_reverts() public {
        NonReceiver nr = new NonReceiver();
        vm.deal(address(nr), 2 ether);
        vm.expectRevert(CallExecutor.EtherTransferFailed.selector);
        nr.lock{value: amount + 1}(coordinator, preimageHash, amount, bob, timelock);
    }

    function test_exactValueFromNonReceivableDepositor_succeeds() public {
        NonReceiver nr = new NonReceiver();
        vm.deal(address(nr), 2 ether);
        nr.lock{value: amount}(coordinator, preimageHash, amount, bob, timelock);
        assertEq(coordinator.deposits(_key(amount)), address(nr), "contract depositor recorded");
    }
}
