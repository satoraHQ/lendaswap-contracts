// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCNative, SwapKey} from "../../src/HTLCNative.sol";
import {HTLCNativeCoordinator} from "../../src/HTLCNativeCoordinator.sol";
import {CallExecutor} from "../../src/CallExecutor.sol";
import {MockWRBTC} from "../mocks/MockWRBTC.sol";

/// @notice Shared setup for the HTLCNativeCoordinator suites: Alice locks RBTC for Bob
///         through the coordinator, Bob claims by signature, a relayer submits.
abstract contract NativeCoordinatorFixture is Test {
    HTLCNative htlc;
    HTLCNativeCoordinator coordinator;
    MockWRBTC wrbtc;

    address alice = makeAddr("alice");
    uint256 bobPk;
    address bob;
    address relayer = makeAddr("relayer");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1 ether;
    uint256 timelock;

    CallExecutor.Call[] noCalls;

    function setUp() public virtual {
        htlc = new HTLCNative(address(this));
        coordinator = new HTLCNativeCoordinator(address(htlc));
        wrbtc = new MockWRBTC();

        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        vm.deal(alice, 10 ether);
        vm.deal(relayer, 1 ether);
    }

    // -- Helpers --

    function _key(uint256 _amount) internal view returns (SwapKey) {
        return htlc.computeKey(preimageHash, _amount, address(0), address(coordinator), bob, timelock);
    }

    function _isActive(uint256 _amount) internal view returns (bool) {
        return htlc.isActive(preimageHash, _amount, address(0), address(coordinator), bob, timelock);
    }

    /// Alice locks `amount` with no calls.
    function _lock() internal {
        vm.prank(alice);
        coordinator.executeAndCreate{value: amount}(noCalls, preimageHash, amount, bob, timelock);
    }

    function _callsHash(CallExecutor.Call[] memory calls) internal pure returns (bytes32) {
        return keccak256(abi.encode(calls));
    }

    /// Bob's HTLC-level redeem signature naming the coordinator as caller.
    function _signRedeem(
        uint256 pk,
        address caller,
        address destination,
        address sweepToken,
        uint256 minAmountOut,
        bytes32 callsHash
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        preimage,
                        amount,
                        address(coordinator),
                        timelock,
                        caller,
                        destination,
                        sweepToken,
                        minAmountOut,
                        callsHash
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }

    /// Relayer submits Bob's redeem through the coordinator.
    function _redeemVia(
        CallExecutor.Call[] memory calls,
        address sweepToken,
        uint256 minAmountOut,
        address destination
    ) internal {
        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(
            bobPk, address(coordinator), destination, sweepToken, minAmountOut, _callsHash(calls)
        );
        vm.prank(relayer);
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, calls, sweepToken, minAmountOut, destination, v, r, s
        );
    }

    function _wrapCall(uint256 value) internal view returns (CallExecutor.Call memory) {
        return CallExecutor.Call({
            target: address(wrbtc), value: value, callData: abi.encodeWithSelector(MockWRBTC.deposit.selector)
        });
    }

    function _unwrapCall(uint256 value) internal view returns (CallExecutor.Call memory) {
        return CallExecutor.Call({
            target: address(wrbtc), value: 0, callData: abi.encodeWithSelector(MockWRBTC.withdraw.selector, value)
        });
    }

    function _one(CallExecutor.Call memory c) internal pure returns (CallExecutor.Call[] memory calls) {
        calls = new CallExecutor.Call[](1);
        calls[0] = c;
    }
}
