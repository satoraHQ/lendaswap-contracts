// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeCoordinatorFixture} from "./utils/NativeCoordinatorFixture.sol";
import {HTLCNative} from "../src/HTLCNative.sol";
import {CallExecutor} from "../src/CallExecutor.sol";

contract HTLCNativeCoordinatorRedeemAndExecuteTest is NativeCoordinatorFixture {
    function setUp() public override {
        super.setUp();
        _lock();
    }

    function test_plainSweep_paysDestination() public {
        _redeemVia(noCalls, address(0), amount, bob);

        assertEq(bob.balance, amount, "bob received the coin");
        assertFalse(_isActive(amount), "swap settled");
        (HTLCNative.SwapState state, bytes32 revealed) = htlc.swapState(_key(amount));
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Redeemed), "redeemed");
        assertEq(revealed, preimage, "preimage stored");
        assertEq(address(coordinator).balance, 0, "coordinator empty");
        assertEq(coordinator.deposits(_key(amount)), address(0), "deposit record cleared on redeem");
    }

    function test_redeemOfDirectlyCreatedSwap_leavesDepositsAlone() public {
        // A swap Alice created straight on the HTLC has no deposit record; the
        // coordinator must not touch the mapping when settling it.
        bytes32 h2 = sha256(abi.encodePacked(bytes32(uint256(0xcafe))));
        vm.prank(alice);
        htlc.create{value: amount}(h2, bob, timelock);
        (uint8 v, bytes32 r, bytes32 s) = _signRedeemFor(bytes32(uint256(0xcafe)), alice, bob);
        vm.prank(relayer);
        coordinator.redeemAndExecute(
            bytes32(uint256(0xcafe)), amount, alice, timelock, noCalls, address(0), amount, bob, v, r, s
        );
        assertEq(bob.balance, amount, "bob paid");
        assertEq(coordinator.deposits(_key(amount)), alice, "unrelated deposit record intact");
    }

    /// Bob's signature for a swap with an explicit preimage and HTLC sender.
    function _signRedeemFor(bytes32 _preimage, address sender, address destination)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        _preimage,
                        amount,
                        sender,
                        timelock,
                        address(coordinator),
                        destination,
                        address(0),
                        amount,
                        _callsHash(noCalls)
                    )
                )
            )
        );
        (v, r, s) = vm.sign(bobPk, digest);
    }

    function test_sweepToOtherDestination_signedByBob() public {
        address vault = makeAddr("vault");
        _redeemVia(noCalls, address(0), amount, vault);
        assertEq(vault.balance, amount, "signed destination paid");
        assertEq(bob.balance, 0, "bob paid nothing to himself");
    }

    function test_wrapThenSweepErc20() public {
        CallExecutor.Call[] memory calls = _one(_wrapCall(amount));
        _redeemVia(calls, address(wrbtc), amount, bob);

        assertEq(wrbtc.balanceOf(bob), amount, "bob received WRBTC");
        assertEq(bob.balance, 0, "no native paid");
        assertEq(address(coordinator).balance, 0, "coordinator empty");
    }

    function test_minAmountOutBreach_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(0), amount + 1, _callsHash(noCalls));
        vm.prank(relayer);
        vm.expectRevert(CallExecutor.InsufficientBalance.selector);
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, noCalls, address(0), amount + 1, bob, v, r, s
        );
    }

    function test_tamperedDestination_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(0), amount, _callsHash(noCalls));
        // The recovered signer is not Bob, so the key names an unknown swap.
        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, noCalls, address(0), amount, relayer, v, r, s
        );
        assertTrue(_isActive(amount), "swap untouched");
    }

    function test_tamperedCalls_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(0), amount, _callsHash(noCalls));
        CallExecutor.Call[] memory calls = _one(_wrapCall(amount));
        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, calls, address(0), amount, bob, v, r, s
        );
        assertTrue(_isActive(amount), "swap untouched");
    }

    function test_signatureForEoaCaller_rejectedByCoordinator() public {
        // Bob named the relayer as caller; submitted through the coordinator it recovers
        // to someone else and fails.
        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(bobPk, relayer, bob, address(0), amount, _callsHash(noCalls));
        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, noCalls, address(0), amount, bob, v, r, s
        );
    }

    function test_thirdPartySubmitter_paysDestinationOnly() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(0), amount, _callsHash(noCalls));
        vm.prank(stranger);
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, noCalls, address(0), amount, bob, v, r, s
        );
        assertEq(bob.balance, amount, "bob paid");
        assertEq(stranger.balance, 1 ether, "stranger gained nothing");
    }

    function test_strays_sweptToDestination() public {
        vm.deal(address(coordinator), 0.5 ether);
        _redeemVia(noCalls, address(0), amount, bob);
        assertEq(bob.balance, amount + 0.5 ether, "strays ride along with the sweep");
        assertEq(address(coordinator).balance, 0, "coordinator empty");
    }

    function test_submitterValue_fundsCallValue() public {
        // The relayer tops up the wrap by 0.1 from its own msg.value.
        CallExecutor.Call[] memory calls = _one(_wrapCall(amount + 0.1 ether));
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(wrbtc), amount, _callsHash(calls));
        vm.prank(relayer);
        coordinator.redeemAndExecute{value: 0.1 ether}(
            preimage, amount, address(coordinator), timelock, calls, address(wrbtc), amount, bob, v, r, s
        );
        assertEq(wrbtc.balanceOf(bob), amount + 0.1 ether, "bob received the topped-up wrap");
        assertEq(relayer.balance, 0.9 ether, "relayer paid the top-up");
    }

    function test_redeemTwice_reverts() public {
        _redeemVia(noCalls, address(0), amount, bob);
        (uint8 v, bytes32 r, bytes32 s) =
            _signRedeem(bobPk, address(coordinator), bob, address(0), amount, _callsHash(noCalls));
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, _key(amount), HTLCNative.SwapState.Redeemed)
        );
        coordinator.redeemAndExecute(
            preimage, amount, address(coordinator), timelock, noCalls, address(0), amount, bob, v, r, s
        );
    }

    function test_directRedeemOnHtlc_stillWorksForBob() public {
        // The coordinator is the sender; Bob may bypass it entirely.
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(coordinator), timelock);
        assertEq(bob.balance, amount, "bob claimed directly");
    }
}
