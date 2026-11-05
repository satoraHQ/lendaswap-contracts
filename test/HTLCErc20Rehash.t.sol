// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {HTLCErc20, SwapKey} from "../src/HTLCErc20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 100e18);
    }
}

/// @notice `rehash` moves an active lock to a new hash and timelock without moving
///         tokens. The sender calls, the claimAddress signs — the same consent as
///         `refundBySig`.
contract HTLCErc20RehashTest is Test {
    HTLCErc20 htlc;
    MockToken token;

    address alice = makeAddr("alice");
    address relay = makeAddr("relay");
    address bob;
    uint256 bobPk;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    bytes32 newPreimage = bytes32(uint256(0xcafe));
    bytes32 newPreimageHash;
    uint256 amount = 1e18;
    uint256 timelock;
    uint256 newTimelock;
    SwapKey key;
    SwapKey newKey;

    function setUp() public {
        (bob, bobPk) = makeAddrAndKey("bob");
        htlc = new HTLCErc20(address(this));
        token = new MockToken();
        preimageHash = sha256(abi.encodePacked(preimage));
        newPreimageHash = sha256(abi.encodePacked(newPreimage));
        timelock = block.timestamp + 1 hours;
        newTimelock = block.timestamp + 2 hours;
        token.transfer(alice, 10e18);
        key = htlc.computeKey(preimageHash, amount, address(token), alice, bob, timelock);
        newKey = htlc.computeKey(newPreimageHash, amount, address(token), alice, bob, newTimelock);

        vm.startPrank(alice);
        token.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(token), bob, timelock);
        vm.stopPrank();
    }

    // -- Happy path --

    function test_rehash_movesTheLock() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);

        vm.expectEmit(true, true, true, true, address(htlc));
        emit HTLCErc20.SwapRehashed(preimageHash, key, newKey, newPreimageHash);

        vm.prank(alice);
        (address recovered, SwapKey returnedKey) =
            htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);

        assertEq(recovered, bob, "recovers the claimAddress");
        assertEq(SwapKey.unwrap(returnedKey), SwapKey.unwrap(newKey), "returns the new key");

        (HTLCErc20.SwapState oldState,) = htlc.swapState(key);
        (HTLCErc20.SwapState newState,) = htlc.swapState(newKey);
        assertEq(uint8(oldState), uint8(HTLCErc20.SwapState.Rehashed), "old key is Rehashed");
        assertEq(uint8(newState), uint8(HTLCErc20.SwapState.Active), "new key is Active");
        assertFalse(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock));
        assertTrue(htlc.isActive(newPreimageHash, amount, address(token), alice, bob, newTimelock));
    }

    function test_rehash_movesNoTokens() public {
        uint256 lockedBefore = htlc.lockedAmounts(address(token));
        uint256 balanceBefore = token.balanceOf(address(htlc));

        _rehash();

        assertEq(htlc.lockedAmounts(address(token)), lockedBefore, "lockedAmounts unchanged");
        assertEq(token.balanceOf(address(htlc)), balanceBefore, "htlc balance unchanged");
        assertEq(token.balanceOf(alice), 9e18, "sender received nothing");
        assertEq(token.balanceOf(bob), 0, "claimAddress received nothing");
    }

    function test_rehash_newKeyRedeemsWithNewPreimage() public {
        _rehash();

        vm.prank(bob);
        htlc.redeem(newPreimage, amount, address(token), alice, newTimelock);

        assertEq(token.balanceOf(bob), amount, "bob redeemed under the new hash");
        assertEq(htlc.lockedAmounts(address(token)), 0, "accounting settles to zero");
        (HTLCErc20.SwapState state, bytes32 stored) = htlc.swapState(newKey);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.Redeemed));
        assertEq(stored, newPreimage);
    }

    function test_rehash_newKeyRefundsAfterNewTimelock() public {
        _rehash();

        vm.warp(timelock); // old timelock passed, new one not
        vm.prank(alice);
        vm.expectRevert(HTLCErc20.TimelockNotExpired.selector);
        htlc.refund(newPreimageHash, amount, address(token), bob, newTimelock);

        vm.warp(newTimelock);
        vm.prank(alice);
        htlc.refund(newPreimageHash, amount, address(token), bob, newTimelock);
        assertEq(token.balanceOf(alice), 10e18, "alice made whole");
    }

    function test_rehash_newKeyCollabRefunds() public {
        _rehash();

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(htlc.TYPEHASH_REFUND(), newPreimageHash, amount, address(token), alice, newTimelock)
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(alice);
        htlc.refundBySig(newPreimageHash, amount, address(token), newTimelock, v, r, s);
        assertEq(token.balanceOf(alice), 10e18, "alice made whole before the timelock");
    }

    // -- A rehash never shortens the timelock --

    function test_rehash_shorterTimelock_reverts() public {
        uint256 shorter = timelock - 30 minutes;
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, shorter);

        vm.prank(alice);
        vm.expectRevert(HTLCErc20.TimelockShortened.selector);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, shorter, v, r, s);

        assertTrue(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock), "old lock untouched");
    }

    function test_rehash_equalTimelock_succeeds() public {
        SwapKey equalKey = htlc.computeKey(newPreimageHash, amount, address(token), alice, bob, timelock);
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, timelock);

        vm.prank(alice);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, timelock, v, r, s);

        (HTLCErc20.SwapState state,) = htlc.swapState(equalKey);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.Active));
    }

    function test_rehash_longerTimelock_succeeds() public {
        uint256 longer = timelock + 30 minutes;
        SwapKey longerKey = htlc.computeKey(newPreimageHash, amount, address(token), alice, bob, longer);
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, longer);

        vm.prank(alice);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, longer, v, r, s);

        (HTLCErc20.SwapState state,) = htlc.swapState(longerKey);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.Active));
    }

    function test_rehash_afterOldTimelockExpired() public {
        // An expired-but-unsettled lock can still be moved; the sender could refund
        // it unilaterally, so a rehash it calls for takes nothing from it.
        vm.warp(timelock + 1);
        newTimelock = block.timestamp + 1 hours;
        _rehash();
        assertTrue(htlc.isActive(newPreimageHash, amount, address(token), alice, bob, newTimelock));
    }

    // -- The old key is spent --

    function test_rehash_oldKeyCannotRedeem() public {
        _rehash();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Rehashed));
        htlc.redeem(preimage, amount, address(token), alice, timelock);
    }

    function test_rehash_oldKeyCannotRefund() public {
        _rehash();
        vm.warp(timelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Rehashed));
        htlc.refund(preimageHash, amount, address(token), bob, timelock);
    }

    function test_rehash_oldKeyCannotRedeemBySig() public {
        _rehash();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        preimage,
                        amount,
                        address(token),
                        alice,
                        timelock,
                        relay,
                        relay,
                        address(0),
                        uint256(0),
                        bytes32(0)
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(relay);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Rehashed));
        htlc.redeemBySig(
            preimage, amount, address(token), alice, timelock, relay, address(0), 0, bytes32(0), v, r, s
        );
    }

    function test_rehash_oldKeyCannotRefundBySig() public {
        _rehash();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(htlc.TYPEHASH_REFUND(), preimageHash, amount, address(token), alice, timelock))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Rehashed));
        htlc.refundBySig(preimageHash, amount, address(token), timelock, v, r, s);
    }

    /// A rehash-created key is an ordinary active lock: it can be moved again.
    function test_rehash_chained() public {
        _rehash();

        bytes32 thirdPreimage = bytes32(uint256(0xf00d));
        bytes32 thirdHash = sha256(abi.encodePacked(thirdPreimage));
        uint256 thirdTimelock = newTimelock + 1 hours;
        SwapKey thirdKey = htlc.computeKey(thirdHash, amount, address(token), alice, bob, thirdTimelock);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REHASH(),
                        newPreimageHash,
                        amount,
                        address(token),
                        alice,
                        newTimelock,
                        thirdHash,
                        thirdTimelock
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(alice);
        (, SwapKey returned) =
            htlc.rehash(newPreimageHash, amount, address(token), newTimelock, thirdHash, thirdTimelock, v, r, s);
        assertEq(SwapKey.unwrap(returned), SwapKey.unwrap(thirdKey));

        (HTLCErc20.SwapState s1,) = htlc.swapState(key);
        (HTLCErc20.SwapState s2,) = htlc.swapState(newKey);
        (HTLCErc20.SwapState s3,) = htlc.swapState(thirdKey);
        assertEq(uint8(s1), uint8(HTLCErc20.SwapState.Rehashed), "first key spent");
        assertEq(uint8(s2), uint8(HTLCErc20.SwapState.Rehashed), "second key spent");
        assertEq(uint8(s3), uint8(HTLCErc20.SwapState.Active), "third key live");
        assertEq(htlc.lockedAmounts(address(token)), amount, "still one lock");

        vm.prank(bob);
        htlc.redeem(thirdPreimage, amount, address(token), alice, thirdTimelock);
        assertEq(token.balanceOf(bob), amount);
        assertEq(htlc.lockedAmounts(address(token)), 0);
    }

    function test_rehash_replay_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Rehashed));
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
    }

    function test_rehash_afterRedeem_reverts() public {
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(token), alice, timelock);

        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Redeemed));
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
    }

    function test_rehash_afterRefund_reverts() public {
        vm.warp(timelock);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, address(token), bob, timelock);

        newTimelock = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Refunded));
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
    }

    function test_rehash_rehashedKeyCannotBeCreatedAgain() public {
        _rehash();
        vm.startPrank(alice);
        token.approve(address(htlc), amount);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapExists.selector, key, HTLCErc20.SwapState.Rehashed));
        htlc.create(preimageHash, amount, address(token), bob, timelock);
        vm.stopPrank();
    }

    /// Two rehash signatures over the same key: whichever lands first spends the key
    /// and kills the other. This is why the signatures carry no expiry.
    function test_rehash_secondSignatureDiesWithTheFirst() public {
        bytes32 otherHash = sha256(abi.encodePacked(bytes32(uint256(0xbeef))));
        (uint8 v1, bytes32 r1, bytes32 s1) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        (uint8 v2, bytes32 r2, bytes32 s2) = _signRehash(bobPk, alice, otherHash, newTimelock);

        vm.prank(alice);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v1, r1, s1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Rehashed));
        htlc.rehash(preimageHash, amount, address(token), timelock, otherHash, newTimelock, v2, r2, s2);
        assertFalse(htlc.isActive(otherHash, amount, address(token), alice, bob, newTimelock));
    }

    // -- Consent --

    function test_rehash_wrongCaller_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(relay);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
        assertTrue(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock), "untouched");
    }

    function test_rehash_wrongSigner_reverts() public {
        (, uint256 evePk) = makeAddrAndKey("eve");
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(evePk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
    }

    /// The claimAddress can sign and submit on its own, but then it is the sender in
    /// the key, and no lock was ever created under it.
    function test_rehash_claimAddressAlone_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, bob, newPreimageHash, newTimelock);
        vm.prank(bob);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
        assertTrue(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock), "untouched");
    }

    /// The signature binds the new terms: a sender cannot keep bob's signature and
    /// pick a different hash or timelock.
    function test_rehash_substitutedNewTerms_reverts() public {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        bytes32 otherHash = sha256(abi.encodePacked(bytes32(uint256(0xbeef))));

        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.rehash(preimageHash, amount, address(token), timelock, otherHash, newTimelock, v, r, s);

        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock + 1, v, r, s);
    }

    function test_rehash_garbageSignature_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        htlc.rehash(
            preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, 27, bytes32(uint256(1)), 0
        );
    }

    // -- New terms --

    function test_rehash_newTimelockInThePast_reverts() public {
        uint256 past = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, past);
        vm.prank(alice);
        vm.expectRevert(HTLCErc20.TimelockTooSoon.selector);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, past, v, r, s);
    }

    function test_rehash_sameTerms_reverts() public {
        // new key == old key, which is Active
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, preimageHash, timelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapExists.selector, key, HTLCErc20.SwapState.Active));
        htlc.rehash(preimageHash, amount, address(token), timelock, preimageHash, timelock, v, r, s);
    }

    function test_rehash_ontoSettledKey_reverts() public {
        // Bob already redeemed a swap under the new terms once; its preimage is public.
        vm.startPrank(alice);
        token.approve(address(htlc), amount);
        htlc.create(newPreimageHash, amount, address(token), bob, newTimelock);
        vm.stopPrank();
        vm.prank(bob);
        htlc.redeem(newPreimage, amount, address(token), alice, newTimelock);

        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HTLCErc20.SwapExists.selector, newKey, HTLCErc20.SwapState.Redeemed)
        );
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
    }

    /// Anyone can `create` under any key with their own tokens, so a third party who
    /// sees the agreed new terms can squat the new key and make the rehash revert. The
    /// squatter's tokens are then locked under terms the claimAddress may redeem; the
    /// original lock is untouched and can be moved again under fresh terms.
    function test_rehash_ontoSquattedKey_reverts() public {
        address squatter = makeAddr("squatter");
        token.transfer(squatter, amount);
        vm.startPrank(squatter);
        token.approve(address(htlc), amount);
        htlc.create(newPreimageHash, amount, address(token), alice, bob, newTimelock);
        vm.stopPrank();

        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapExists.selector, newKey, HTLCErc20.SwapState.Active));
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
        assertTrue(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock), "original untouched");

        // The squatter paid for bob's lock.
        vm.prank(bob);
        htlc.redeem(newPreimage, amount, address(token), alice, newTimelock);
        assertEq(token.balanceOf(bob), amount);

        // And the original moves under other terms.
        bytes32 otherHash = sha256(abi.encodePacked(bytes32(uint256(0xbeef))));
        (v, r, s) = _signRehash(bobPk, alice, otherHash, newTimelock);
        vm.prank(alice);
        htlc.rehash(preimageHash, amount, address(token), timelock, otherHash, newTimelock, v, r, s);
        assertTrue(htlc.isActive(otherHash, amount, address(token), alice, bob, newTimelock));
        assertEq(htlc.lockedAmounts(address(token)), amount, "one lock left");
    }

    // -- Accounting under interleaving --

    /// Several locks, each rehashed zero or more times and then redeemed, refunded or
    /// left open in any order: `lockedAmounts` always equals the sum of active locks and
    /// the balance always covers it.
    function testFuzz_rehash_conservesAccounting(uint8 plan, uint64 amountSeed) public {
        uint256 n = 3;
        uint256[] memory amounts = new uint256[](n);
        bytes32[] memory hashes = new bytes32[](n);
        uint256[] memory locks = new uint256[](n);
        uint256 expectedLocked = htlc.lockedAmounts(address(token)); // the setUp lock

        for (uint256 i; i < n; i++) {
            amounts[i] = bound(uint256(amountSeed) + i * 7919, 1, 2e18);
            hashes[i] = sha256(abi.encodePacked(bytes32(uint256(0x1000 + i))));
            locks[i] = block.timestamp + 1 hours + i;
            vm.startPrank(alice);
            token.approve(address(htlc), amounts[i]);
            htlc.create(hashes[i], amounts[i], address(token), bob, locks[i]);
            vm.stopPrank();
            expectedLocked += amounts[i];
        }

        for (uint256 i; i < n; i++) {
            // two bits per swap: bit0 = rehash first, bit1 = settle (redeem) / else refund-or-leave
            bool doRehash = (plan >> (2 * i)) & 1 == 1;
            bool doRedeem = (plan >> (2 * i + 1)) & 1 == 1;
            bytes32 curPreimage = bytes32(uint256(0x1000 + i));

            if (doRehash) {
                bytes32 nextPreimage = bytes32(uint256(0x2000 + i));
                bytes32 nextHash = sha256(abi.encodePacked(nextPreimage));
                uint256 nextLock = locks[i] + 1 hours;
                bytes32 digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        htlc.DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                htlc.TYPEHASH_REHASH(),
                                hashes[i],
                                amounts[i],
                                address(token),
                                alice,
                                locks[i],
                                nextHash,
                                nextLock
                            )
                        )
                    )
                );
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);
                vm.prank(alice);
                htlc.rehash(hashes[i], amounts[i], address(token), locks[i], nextHash, nextLock, v, r, s);
                assertEq(htlc.lockedAmounts(address(token)), expectedLocked, "rehash moves nothing");
                hashes[i] = nextHash;
                locks[i] = nextLock;
                curPreimage = nextPreimage;
            }

            if (doRedeem) {
                vm.prank(bob);
                htlc.redeem(curPreimage, amounts[i], address(token), alice, locks[i]);
                expectedLocked -= amounts[i];
            } else if (i % 2 == 0) {
                vm.warp(locks[i]);
                vm.prank(alice);
                htlc.refund(hashes[i], amounts[i], address(token), bob, locks[i]);
                expectedLocked -= amounts[i];
            }

            assertEq(htlc.lockedAmounts(address(token)), expectedLocked, "obligation tracks settlements");
            assertGe(token.balanceOf(address(htlc)), htlc.lockedAmounts(address(token)), "balance covers it");
        }

        // Whatever is still open remains payable in full.
        for (uint256 i; i < n; i++) {
            if (htlc.isActive(hashes[i], amounts[i], address(token), alice, bob, locks[i])) {
                uint256 before = token.balanceOf(bob);
                vm.warp(locks[i]);
                vm.prank(alice);
                htlc.refund(hashes[i], amounts[i], address(token), bob, locks[i]);
                assertEq(token.balanceOf(bob), before);
            }
        }
        assertEq(htlc.lockedAmounts(address(token)), amount, "only the setUp lock remains");
        assertEq(token.balanceOf(address(htlc)), amount, "nothing stranded");
    }

    // -- Helpers --

    function _rehash() internal {
        (uint8 v, bytes32 r, bytes32 s) = _signRehash(bobPk, alice, newPreimageHash, newTimelock);
        vm.prank(alice);
        htlc.rehash(preimageHash, amount, address(token), timelock, newPreimageHash, newTimelock, v, r, s);
    }

    function _signRehash(uint256 pk, address sender, bytes32 _newPreimageHash, uint256 _newTimelock)
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
                        htlc.TYPEHASH_REHASH(),
                        preimageHash,
                        amount,
                        address(token),
                        sender,
                        timelock,
                        _newPreimageHash,
                        _newTimelock
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }
}
