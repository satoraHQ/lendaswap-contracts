// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCNative} from "../src/HTLCNative.sol";

/// @notice Only `claimAddress` can move an Active swap to Redeemed: directly as
///         msg.sender, or through an EIP-712 signature that binds the caller and every
///         execution parameter. Knowing the preimage is not enough.
contract HTLCNativeFrontRunningTest is Test {
    HTLCNative htlc;

    address alice = makeAddr("alice");
    address relayer = makeAddr("relayer");
    address attacker = makeAddr("attacker");

    uint256 bobPk;
    address bob;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1 ether;
    uint256 timelock;

    bytes32 callsHash = keccak256("calls");
    address sweepToken = makeAddr("sweepToken");
    uint256 minAmountOut = 123;

    function setUp() public {
        htlc = new HTLCNative(address(this));
        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
    }

    function _assertStillLocked() internal view {
        assertEq(attacker.balance, 0, "attacker should have 0");
        assertEq(address(htlc).balance, amount, "htlc should still hold the coins");
        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "swap still active");
    }

    // ---------------------------------------------------------------
    // Direct redeem: msg.sender must be claimAddress
    // ---------------------------------------------------------------

    function test_directRedeem_claimAddress_succeeds() public {
        vm.prank(bob);
        htlc.redeem(preimage, amount, alice, timelock);
        assertEq(bob.balance, amount, "bob should have the coins");
    }

    function test_directRedeem_attacker_reverts() public {
        // Attacker knows the preimage (e.g. from the mempool) but is not the claimAddress:
        // msg.sender = attacker, but the key was created with claimAddress = bob.
        vm.prank(attacker);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeem(preimage, amount, alice, timelock);
        _assertStillLocked();
    }

    function test_directRedeem_sender_reverts() public {
        // Not even the party that locked the funds can take the claim path.
        vm.prank(alice);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeem(preimage, amount, alice, timelock);
        _assertStillLocked();
    }

    // ---------------------------------------------------------------
    // Signature redeem: the signature binds caller and every execution parameter
    // ---------------------------------------------------------------

    function test_signatureRedeem_authorizedCaller_succeeds() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(relayer, bob, sweepToken, minAmountOut, callsHash);

        vm.prank(relayer);
        address recovered =
            htlc.redeemBySig(preimage, amount, alice, timelock, bob, sweepToken, minAmountOut, callsHash, v, r, s);

        assertEq(recovered, bob, "recovered address should be bob");
        assertEq(relayer.balance, amount, "the authorized caller is paid");
    }

    function test_signatureRedeem_attackerReplaysSignature_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(relayer, bob, sweepToken, minAmountOut, callsHash);

        // Same signature, different msg.sender: ecrecover yields a different address.
        vm.prank(attacker);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, sweepToken, minAmountOut, callsHash, v, r, s);
        _assertStillLocked();
    }

    function test_signatureRedeem_attackerMakesOwnSignature_reverts() public {
        (, uint256 attackerPk) = makeAddrAndKey("attacker");
        bytes32 digest = _digest(attacker, attacker, sweepToken, minAmountOut, callsHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, digest);

        // The key commits to claimAddress = bob, but recovery yields the attacker.
        vm.prank(attacker);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, attacker, sweepToken, minAmountOut, callsHash, v, r, s);
        _assertStillLocked();
    }

    function test_signatureRedeem_tamperedDestination_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(relayer, bob, sweepToken, minAmountOut, callsHash);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, attacker, sweepToken, minAmountOut, callsHash, v, r, s);
        _assertStillLocked();
    }

    function test_signatureRedeem_tamperedSweepToken_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(relayer, bob, sweepToken, minAmountOut, callsHash);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), minAmountOut, callsHash, v, r, s);
        _assertStillLocked();
    }

    function test_signatureRedeem_tamperedMinAmountOut_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(relayer, bob, sweepToken, minAmountOut, callsHash);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, sweepToken, 0, callsHash, v, r, s);
        _assertStillLocked();
    }

    function test_signatureRedeem_tamperedCallsHash_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(relayer, bob, sweepToken, minAmountOut, callsHash);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, sweepToken, minAmountOut, bytes32(0), v, r, s);
        _assertStillLocked();
    }

    function test_signatureRedeem_tamperedSwapTerms_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(relayer, bob, sweepToken, minAmountOut, callsHash);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount - 1, alice, timelock, bob, sweepToken, minAmountOut, callsHash, v, r, s);
        _assertStillLocked();
    }

    /// A signature is single-use by construction: the swap it names is consumed.
    function test_signatureRedeem_cannotBeReplayedAfterSettlement() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(relayer, bob, sweepToken, minAmountOut, callsHash);

        vm.prank(relayer);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, sweepToken, minAmountOut, callsHash, v, r, s);

        // Force-fund the contract so only the state check can stop a second payout.
        vm.deal(address(htlc), amount);
        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, sweepToken, minAmountOut, callsHash, v, r, s);
        assertEq(relayer.balance, amount, "paid exactly once");
    }

    // -- Helpers --

    function _digest(
        address caller,
        address destination,
        address _sweepToken,
        uint256 _minAmountOut,
        bytes32 _callsHash
    ) internal view returns (bytes32) {
        return keccak256(
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
                        _sweepToken,
                        _minAmountOut,
                        _callsHash
                    )
                )
            )
        );
    }

    function _sign(address caller, address destination, address _sweepToken, uint256 _minAmountOut, bytes32 _callsHash)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (v, r, s) = vm.sign(bobPk, _digest(caller, destination, _sweepToken, _minAmountOut, _callsHash));
    }
}
