// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCNative, SwapKey} from "../src/HTLCNative.sol";

/// @notice E2E: user creates a native-coin HTLC, timelock expires, sender refunds
contract HTLCNativeCreateAndRefundTest is Test {
    event SwapRefunded(bytes32 indexed preimageHash, SwapKey indexed key);

    HTLCNative htlc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1 ether;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCNative(address(this));
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        vm.deal(alice, 10 ether);
        vm.deal(carol, 10 ether);
    }

    function _create() internal {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
    }

    function test_createAndRefund() public {
        // 1. Alice creates an HTLC locking 1 RBTC with Bob as claimAddress
        _create();
        assertEq(alice.balance, 9 ether);
        assertEq(address(htlc).balance, amount);

        // 2. Bob never redeems — timelock expires
        vm.warp(timelock + 1);

        // 3. Alice refunds and gets her coins back
        SwapKey key = htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock);
        vm.expectEmit(true, true, false, true, address(htlc));
        emit SwapRefunded(preimageHash, key);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, bob, timelock);

        assertEq(alice.balance, 10 ether, "alice should have all 10 back");
        assertEq(address(htlc).balance, 0, "htlc should be empty");
        assertEq(htlc.lockedTotal(), 0, "released");
        assertFalse(
            htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "swap should no longer be active"
        );
    }

    /// The boundary is inclusive: at `timelock` exactly the refund is allowed.
    function test_refundAtTimelock_works() public {
        _create();
        vm.warp(timelock);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, bob, timelock);
        assertEq(alice.balance, 10 ether, "refunded");
    }

    function test_refundBeforeTimelock_reverts() public {
        _create();

        vm.warp(timelock - 1);
        vm.prank(alice);
        vm.expectRevert(HTLCNative.TimelockNotExpired.selector);
        htlc.refund(preimageHash, amount, bob, timelock);

        assertEq(alice.balance, 9 ether, "alice should still have 9");
        assertEq(address(htlc).balance, amount, "htlc should still hold 1");
    }

    function test_refundByNonRefundAddress_reverts() public {
        _create();
        vm.warp(timelock);

        // msg.sender is the refundAddress in the key, so carol derives a key that does not exist.
        vm.prank(carol);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refund(preimageHash, amount, bob, timelock);

        // Neither can the claimant take the refund path.
        vm.prank(bob);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refund(preimageHash, amount, bob, timelock);

        assertEq(address(htlc).balance, amount, "still locked");
    }

    // -- Explicit refund address --

    function test_explicitRefundAddress_isTheOnlyRefunder() public {
        // Carol pays, but names alice as the party that can reclaim.
        vm.prank(carol);
        htlc.create{value: amount}(preimageHash, alice, bob, timelock);
        vm.warp(timelock);

        vm.prank(carol);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refund(preimageHash, amount, bob, timelock);

        vm.prank(alice);
        htlc.refund(preimageHash, amount, bob, timelock);
        assertEq(alice.balance, 11 ether, "alice reclaimed carol's deposit");
    }

    // -- Refund to a destination --

    function test_refundToDestination() public {
        _create();
        vm.warp(timelock);

        vm.prank(alice);
        htlc.refund(preimageHash, amount, bob, timelock, carol);

        assertEq(carol.balance, 11 ether, "destination paid");
        assertEq(alice.balance, 9 ether, "refunder not paid");
        assertEq(htlc.lockedTotal(), 0, "released");
    }

    function test_refundToDestination_byNonRefundAddress_reverts() public {
        _create();
        vm.warp(timelock);

        vm.prank(carol);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refund(preimageHash, amount, bob, timelock, carol);
    }

    /// A native transfer to address(0) would succeed and burn the deposit.
    function test_refundToZeroDestination_reverts() public {
        _create();
        vm.warp(timelock);

        vm.prank(alice);
        vm.expectRevert(HTLCNative.ZeroRecipient.selector);
        htlc.refund(preimageHash, amount, bob, timelock, address(0));

        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "still active");
    }

    function test_refundToDestination_beforeTimelock_reverts() public {
        _create();

        vm.prank(alice);
        vm.expectRevert(HTLCNative.TimelockNotExpired.selector);
        htlc.refund(preimageHash, amount, bob, timelock, carol);
    }
}
