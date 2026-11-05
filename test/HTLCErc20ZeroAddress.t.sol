// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {HTLCErc20, SwapKey} from "../src/HTLCErc20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice A recovered signer authorises nothing until the recovery is known to have
///         succeeded, and no swap may name address(0) as either party.
/// @dev A `*BySig` path derives its swap key from the recovered address, so a recovery
///      that resolved to address(0) would derive a valid key for a swap whose claimAddress
///      is address(0). Both layers are covered: such a swap cannot be created, and a
///      recovery that does not succeed reverts rather than resolving to address(0).
contract HTLCErc20ZeroAddressTest is Test {
    /// @dev `swaps` sits behind `Ownable2Step`'s `_owner` and `_pendingOwner`. Confirmed
    ///      with `forge inspect HTLCErc20 storage`; re-check it if the base changes, or
    ///      the seeded swap silently lands nowhere and the theft test proves nothing.
    uint256 internal constant SWAPS_SLOT = 2;
    uint256 internal constant LOCKED_AMOUNTS_SLOT = 3;

    HTLCErc20 htlc;
    MockToken token;

    uint256 alicePk;
    address alice;
    uint256 bobPk;
    address bob;
    address eve = makeAddr("eve");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 100e18;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20(address(this));
        token = new MockToken();

        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        token.transfer(alice, 10_000e18);
        vm.prank(alice);
        token.approve(address(htlc), type(uint256).max);
    }

    // -- The swap that makes the theft possible cannot be created --

    function test_create_zeroClaimAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCErc20.ZeroClaimAddress.selector);
        htlc.create(preimageHash, amount, address(token), address(0), timelock);
    }

    function test_createWithRefundAddress_zeroClaimAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCErc20.ZeroClaimAddress.selector);
        htlc.create(preimageHash, amount, address(token), alice, address(0), timelock);
    }

    /// The same omission on the fund-loss side: nobody could reclaim this after timelock.
    function test_createWithRefundAddress_zeroRefundAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(HTLCErc20.ZeroRefundAddress.selector);
        htlc.create(preimageHash, amount, address(token), address(0), bob, timelock);
    }

    // -- A failed recovery is not an authorisation --

    function test_refundBySig_garbageSignature_reverts() public {
        _aliceCreate(bob);

        vm.prank(eve);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        htlc.refundBySig(
            preimageHash,
            amount,
            address(token),
            timelock,
            27,
            bytes32(uint256(1)),
            bytes32(0) // s = 0 has no valid recovery
        );
    }

    function test_redeemBySig_garbageSignature_reverts() public {
        _aliceCreate(bob);

        vm.prank(eve);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        htlc.redeemBySig(
            preimage,
            amount,
            address(token),
            alice,
            timelock,
            eve,
            address(token),
            0,
            bytes32(0),
            27,
            bytes32(uint256(1)),
            bytes32(0)
        );
    }

    /// Seeds a zero-claim swap straight into storage — the state a contract without the
    /// creation guard could already hold — and shows the recovery check alone stops it.
    ///
    /// `lockedAmounts` is seeded alongside `swaps` so the state matches what `create`
    /// would have produced. Without it the settlement underflows on the decrement and
    /// reverts for that reason instead, which would leave the theft itself untested.
    function test_preExistingZeroClaimSwap_cannotBeStolen() public {
        SwapKey key = htlc.computeKey(preimageHash, amount, address(token), alice, address(0), timelock);
        vm.store(address(htlc), keccak256(abi.encode(key, SWAPS_SLOT)), bytes32(uint256(1)));
        vm.store(address(htlc), keccak256(abi.encode(address(token), LOCKED_AMOUNTS_SLOT)), bytes32(amount));
        token.transfer(address(htlc), amount);

        assertEq(htlc.lockedAmounts(address(token)), amount, "accounting must match the swap");

        assertTrue(
            htlc.isActive(preimageHash, amount, address(token), alice, address(0), timelock),
            "the seeded swap must actually be in storage, or this test proves nothing"
        );

        vm.prank(eve);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        htlc.refundBySig(
            preimageHash,
            amount,
            address(token),
            timelock,
            27,
            bytes32(uint256(1)),
            bytes32(0)
        );

        assertEq(token.balanceOf(eve), 0, "eve must not receive anything");
        assertEq(token.balanceOf(address(htlc)), amount, "htlc must still hold the tokens");
    }

    /// Every signature has a second form — same `r`, `n - s`, and the other recovery id —
    /// that recovers the same signer. Nothing here keys off the signature bytes (a
    /// settlement consumes the swap key, cleared before the transfer), so this is a closed
    /// door rather than a fixed leak. Asserted so it stays closed.
    function test_refundBySig_malleatedSignature_reverts() public {
        _aliceCreate(bob);

        (uint8 v, bytes32 r, bytes32 s) = _signRefund(bobPk, alice);

        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flippedS = bytes32(n - uint256(s));
        // The recovery id is 27 or 28; the counterpart is the other one. `v ^ 1` would
        // give 26, which is not a recovery id at all and would fail for the wrong reason.
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, flippedS));
        htlc.refundBySig(preimageHash, amount, address(token), timelock, flippedV, r, flippedS);

        assertEq(token.balanceOf(address(htlc)), amount, "the malleated form must settle nothing");
    }

    // -- Valid signatures still settle --

    function test_refundBySig_validSignature_stillWorks() public {
        _aliceCreate(bob);

        (uint8 v, bytes32 r, bytes32 s) = _signRefund(bobPk, alice);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        address recovered = htlc.refundBySig(preimageHash, amount, address(token), timelock, v, r, s);

        assertEq(recovered, bob, "should recover bob");
        assertEq(token.balanceOf(alice), aliceBefore + amount, "the sender receives the tokens");
    }

    function test_redeem_validPreimage_stillWorks() public {
        _aliceCreate(bob);

        vm.prank(bob);
        htlc.redeem(preimage, amount, address(token), alice, timelock);

        assertEq(token.balanceOf(bob), amount, "bob receives the tokens");
    }

    // -- Helpers --

    function _aliceCreate(address claimAddress) internal {
        vm.prank(alice);
        htlc.create(preimageHash, amount, address(token), claimAddress, timelock);
    }

    function _signRefund(uint256 pk, address sender) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(htlc.TYPEHASH_REFUND(), preimageHash, amount, address(token), sender, timelock))
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }
}
