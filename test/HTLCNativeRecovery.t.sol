// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HTLCNative} from "../src/HTLCNative.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StrayToken is ERC20 {
    constructor() ERC20("Stray", "STRAY") {
        _mint(msg.sender, 1_000e18);
    }
}

/// Pushes its whole balance into `target` without a call: the one way ether can reach
/// a contract that has no payable fallback.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// A recipient that cannot take the native coin.
contract Rejecting {
    receive() external payable {
        revert("no thanks");
    }
}

/// @notice The owner may move only the balance no active swap is owed. `lockedTotal`
///         tracks that obligation, so `recoverExcess` is floored at it and every
///         locked swap stays settleable — whatever gets force-sent in.
contract HTLCNativeRecoveryTest is Test {
    event ExcessRecovered(address indexed to, uint256 amount);

    HTLCNative htlc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    bytes32 preimage = bytes32(uint256(0xbeef));
    bytes32 preimageHash;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCNative(address(this));
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        vm.deal(alice, 10 ether);
    }

    function _lock(uint256 amount) internal {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);
    }

    function _forceSend(uint256 amount) internal {
        new ForceSender{value: amount}(payable(address(htlc)));
    }

    // -- Accounting --

    function test_lockedTotalTracksActiveSwaps() public {
        assertEq(htlc.lockedTotal(), 0, "starts at zero");

        _lock(1 ether);
        assertEq(htlc.lockedTotal(), 1 ether, "rises on create");

        vm.prank(alice);
        htlc.create{value: 2 ether}(preimageHash, bob, timelock + 1);
        assertEq(htlc.lockedTotal(), 3 ether, "sums every active swap");

        vm.prank(bob);
        htlc.redeem(preimage, 1 ether, alice, timelock);
        assertEq(htlc.lockedTotal(), 2 ether, "falls on redeem");

        vm.warp(timelock + 1);
        vm.prank(alice);
        htlc.refund(preimageHash, 2 ether, bob, timelock + 1);
        assertEq(htlc.lockedTotal(), 0, "falls on refund");
    }

    // -- Force-sent ether --

    function test_forceSendReachesTheContract() public {
        _forceSend(3 ether);
        assertEq(address(htlc).balance, 3 ether, "selfdestruct delivered");
        assertEq(htlc.lockedTotal(), 0, "owed to nobody");
    }

    function test_recoverExcess_movesOnlyTheSurplus() public {
        _lock(1 ether);
        _forceSend(3 ether);

        assertEq(address(htlc).balance, 4 ether, "balance is swap + surplus");

        vm.expectEmit(true, false, false, true, address(htlc));
        emit ExcessRecovered(treasury, 3 ether);
        htlc.recoverExcess(payable(treasury));

        assertEq(treasury.balance, 3 ether, "surplus recovered");
        assertEq(address(htlc).balance, 1 ether, "swap funds remain");
        assertEq(htlc.lockedTotal(), 1 ether, "obligation unchanged");

        // The swap is still settleable afterwards.
        vm.prank(bob);
        htlc.redeem(preimage, 1 ether, alice, timelock);
        assertEq(bob.balance, 1 ether, "swap paid out in full");
    }

    /// A force-send never changes what an active swap is owed: the claimant gets
    /// exactly `amount`, and the surplus is still there for the owner afterwards.
    function test_forceSendDoesNotChangeWhatSwapsAreOwed() public {
        _lock(1 ether);
        _forceSend(3 ether);

        vm.prank(bob);
        htlc.redeem(preimage, 1 ether, alice, timelock);

        assertEq(bob.balance, 1 ether, "exactly the locked amount");
        assertEq(address(htlc).balance, 3 ether, "surplus untouched by settlement");
        assertEq(htlc.lockedTotal(), 0);

        htlc.recoverExcess(payable(treasury));
        assertEq(treasury.balance, 3 ether, "surplus recovered in full");
        assertEq(address(htlc).balance, 0);
    }

    function test_recoverExcess_withNoSurplus_reverts() public {
        _lock(1 ether);
        vm.expectRevert(HTLCNative.NoExcess.selector);
        htlc.recoverExcess(payable(treasury));
    }

    function test_recoverExcess_onEmptyContract_reverts() public {
        vm.expectRevert(HTLCNative.NoExcess.selector);
        htlc.recoverExcess(payable(treasury));
    }

    function test_recoverExcess_fromNonOwner_reverts() public {
        _forceSend(1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        htlc.recoverExcess(payable(treasury));
    }

    function test_recoverExcess_toZeroAddress_reverts() public {
        _forceSend(1 ether);

        vm.expectRevert(HTLCNative.ZeroRecipient.selector);
        htlc.recoverExcess(payable(address(0)));
    }

    function test_recoverExcess_toRejectingRecipient_reverts() public {
        _forceSend(1 ether);
        Rejecting rejecting = new Rejecting();

        vm.expectRevert(HTLCNative.EtherTransferFailed.selector);
        htlc.recoverExcess(payable(address(rejecting)));

        assertEq(address(htlc).balance, 1 ether, "nothing moved");
    }

    // -- Ownership --

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(HTLCNative.OwnershipRequired.selector);
        htlc.renounceOwnership();
    }

    function test_ownershipTransferIsTwoStep() public {
        htlc.transferOwnership(treasury);
        assertEq(htlc.owner(), address(this), "not transferred until accepted");
        assertEq(htlc.pendingOwner(), treasury, "pending");

        vm.prank(treasury);
        htlc.acceptOwnership();
        assertEq(htlc.owner(), treasury, "transferred");
    }

    // -- Invariant --

    /// Whatever sequence of locks, settlements and force-sends occurs, the balance
    /// covers the recorded obligation — recovery can never undercut a pending settlement.
    // -- recoverToken --

    function test_recoverToken_movesTheWholeBalance() public {
        StrayToken token = new StrayToken();
        token.transfer(address(htlc), 250e18);
        _lock(1 ether);

        vm.expectEmit(true, true, false, true, address(htlc));
        emit HTLCNative.TokenRecovered(address(token), treasury, 250e18);
        htlc.recoverToken(address(token), treasury);

        assertEq(token.balanceOf(address(htlc)), 0, "token balance swept");
        assertEq(token.balanceOf(treasury), 250e18, "recipient received the tokens");
        assertEq(address(htlc).balance, 1 ether, "native balance untouched");
        assertEq(htlc.lockedTotal(), 1 ether, "lockedTotal untouched");
    }

    function test_recoverToken_withNoBalance_reverts() public {
        StrayToken token = new StrayToken();
        vm.expectRevert(HTLCNative.NoExcess.selector);
        htlc.recoverToken(address(token), treasury);
    }

    function test_recoverToken_fromNonOwner_reverts() public {
        StrayToken token = new StrayToken();
        token.transfer(address(htlc), 1e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        htlc.recoverToken(address(token), stranger);
    }

    function test_recoverToken_toZeroAddress_reverts() public {
        StrayToken token = new StrayToken();
        token.transfer(address(htlc), 1e18);
        vm.expectRevert(HTLCNative.ZeroRecipient.selector);
        htlc.recoverToken(address(token), address(0));
    }

    function testFuzz_balanceCoversLockedTotal(uint96 lockAmount, uint96 strayAmount, bool settle) public {
        uint256 locked = bound(uint256(lockAmount), 1, 5 ether);
        uint256 stray = bound(uint256(strayAmount), 0, 4 ether);

        _lock(locked);

        if (stray > 0) {
            _forceSend(stray);
        }

        if (settle) {
            vm.prank(bob);
            htlc.redeem(preimage, locked, alice, timelock);
        }

        assertGe(address(htlc).balance, htlc.lockedTotal(), "balance must cover the obligation");

        if (address(htlc).balance > htlc.lockedTotal()) {
            htlc.recoverExcess(payable(treasury));
            assertEq(treasury.balance, stray, "recovered exactly the force-sent amount");
        }

        assertEq(address(htlc).balance, htlc.lockedTotal(), "exactly covered after recovery");

        // Anything still locked remains payable.
        if (!settle) {
            vm.prank(bob);
            htlc.redeem(preimage, locked, alice, timelock);
            assertEq(bob.balance, locked, "swap paid out in full");
        }
    }
}
