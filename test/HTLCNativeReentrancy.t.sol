// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCNative} from "../src/HTLCNative.sol";

/// A recipient that re-enters the HTLC from its `receive` hook. It acts as a swap
/// party in its own right (claimant, refunder, even owner), so the reentrancy guard
/// is isolated as the only thing standing between the hook and the entry point.
contract Reenterer {
    enum Mode {
        None,
        Create,
        Redeem,
        Refund,
        Recover
    }

    HTLCNative public htlc;

    Mode public mode;
    bytes32 preimage;
    uint256 amount;
    address party;
    uint256 timelock;

    bool public hookRan;
    bool public reentrySucceeded;
    bytes4 public reentryError;

    constructor(HTLCNative _htlc) {
        htlc = _htlc;
    }

    receive() external payable {
        hookRan = true;
        Mode m = mode;
        if (m == Mode.None) return;
        mode = Mode.None;

        if (m == Mode.Create) {
            try htlc.create{value: 1}(sha256(abi.encodePacked(preimage)), party, timelock) {
                reentrySucceeded = true;
            } catch (bytes memory data) {
                reentryError = bytes4(data);
            }
        } else if (m == Mode.Redeem) {
            try htlc.redeem(preimage, amount, party, timelock) {
                reentrySucceeded = true;
            } catch (bytes memory data) {
                reentryError = bytes4(data);
            }
        } else if (m == Mode.Refund) {
            try htlc.refund(sha256(abi.encodePacked(preimage)), amount, party, timelock) {
                reentrySucceeded = true;
            } catch (bytes memory data) {
                reentryError = bytes4(data);
            }
        } else if (m == Mode.Recover) {
            try htlc.recoverExcess(payable(address(this))) {
                reentrySucceeded = true;
            } catch (bytes memory data) {
                reentryError = bytes4(data);
            }
        }
    }

    /// Schedule one re-entry for the next payout. `party` is the swap's sender for a
    /// redeem, its claimant for a create or refund.
    function arm(Mode m, bytes32 _preimage, uint256 _amount, address _party, uint256 _timelock) external {
        mode = m;
        preimage = _preimage;
        amount = _amount;
        party = _party;
        timelock = _timelock;
    }

    // -- Acting as a swap party --

    function create(bytes32 preimageHash, address claimAddress, uint256 _timelock) external payable {
        htlc.create{value: msg.value}(preimageHash, claimAddress, _timelock);
    }

    function redeem(bytes32 _preimage, uint256 _amount, address sender, uint256 _timelock) external {
        htlc.redeem(_preimage, _amount, sender, _timelock);
    }

    function redeemBySig(
        bytes32 _preimage,
        uint256 _amount,
        address sender,
        uint256 _timelock,
        address destination,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        htlc.redeemBySig(_preimage, _amount, sender, _timelock, destination, address(0), 0, bytes32(0), v, r, s);
    }

    function refund(bytes32 preimageHash, uint256 _amount, address claimAddress, uint256 _timelock) external {
        htlc.refund(preimageHash, _amount, claimAddress, _timelock);
    }

    function refundTo(bytes32 preimageHash, uint256 _amount, address claimAddress, uint256 _timelock, address to)
        external
    {
        htlc.refund(preimageHash, _amount, claimAddress, _timelock, to);
    }

    function acceptOwnership() external {
        htlc.acceptOwnership();
    }

    function recoverExcess() external {
        htlc.recoverExcess(payable(address(this)));
    }
}

/// A party that cannot take the native coin at all.
contract Rejecting {
    HTLCNative public htlc;

    constructor(HTLCNative _htlc) {
        htlc = _htlc;
    }

    receive() external payable {
        revert("no thanks");
    }

    function redeem(bytes32 preimage, uint256 amount, address sender, uint256 timelock) external {
        htlc.redeem(preimage, amount, sender, timelock);
    }

    function refund(bytes32 preimageHash, uint256 amount, address claimAddress, uint256 timelock) external {
        htlc.refund(preimageHash, amount, claimAddress, timelock);
    }

    function refundTo(bytes32 preimageHash, uint256 amount, address claimAddress, uint256 timelock, address to)
        external
    {
        htlc.refund(preimageHash, amount, claimAddress, timelock, to);
    }
}

