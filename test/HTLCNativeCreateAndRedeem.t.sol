// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCNative, SwapKey} from "../src/HTLCNative.sol";

/// @notice E2E: user creates a native-coin HTLC, claimAddress redeems it (directly or by signature)
contract HTLCNativeCreateAndRedeemTest is Test {
    event SwapCreated(
        bytes32 indexed preimageHash,
        address indexed refundAddress,
        address indexed claimAddress,
        address token,
        uint256 amount,
        uint256 timelock,
        SwapKey key
    );
    event SwapRedeemed(bytes32 indexed preimageHash, SwapKey indexed key, bytes32 preimage);

    HTLCNative htlc;

    address alice = makeAddr("alice");
    uint256 bobPk;
    address bob;
    address relayer = makeAddr("relayer");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1 ether;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCNative(address(this));
        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        vm.deal(alice, 10 ether);
    }

    function test_createAndRedeem() public {
        // 1. Alice creates an HTLC locking 1 RBTC with Bob as claimAddress
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        // Verify: coins moved from alice to the HTLC contract
        assertEq(alice.balance, 9 ether, "alice should have 9 left");
        assertEq(address(htlc).balance, amount, "htlc should hold 1");
        assertEq(htlc.lockedTotal(), amount, "lockedTotal tracks the swap");
        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "swap should be active");

        // 2. Bob (claimAddress) redeems by revealing the preimage
        vm.prank(bob);
        htlc.redeem(preimage, amount, alice, timelock);

        // Verify: coins moved from HTLC to Bob (msg.sender = claimAddress)
        assertEq(bob.balance, amount, "bob should have received 1");
        assertEq(address(htlc).balance, 0, "htlc should be empty");
        assertEq(htlc.lockedTotal(), 0, "nothing locked anymore");
        assertFalse(
            htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "swap should no longer be active"
        );
    }

    function test_createEmitsErc20ShapedEventWithZeroToken() public {
        SwapKey key = htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock);

        vm.expectEmit(true, true, true, true, address(htlc));
        emit SwapCreated(preimageHash, alice, bob, address(0), amount, timelock, key);
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
    }

    function test_redeemEmitsSwapKey() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
        SwapKey key = htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock);

        vm.expectEmit(true, true, false, true, address(htlc));
        emit SwapRedeemed(preimageHash, key, preimage);
        vm.prank(bob);
        htlc.redeem(preimage, amount, alice, timelock);
    }

    /// The value always comes from msg.sender; the refund address is whoever the caller names.
    function test_createWithExplicitRefundAddress() public {
        address carol = makeAddr("carol");
        vm.deal(carol, amount);

        vm.prank(carol);
        htlc.create{value: amount}(preimageHash, alice, bob, timelock);

        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "keyed on alice");
        assertFalse(htlc.isActive(preimageHash, amount, address(0), carol, bob, timelock), "not keyed on carol");

        vm.prank(bob);
        htlc.redeem(preimage, amount, alice, timelock);
        assertEq(bob.balance, amount, "bob paid out");
    }

    /// The claimant may redeem after the timelock too — expiry only enables the refund.
    function test_redeemAfterTimelock_stillWorks() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        vm.warp(timelock + 1 days);
        vm.prank(bob);
        htlc.redeem(preimage, amount, alice, timelock);
        assertEq(bob.balance, amount, "bob paid out");
    }

    // -- Creation guards --

    function test_createWithZeroValue_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCNative.ZeroAmount.selector);
        htlc.create{value: 0}(preimageHash, bob, timelock);
    }

    function test_createWithPastTimelock_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCNative.TimelockTooSoon.selector);
        htlc.create{value: amount}(preimageHash, bob, block.timestamp);
    }

    function test_createDuplicate_reverts() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
        SwapKey key = htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapExists.selector, key, HTLCNative.SwapState.Active));
        htlc.create{value: amount}(preimageHash, bob, timelock);

        assertEq(address(htlc).balance, amount, "second value was not taken");
        assertEq(htlc.lockedTotal(), amount, "locked once");
    }

    /// A plain transfer is not a lock: there is no receive/fallback, so it bounces.
    function test_plainTransfer_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(htlc).call{value: 1 ether}("");
        assertFalse(ok, "no payable fallback");
        assertEq(address(htlc).balance, 0, "nothing arrived");
    }

    // -- Redeem guards --

    function test_redeemWithInvalidPreimage_reverts() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        bytes32 wrongPreimage = bytes32(uint256(0xbaadf00d));
        vm.prank(bob);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeem(wrongPreimage, amount, alice, timelock);

        assertEq(bob.balance, 0, "bob should still have 0");
        assertEq(address(htlc).balance, amount, "htlc should still hold 1");
    }

    function test_redeemByNonClaimAddress_reverts() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeem(preimage, amount, alice, timelock);

        assertEq(charlie.balance, 0, "charlie should have 0");
        assertEq(address(htlc).balance, amount, "htlc should still hold 1");
    }

    function test_redeemWithWrongAmount_reverts() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        vm.prank(bob);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeem(preimage, amount + 1, alice, timelock);
    }

    // -- redeemBySig --

    function test_redeemBySig_paysTheAuthorizedCaller() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
        SwapKey key = htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock);

        // Bob signs for the relayer as the authorized caller, with bob as destination
        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(bobPk, relayer, bob, address(0), 0, bytes32(0));

        vm.expectEmit(true, true, false, true, address(htlc));
        emit SwapRedeemed(preimageHash, key, preimage);
        vm.prank(relayer);
        address recovered = htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);

        assertEq(recovered, bob, "recovered address should be bob");
        assertEq(relayer.balance, amount, "the caller receives the coins, not the claimant");
        assertEq(bob.balance, 0, "claimant is paid downstream by the caller");
        assertEq(htlc.lockedTotal(), 0, "released");
    }

    function test_redeemBySig_wrongCaller_reverts() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(bobPk, relayer, bob, address(0), 0, bytes32(0));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);

        assertEq(address(htlc).balance, amount, "still locked");
    }

    function test_redeemBySig_onUnknownSwap_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(bobPk, relayer, bob, address(0), 0, bytes32(0));
        SwapKey key = htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.None));
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);
    }

    // -- Helpers --

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
                        alice,
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
}
