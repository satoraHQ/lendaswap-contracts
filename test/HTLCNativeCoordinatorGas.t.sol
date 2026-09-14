// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeCoordinatorFixture} from "./utils/NativeCoordinatorFixture.sol";
import {CallExecutor} from "../src/CallExecutor.sol";

/// @notice Gas of the entry points the backend prices: the daemon's relay overhead
///         constant for gasless native claims is measured from `redeemAndExecute`
///         with no calls. `forge test --match-contract HTLCNativeCoordinatorGas -vv`
///         prints the numbers; `forge snapshot` records them under `snapshots/`.
contract HTLCNativeCoordinatorGasTest is NativeCoordinatorFixture {
    function test_gas_executeAndCreate_noCalls() public {
        vm.prank(alice);
        coordinator.executeAndCreate{value: amount}(noCalls, preimageHash, amount, bob, timelock);
        vm.snapshotGasLastCall("executeAndCreate_0calls");
    }

    function test_gas_executeAndCreate_oneCall() public {
        CallExecutor.Call[] memory calls = _one(_wrapCall(0));
        vm.prank(alice);
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
        vm.snapshotGasLastCall("executeAndCreate_1call");
    }

    function test_gas_executeAndCreate_threeCalls() public {
        CallExecutor.Call[] memory calls = new CallExecutor.Call[](3);
        calls[0] = _wrapCall(0);
        calls[1] = _wrapCall(0);
        calls[2] = _wrapCall(0);
        vm.prank(alice);
        coordinator.executeAndCreate{value: amount}(calls, preimageHash, amount, bob, timelock);
        vm.snapshotGasLastCall("executeAndCreate_3calls");
    }

    function test_gas_redeemAndExecute_noCalls() public {
        _lock();
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(0), amount, _callsHash(noCalls));
        vm.prank(relayer);
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, noCalls, address(0), amount, bob, v, r, s
        );
        vm.snapshotGasLastCall("redeemAndExecute_0calls");
    }

    function test_gas_directRedeem() public {
        _lock();
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(coordinator), timelock);
        vm.snapshotGasLastCall("htlcNative_redeem_direct");
    }
}