/// @notice Every payout hands control to the recipient with all remaining gas. State,
///         `lockedTotal` and the event are final before that happens, and the transient
///         guard keeps the hook out of every state-changing entry point; a recipient that
///         cannot receive reverts the settlement atomically and the swap stays Active.
contract HTLCNativeReentrancyTest is Test {
    HTLCNative htlc;
    Reenterer reenterer;

    address alice = makeAddr("alice");
    uint256 bobPk;
    address bob;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1 ether;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCNative(address(this));
        reenterer = new Reenterer(htlc);
        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        vm.deal(alice, 10 ether);
        vm.deal(address(reenterer), 10 ether);
    }

    /// Two swaps with the reenterer as claimant, distinguished by timelock.
    function _lockTwoForReenterer() internal {
        vm.startPrank(alice);
        htlc.create{value: amount}(preimageHash, address(reenterer), timelock);
        htlc.create{value: amount}(preimageHash, address(reenterer), timelock + 1);
        vm.stopPrank();
        assertEq(htlc.lockedTotal(), 2 ether, "two swaps outstanding");
    }

    function _assertReentryBlocked() internal view {
        assertTrue(reenterer.hookRan(), "the payout reached the hook");
        assertFalse(reenterer.reentrySucceeded(), "re-entry must not succeed");
        assertEq(reenterer.reentryError(), HTLCNative.Reentrancy.selector, "re-entry hits the guard");
    }

    // -- Re-entering during a redeem payout --

    function test_redeemPayout_cannotReenterRedeem() public {
        _lockTwoForReenterer();
        reenterer.arm(Reenterer.Mode.Redeem, preimage, amount, alice, timelock + 1);

        reenterer.redeem(preimage, amount, alice, timelock);

        _assertReentryBlocked();
        assertEq(address(reenterer).balance, 11 ether, "the outer redeem paid out");
        assertEq(htlc.lockedTotal(), 1 ether, "the second swap is still owed");
        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, address(reenterer), timelock + 1));

        // And it can still be settled normally.
        reenterer.redeem(preimage, amount, alice, timelock + 1);
        assertEq(address(reenterer).balance, 12 ether, "second swap paid out too");
        assertEq(htlc.lockedTotal(), 0);
    }

    function test_redeemPayout_cannotReenterCreate() public {
        _lockTwoForReenterer();
        bytes32 otherPreimage = bytes32(uint256(0xcafe));
        reenterer.arm(Reenterer.Mode.Create, otherPreimage, 1, bob, timelock);

        reenterer.redeem(preimage, amount, alice, timelock);

        _assertReentryBlocked();
        assertFalse(
            htlc.isActive(sha256(abi.encodePacked(otherPreimage)), 1, address(0), address(reenterer), bob, timelock),
            "no swap was planted"
        );
        assertEq(htlc.lockedTotal(), 1 ether, "accounting only reflects the untouched swap");
    }

    function test_redeemPayout_cannotReenterRefund() public {
        _lockTwoForReenterer();
        // A swap the reenterer could refund: it is the refund address and the timelock passed.
        uint256 refundable = timelock + 2;
        reenterer.create{value: amount}(preimageHash, bob, refundable);
        vm.warp(refundable);
        reenterer.arm(Reenterer.Mode.Refund, preimage, amount, bob, refundable);

        reenterer.redeem(preimage, amount, alice, timelock);

        _assertReentryBlocked();
        assertTrue(
            htlc.isActive(preimageHash, amount, address(0), address(reenterer), bob, refundable),
            "refund did not go through"
        );
        assertEq(htlc.lockedTotal(), 2 ether);

        reenterer.refund(preimageHash, amount, bob, refundable);
        assertEq(htlc.lockedTotal(), 1 ether, "refundable swap settles normally afterwards");
    }

    /// `lockedTotal` is decremented before a settlement pays out, so for the rest of
    /// that call it understates what the contract still owes. Recovery is only correct
    /// against a settled obligation, so the guard keeps it out of that window entirely.
    function test_redeemPayout_cannotReenterRecoverExcess() public {
        htlc.transferOwnership(address(reenterer));
        reenterer.acceptOwnership();
        assertEq(htlc.owner(), address(reenterer), "reenterer owns the HTLC");

        _lockTwoForReenterer();
        reenterer.arm(Reenterer.Mode.Recover, preimage, amount, alice, timelock);

        reenterer.redeem(preimage, amount, alice, timelock);

        _assertReentryBlocked();
        assertEq(htlc.lockedTotal(), 1 ether, "one swap still outstanding");
        assertGe(address(htlc).balance, htlc.lockedTotal(), "the untouched swap is still fully backed");
    }

    // -- The other payout paths are guarded the same way --

    function test_redeemBySigPayout_cannotReenter() public {
        // Bob is the claimant; the reenterer is the authorized caller and gets paid.
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, address(reenterer), timelock + 1);

        (uint8 v, bytes32 r, bytes32 s) = _signRedeem(address(reenterer), bob);
        reenterer.arm(Reenterer.Mode.Redeem, preimage, amount, alice, timelock + 1);

        reenterer.redeemBySig(preimage, amount, alice, timelock, bob, v, r, s);

        _assertReentryBlocked();
        assertEq(address(reenterer).balance, 11 ether, "the outer redeem paid the caller");
        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, address(reenterer), timelock + 1));
    }

    function test_refundPayout_cannotReenter() public {
        reenterer.create{value: amount}(preimageHash, bob, timelock);
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, address(reenterer), timelock + 1);
        vm.warp(timelock);
        reenterer.arm(Reenterer.Mode.Redeem, preimage, amount, alice, timelock + 1);

        reenterer.refund(preimageHash, amount, bob, timelock);

        _assertReentryBlocked();
        assertEq(htlc.lockedTotal(), 1 ether, "only the refund settled");
        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, address(reenterer), timelock + 1));
    }

    function test_refundToDestinationPayout_cannotReenter() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, address(reenterer), timelock + 1);
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
        vm.warp(timelock);
        reenterer.arm(Reenterer.Mode.Redeem, preimage, amount, alice, timelock + 1);

        // Alice refunds her swap to the reenterer.
        vm.prank(alice);
        htlc.refund(preimageHash, amount, bob, timelock, address(reenterer));

        _assertReentryBlocked();
        assertEq(htlc.lockedTotal(), 1 ether, "only the refund settled");
    }

    function test_recoverExcessPayout_cannotReenter() public {
        htlc.transferOwnership(address(reenterer));
        reenterer.acceptOwnership();

        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, address(reenterer), timelock);
        vm.deal(address(htlc), address(htlc).balance + 3 ether);
        reenterer.arm(Reenterer.Mode.Redeem, preimage, amount, alice, timelock);

        reenterer.recoverExcess();

        _assertReentryBlocked();
        assertEq(address(htlc).balance, amount, "exactly the surplus left");
        assertEq(htlc.lockedTotal(), amount, "the swap is untouched");
    }

    // -- Gas forwarding --

    /// The hook writes storage, which a 2300-gas stipend could not afford: payouts
    /// forward all remaining gas, so smart-account claimants work.
    function test_payoutForwardsEnoughGasForAReceiveHook() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, address(reenterer), timelock);

        reenterer.redeem(preimage, amount, alice, timelock);

        assertTrue(reenterer.hookRan(), "hook wrote storage");
        assertEq(address(reenterer).balance, 11 ether, "paid");
    }

    // -- Non-receivable recipient --

    function test_redeemToRejectingClaimant_revertsAtomically() public {
        Rejecting rejecting = new Rejecting(htlc);
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, address(rejecting), timelock);

        vm.expectRevert(HTLCNative.EtherTransferFailed.selector);
        rejecting.redeem(preimage, amount, alice, timelock);

        (HTLCNative.SwapState state, bytes32 stored) =
            htlc.swapState(htlc.computeKey(preimageHash, amount, address(0), alice, address(rejecting), timelock));
        assertEq(uint8(state), uint8(HTLCNative.SwapState.Active), "swap stays Active");
        assertEq(stored, bytes32(0), "no preimage recorded");
        assertEq(htlc.lockedTotal(), amount, "still owed");
        assertEq(address(htlc).balance, amount, "still held");

        // The funds are not stranded: the sender can reclaim them after expiry.
        vm.warp(timelock);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, address(rejecting), timelock);
        assertEq(alice.balance, 10 ether, "refunded");
    }

    function test_refundToRejectingSender_revertsAtomically_destinationWorks() public {
        Rejecting rejecting = new Rejecting(htlc);
        // Alice pays, but the rejecting contract is the refund address.
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, address(rejecting), bob, timelock);
        vm.warp(timelock);

        vm.expectRevert(HTLCNative.EtherTransferFailed.selector);
        rejecting.refund(preimageHash, amount, bob, timelock);

        assertTrue(htlc.isActive(preimageHash, amount, address(0), address(rejecting), bob, timelock), "stays Active");
        assertEq(htlc.lockedTotal(), amount, "still owed");

        // The party picks a destination that can receive instead.
        rejecting.refundTo(preimageHash, amount, bob, timelock, alice);
        assertEq(alice.balance, 10 ether, "refunded to the chosen destination");
        assertEq(htlc.lockedTotal(), 0);
    }

    // -- Helpers --

    function _signRedeem(address caller, address destination) internal view returns (uint8 v, bytes32 r, bytes32 s) {
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
        (v, r, s) = vm.sign(bobPk, digest);
    }
}
