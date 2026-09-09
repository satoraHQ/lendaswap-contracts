// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {HTLCNative, SwapKey} from "../src/HTLCNative.sol";

/// @notice A recovered signer authorises nothing until the recovery is known to have
///         succeeded, no swap may name address(0) as either party, and no payout may
///         target address(0) — a native transfer there succeeds and burns the coins.
/// @dev `redeemBySig` derives its swap key from the recovered address, so a recovery
///      that resolved to address(0) would derive a valid key for a swap whose claimAddress
///      is address(0). Both layers are covered: such a swap cannot be created, and a
///      recovery that does not succeed reverts rather than resolving to address(0).
contract HTLCNativeZeroAddressTest is Test {
    /// @dev `swaps` and `lockedTotal` sit behind `Ownable2Step`'s `_owner` and
    ///      `_pendingOwner`. Confirmed with `forge inspect HTLCNative storage`; re-check
    ///      it if the base changes, or the seeded swap silently lands nowhere and the
    ///      theft test proves nothing (its `isActive` assertion guards against that).
    uint256 internal constant SWAPS_SLOT = 2;
    uint256 internal constant LOCKED_TOTAL_SLOT = 3;

    HTLCNative htlc;

    address alice = makeAddr("alice");
    uint256 bobPk;
    address bob;
    address eve = makeAddr("eve");

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

    // -- The swap that makes the theft possible cannot be created --

    function test_create_zeroClaimAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCNative.ZeroClaimAddress.selector);
        htlc.create{value: amount}(preimageHash, address(0), timelock);
    }

    function test_createWithRefundAddress_zeroClaimAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCNative.ZeroClaimAddress.selector);
        htlc.create{value: amount}(preimageHash, alice, address(0), timelock);
    }

    /// The same omission on the fund-loss side: nobody could reclaim this after timelock.
    function test_createWithRefundAddress_zeroRefundAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCNative.ZeroRefundAddress.selector);
        htlc.create{value: amount}(preimageHash, address(0), bob, timelock);
    }

    // -- A failed recovery is not an authorisation --

    function test_redeemBySig_garbageSignature_reverts() public {
        _aliceCreate(bob);

        vm.prank(eve);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        htlc.redeemBySig(
            preimage,
            amount,
            alice,
            timelock,
            eve,
            address(0),
            0,
            bytes32(0),
            27,
            bytes32(uint256(1)),
            bytes32(0) // s = 0 has no valid recovery
        );

        assertEq(eve.balance, 0, "eve must not receive anything");
        assertEq(address(htlc).balance, amount, "htlc must still hold the coins");
    }

    /// Seeds a zero-claim swap straight into storage — the state a contract without the
    /// creation guard could already hold — and shows the recovery check alone stops it.
    ///
    /// `lockedTotal` is seeded alongside `swaps` so the state matches what `create`
    /// would have produced. Without it the settlement underflows on the decrement and
    /// reverts for that reason instead, which would leave the theft itself untested.
    function test_preExistingZeroClaimSwap_cannotBeStolen() public {
        SwapKey key = htlc.computeKey(preimageHash, amount, address(0), alice, address(0), timelock);
        vm.store(address(htlc), keccak256(abi.encode(key, SWAPS_SLOT)), bytes32(uint256(1)));
        vm.store(address(htlc), bytes32(LOCKED_TOTAL_SLOT), bytes32(amount));
        vm.deal(address(htlc), amount);

        assertEq(htlc.lockedTotal(), amount, "accounting must match the swap");
        assertTrue(
            htlc.isActive(preimageHash, amount, address(0), alice, address(0), timelock),
            "the seeded swap must actually be in storage, or this test proves nothing"
        );

        vm.prank(eve);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        htlc.redeemBySig(
            preimage, amount, alice, timelock, eve, address(0), 0, bytes32(0), 27, bytes32(uint256(1)), bytes32(0)
        );

        assertEq(eve.balance, 0, "eve must not receive anything");
        assertEq(address(htlc).balance, amount, "htlc must still hold the coins");
    }

    /// Every signature has a second form — same `r`, `n - s`, and the other recovery id —
    /// that recovers the same signer. Nothing here keys off the signature bytes (a
    /// settlement consumes the swap key, cleared before the transfer), so this is a closed
    /// door rather than a fixed leak. Asserted so it stays closed.
    function test_redeemBySig_malleatedSignature_reverts() public {
        _aliceCreate(bob);

        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(bobPk, eve, eve);

        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flippedS = bytes32(n - uint256(s));
        // The recovery id is 27 or 28; the counterpart is the other one. `v ^ 1` would
        // give 26, which is not a recovery id at all and would fail for the wrong reason.
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, flippedS));
        htlc.redeemBySig(preimage, amount, alice, timelock, eve, address(0), 0, bytes32(0), flippedV, r, flippedS);

        assertEq(eve.balance, 0, "the malleated form must settle nothing");
    }

    // -- No payout may target address(0) --

    function test_refundToZeroDestination_reverts() public {
        _aliceCreate(bob);
        vm.warp(timelock);

        vm.prank(alice);
        vm.expectRevert(HTLCNative.ZeroRecipient.selector);
        htlc.refund(preimageHash, amount, bob, timelock, address(0));

        assertEq(address(htlc).balance, amount, "nothing burned");
    }

    function test_recoverExcessToZeroAddress_reverts() public {
        vm.deal(address(htlc), 1 ether);

        vm.expectRevert(HTLCNative.ZeroRecipient.selector);
        htlc.recoverExcess(payable(address(0)));

        assertEq(address(htlc).balance, 1 ether, "nothing burned");
    }

    // -- Valid paths still settle --

    function test_redeem_validPreimage_stillWorks() public {
        _aliceCreate(bob);

        vm.prank(bob);
        htlc.redeem(preimage, amount, alice, timelock);

        assertEq(bob.balance, amount, "bob receives the coins");
    }

    function test_redeemBySig_validSignature_stillWorks() public {
        _aliceCreate(bob);

        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(bobPk, eve, eve);

        vm.prank(eve);
        address recovered = htlc.redeemBySig(preimage, amount, alice, timelock, eve, address(0), 0, bytes32(0), v, r, s);

        assertEq(recovered, bob, "should recover bob");
        assertEq(eve.balance, amount, "caller receives the coins");
    }

    // -- Helpers --

    function _aliceCreate(address claimAddress) internal {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, claimAddress, timelock);
    }

    function _signRedeem(uint256 pk, address caller, address destination)
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
                        preimage,
                        amount,
                        alice,
                        timelock,
                        caller,
                        destination,
                        address(0),
                        uint256(0),
                        bytes32(0)
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }
}
