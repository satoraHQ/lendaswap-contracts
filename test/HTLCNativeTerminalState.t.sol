// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCNative, SwapKey} from "../src/HTLCNative.sol";

/// @notice A settled swap's outcome stays readable from storage: the state enum
///         classifies redeem vs refund, a redeem stores its preimage, and a
///         settled key can never be created or settled again — not even under
///         terms one parameter away from it.
contract HTLCNativeTerminalStateTest is Test {
    HTLCNative htlc;

    address alice = makeAddr("alice");
    address carol = makeAddr("carol");
    address bob;
    uint256 bobPk;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1 ether;
    uint256 timelock;
    SwapKey key;

    function setUp() public {
        (bob, bobPk) = makeAddrAndKey("bob");
        htlc = new HTLCNative(address(this));
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;
        vm.deal(alice, 10 ether);
        key = htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock);
    }

    function _create() internal {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
    }

    function _redeem() internal {
        vm.prank(bob);
        htlc.redeem(preimage, amount, alice, timelock);
    }

    function _refund() internal {
        vm.warp(timelock);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, bob, timelock);
    }

    function test_lifecycleStates() public {
        (HTLCNative.SwapState state, bytes32 storedPreimage) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.None), "unknown key is None");
        assertEq(storedPreimage, bytes32(0));

        _create();
        (state,) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Active), "created swap is Active");
        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock));
    }

    function test_redeemStoresTerminalStateAndPreimage() public {
        _create();
        _redeem();

        (HTLCNative.SwapState state, bytes32 storedPreimage) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Redeemed), "redeem is terminal");
        assertEq(storedPreimage, preimage, "revealed preimage is readable from storage");
        assertFalse(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock));
    }

    function test_refundStoresTerminalState() public {
        _create();
        _refund();

        (HTLCNative.SwapState state, bytes32 storedPreimage) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Refunded), "refund is terminal");
        assertEq(storedPreimage, bytes32(0), "no preimage was revealed");
        assertFalse(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock));
    }

    // -- Terminal keys are never recreated --

    function test_redeemedKey_cannotBeCreatedAgain() public {
        _create();
        _redeem();

        // The preimage is now public; locking coins under the same key again
        // would be claimable by anyone, so create must reject the settled key.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapExists.selector, key, HTLCNative.SwapState.Redeemed));
        htlc.create{value: amount}(preimageHash, bob, timelock);

        assertEq(htlc.lockedTotal(), 0, "nothing was locked");
        assertEq(alice.balance, 9 ether, "value was not taken");
    }

    /// A unilateral refund needs the timelock to have passed, so on a real chain a
    /// re-create under the same terms already fails the "timelock too soon" check.
    /// Winding the clock back isolates the settled-key check itself.
    function test_refundedKey_cannotBeCreatedAgain() public {
        _create();
        _refund();

        vm.prank(alice);
        vm.expectRevert(HTLCNative.TimelockTooSoon.selector);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        vm.warp(timelock - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapExists.selector, key, HTLCNative.SwapState.Refunded));
        htlc.create{value: amount}(preimageHash, bob, timelock);

        (HTLCNative.SwapState state,) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Refunded), "still refunded");
    }

    // -- Terminal keys are never settled again --

    function test_redeemedSwap_cannotBeSettledAgain() public {
        _create();
        _redeem();

        // A second redeem must not pass the Active check; the error names the
        // terminal state the swap is actually in.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Redeemed));
        htlc.redeem(preimage, amount, alice, timelock);

        // Nor a signed redeem.
        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Redeemed));
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);

        // Neither may a refund of the already-redeemed swap.
        vm.warp(timelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Redeemed));
        htlc.refund(preimageHash, amount, bob, timelock);

        assertEq(address(htlc).balance, 0, "paid out exactly once");
    }

    function test_refundedSwap_cannotBeSettledAgain() public {
        _create();
        _refund();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Refunded));
        htlc.refund(preimageHash, amount, bob, timelock);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Refunded));
        htlc.refund(preimageHash, amount, bob, timelock, carol);

        // The claimant learned the preimage too late: the refunded swap is gone.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Refunded));
        htlc.redeem(preimage, amount, alice, timelock);

        assertEq(address(htlc).balance, 0, "paid out exactly once");
    }

    /// Terms one parameter away from a settled swap name a key that was never created,
    /// so they revert as None — a terminal swap cannot be reached under adjacent terms.
    function test_adjacentTerms_onSettledSwap_revert() public {
        _create();
        _redeem();
        // Another force-funded balance must not make any of these succeed.
        vm.deal(address(htlc), 10 ether);

        vm.startPrank(bob);
        _expectNone(htlc.computeKey(preimageHash, amount + 1, address(0), alice, bob, timelock));
        htlc.redeem(preimage, amount + 1, alice, timelock);

        _expectNone(htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock + 1));
        htlc.redeem(preimage, amount, alice, timelock + 1);

        _expectNone(htlc.computeKey(preimageHash, amount, address(0), carol, bob, timelock));
        htlc.redeem(preimage, amount, carol, timelock);
        vm.stopPrank();

        SwapKey otherClaimant = htlc.computeKey(preimageHash, amount, address(0), alice, carol, timelock);
        vm.prank(carol);
        _expectNone(otherClaimant);
        htlc.redeem(preimage, amount, alice, timelock);

        vm.warp(timelock);
        vm.startPrank(alice);
        _expectNone(htlc.computeKey(preimageHash, amount - 1, address(0), alice, bob, timelock));
        htlc.refund(preimageHash, amount - 1, bob, timelock);

        _expectNone(htlc.computeKey(preimageHash, amount, address(0), alice, carol, timelock));
        htlc.refund(preimageHash, amount, carol, timelock);
        vm.stopPrank();

        assertEq(htlc.lockedTotal(), 0, "accounting untouched");
        assertEq(bob.balance, amount, "paid out exactly once");
    }

    // -- Helpers --

    function _expectNone(SwapKey k) internal {
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, k, HTLCNative.SwapState.None));
    }

    function _signRedeem(address caller) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        preimage,
                        amount,
                        alice,
                        timelock,
                        caller,
                        bob,
                        address(0),
                        uint256(0),
                        bytes32(0)
                    )
                )
            )
        );
        (v, r, s) = vm.sign(bobPk, digest);
    }
}
