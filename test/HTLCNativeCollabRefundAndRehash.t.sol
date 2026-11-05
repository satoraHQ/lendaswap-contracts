// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {HTLCNative, SwapKey} from "../src/HTLCNative.sol";

/// A sender that re-enters the HTLC from its receive hook during a refundBySig payout.
contract ReenteringSender {
    HTLCNative immutable htlc;
    bytes32 preimageHash;
    uint256 amount;
    address claim;
    uint256 timelock;
    bool public hookRan;
    bytes4 public reentryError;

    constructor(HTLCNative _htlc) {
        htlc = _htlc;
    }

    function lock(bytes32 h, address c, uint256 tl) external payable {
        preimageHash = h;
        amount = msg.value;
        claim = c;
        timelock = tl;
        htlc.create{value: msg.value}(h, c, tl);
    }

    function collabRefund(uint8 v, bytes32 r, bytes32 s) external {
        htlc.refundBySig(preimageHash, amount, timelock, v, r, s);
    }

    receive() external payable {
        hookRan = true;
        try htlc.refund(preimageHash, amount, claim, timelock) {}
        catch (bytes memory data) {
            reentryError = bytes4(data);
        }
    }
}

/// @notice HTLCNative v2: `refundBySig` and `rehash`, consented to by the sender as
///         caller and the claimAddress as signer. Mirrors the ERC20 suites.
contract HTLCNativeCollabRefundAndRehashTest is Test {
    HTLCNative htlc;

    address alice = makeAddr("alice");
    address relay = makeAddr("relay");
    address bob;
    uint256 bobPk;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    bytes32 newPreimage = bytes32(uint256(0xcafe));
    bytes32 newPreimageHash;
    uint256 amount = 1 ether;
    uint256 timelock;
    uint256 newTimelock;
    SwapKey key;
    SwapKey newKey;

    function setUp() public {
        (bob, bobPk) = makeAddrAndKey("bob");
        htlc = new HTLCNative(address(this));
        preimageHash = sha256(abi.encodePacked(preimage));
        newPreimageHash = sha256(abi.encodePacked(newPreimage));
        timelock = block.timestamp + 1 hours;
        newTimelock = block.timestamp + 2 hours;
        vm.deal(alice, 10 ether);
        key = htlc.computeKey(preimageHash, amount, address(0), alice, bob, timelock);
        newKey = htlc.computeKey(newPreimageHash, amount, address(0), alice, bob, newTimelock);

        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
    }

    // ---------------------------------------------------------------
    // refundBySig
    // ---------------------------------------------------------------

    function test_refundBySig_beforeTimelock() public {
        assertLt(block.timestamp, timelock);
        (uint8 v, bytes32 r, bytes32 s) = _signRefund(bobPk, alice);

        vm.prank(alice);
        address recovered = htlc.refundBySig(preimageHash, amount, timelock, v, r, s);

        assertEq(recovered, bob);
        assertEq(alice.balance, 10 ether, "alice made whole");
        assertEq(htlc.lockedTotal(), 0);
        (HTLCNative.SwapState state,) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Refunded));
    }

    function test_refundBySig_wrongSigner_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRefund(0xA11CE, alice);
        vm.prank(alice);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, amount, timelock, v, r, s);
    }

    function test_refundBySig_wrongCaller_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRefund(bobPk, alice);
        vm.prank(relay);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, amount, timelock, v, r, s);
        assertEq(htlc.lockedTotal(), amount, "nothing moved");
    }

    function test_refundBySig_claimAddressCannotRefundToItself_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRefund(bobPk, bob);
        vm.prank(bob);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, amount, timelock, v, r, s);
        assertEq(bob.balance, 0, "bob must not receive anything");
        assertEq(address(htlc).balance, amount);
    }

    function test_refundBySig_replay_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRefund(bobPk, alice);
        vm.prank(alice);
        htlc.refundBySig(preimageHash, amount, timelock, v, r, s);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Refunded));
        htlc.refundBySig(preimageHash, amount, timelock, v, r, s);
    }

    function test_refundBySig_garbageSignature_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        htlc.refundBySig(preimageHash, amount, timelock, 27, bytes32(uint256(1)), 0);
    }

    function test_refundBySig_payout_cannotReenter() public {
        ReenteringSender sender = new ReenteringSender(htlc);
        bytes32 h2 = sha256(abi.encodePacked(bytes32(uint256(0xbeef))));
        sender.lock{value: amount}(h2, bob, timelock);
        (uint8 v, bytes32 r, bytes32 s) = _signRefundFor(bobPk, h2, address(sender));

        sender.collabRefund(v, r, s);

        assertTrue(sender.hookRan(), "the payout reached the hook");
        assertEq(sender.reentryError(), HTLCNative.Reentrancy.selector, "re-entry hits the guard");
        assertEq(address(sender).balance, amount, "the outer refund paid out");
        assertEq(htlc.lockedTotal(), amount, "alice's swap is still owed");
    }

    // ---------------------------------------------------------------
    // rehash
    // ---------------------------------------------------------------

    function test_rehash_movesTheLock() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);

        vm.expectEmit(true, true, true, true, address(htlc));
        emit HTLCNative.SwapRehashed(preimageHash, key, newKey, newPreimageHash);

        vm.prank(alice);
        (address recovered, SwapKey returned) =
            htlc.rehash(preimageHash, amount, timelock, newPreimageHash, newTimelock, v, r, s);

        assertEq(recovered, bob);
        assertEq(SwapKey.unwrap(returned), SwapKey.unwrap(newKey));
        (HTLCNative.SwapState oldState,) = htlc.swapState(key);
        (HTLCNative.SwapState newState,) = htlc.swapState(newKey);
        assertEq(uint8(oldState), uint8(HTLCNative.SwapState.Rehashed));
        assertEq(uint8(newState), uint8(HTLCNative.SwapState.Active));
        assertEq(htlc.lockedTotal(), amount, "lockedTotal unchanged");
        assertEq(address(htlc).balance, amount, "balance unchanged");
        assertEq(alice.balance, 9 ether, "sender received nothing");
    }

    function test_rehash_newKeyRedeemsWithNewPreimage() public {
        _rehash();
        vm.prank(bob);
        htlc.redeem(newPreimage, amount, alice, newTimelock);
        assertEq(bob.balance, amount);
        assertEq(htlc.lockedTotal(), 0);
    }

    function test_rehash_newKeyRefundsAfterNewTimelock() public {
        _rehash();
        vm.warp(timelock);
        vm.prank(alice);
        vm.expectRevert(HTLCNative.TimelockNotExpired.selector);
        htlc.refund(newPreimageHash, amount, bob, newTimelock);

        vm.warp(newTimelock);
        vm.prank(alice);
        htlc.refund(newPreimageHash, amount, bob, newTimelock);
        assertEq(alice.balance, 10 ether);
    }

    function test_rehash_newKeyCollabRefunds() public {
        _rehash();
        (uint8 v, bytes32 r, bytes32 s) = _signRefundFor(bobPk, newPreimageHash, alice, newTimelock);
        vm.prank(alice);
        htlc.refundBySig(newPreimageHash, amount, newTimelock, v, r, s);
        assertEq(alice.balance, 10 ether);
    }

    function test_rehash_oldKeyIsSpent() public {
        _rehash();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Rehashed));
        htlc.redeem(preimage, amount, alice, timelock);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapExists.selector, key, HTLCNative.SwapState.Rehashed));
        htlc.create{value: amount}(preimageHash, bob, timelock);

        vm.warp(timelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Rehashed));
        htlc.refund(preimageHash, amount, bob, timelock);
    }

    function test_rehash_secondSignatureDiesWithTheFirst() public {
        bytes32 otherHash = sha256(abi.encodePacked(bytes32(uint256(0xbeef))));
        (uint8 v1, bytes32 r1, bytes32 s1) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        (uint8 v2, bytes32 r2, bytes32 s2) = _signRehash(bobPk, alice, otherHash, newTimelock);

        vm.prank(alice);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, newTimelock, v1, r1, s1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Rehashed));
        htlc.rehash(preimageHash, amount, timelock, otherHash, newTimelock, v2, r2, s2);
    }

    function test_rehash_wrongCaller_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(relay);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, newTimelock, v, r, s);
    }

    function test_rehash_claimAddressAlone_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, bob, newPreimageHash, newTimelock);
        vm.prank(bob);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, newTimelock, v, r, s);
        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "untouched");
    }

    function test_rehash_substitutedNewTerms_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, newTimelock + 1, v, r, s);
    }

    function test_rehash_newTimelockInThePast_reverts() public {
        uint256 past = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, past);
        vm.prank(alice);
        vm.expectRevert(HTLCNative.TimelockTooSoon.selector);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, past, v, r, s);
    }

    function test_rehash_shorterTimelock_reverts() public {
        uint256 shorter = timelock - 30 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, shorter);

        vm.prank(alice);
        vm.expectRevert(HTLCNative.TimelockShortened.selector);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, shorter, v, r, s);

        (HTLCNative.SwapState state,) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Active), "old lock untouched");
    }

    function test_rehash_equalTimelock_succeeds() public {
        SwapKey equalKey = htlc.computeKey(newPreimageHash, amount, address(0), alice, bob, timelock);
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, timelock);

        vm.prank(alice);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, timelock, v, r, s);

        (HTLCNative.SwapState state,) = htlc.swapState(equalKey);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Active));
    }

    function test_rehash_longerTimelock_succeeds() public {
        uint256 longer = timelock + 30 minutes;
        SwapKey longerKey = htlc.computeKey(newPreimageHash, amount, address(0), alice, bob, longer);
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, longer);

        vm.prank(alice);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, longer, v, r, s);

        (HTLCNative.SwapState state,) = htlc.swapState(longerKey);
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Active));
    }

    function test_rehash_sameTerms_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, preimageHash, timelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapExists.selector, key, HTLCNative.SwapState.Active));
        htlc.rehash(preimageHash, amount, timelock, preimageHash, timelock, v, r, s);
    }

    function test_rehash_ontoSettledKey_reverts() public {
        vm.prank(alice);
        htlc.create{value: amount}(newPreimageHash, bob, newTimelock);
        vm.prank(bob);
        htlc.redeem(newPreimage, amount, alice, newTimelock);

        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapExists.selector, newKey, HTLCNative.SwapState.Redeemed));
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, newTimelock, v, r, s);
    }

    // -- Helpers --

    function _rehash() internal {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        htlc.rehash(preimageHash, amount, timelock, newPreimageHash, newTimelock, v, r, s);
    }

    function _signRefund(uint256 pk, address sender) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        return _signRefundFor(pk, preimageHash, sender, timelock);
    }

    function _signRefundFor(uint256 pk, bytes32 _hash, address sender)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return _signRefundFor(pk, _hash, sender, timelock);
    }

    function _signRefundFor(uint256 pk, bytes32 _hash, address sender, uint256 _timelock)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(htlc.TYPEHASH_REFUND(), _hash, amount, sender, _timelock))
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }

    function _signRehash(uint256 pk, address sender, bytes32 _newHash, uint256 _newTimelock)
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
                        htlc.TYPEHASH_REHASH(), preimageHash, amount, sender, timelock, _newHash, _newTimelock
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }
}
