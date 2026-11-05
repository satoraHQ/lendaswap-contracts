// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";

contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped Bitcoin", "WBTC") {
        _mint(msg.sender, 100e8);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

/// A token that calls back into the HTLC mid-transfer. It is made the HTLC's owner so
/// the callback passes `onlyOwner`, isolating the reentrancy guard as the thing under test.
contract ReenteringToken is ERC20 {
    HTLCErc20 public htlc;
    bool public armed;
    bool public reentryReverted;
    bytes4 public reentryError;

    constructor() ERC20("Reenter", "RE") {
        _mint(msg.sender, 100e8);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function acceptHtlcOwnership(HTLCErc20 target) external {
        htlc = target;
        target.acceptOwnership();
    }

    function arm() external {
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && from == address(htlc)) {
            armed = false;
            try htlc.recoverExcessToken(address(this), address(this)) {
                reentryReverted = false;
            } catch (bytes memory data) {
                reentryReverted = true;
                reentryError = bytes4(data);
            }
        }
        super._update(from, to, value);
    }
}

/// @notice The owner may move only the balance no active swap is owed. `lockedAmounts`
///         tracks that obligation, so `recoverExcessToken` is floored at it and every
///         locked swap stays settleable.
contract HTLCErc20RecoveryTest is Test {
    event ExcessTokenRecovered(address indexed token, address indexed to, uint256 amount);
    event EtherRecovered(address indexed to, uint256 amount);

    HTLCErc20 htlc;
    MockWBTC wbtc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    bytes32 preimage = bytes32(uint256(0xbeef));
    bytes32 preimageHash;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20(address(this));
        wbtc = new MockWBTC();
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        wbtc.transfer(alice, 10e8);
    }

    function _lock(uint256 amount) internal {
        vm.startPrank(alice);
        wbtc.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(wbtc), bob, timelock);
        vm.stopPrank();
    }

    // -- Accounting --

    function test_lockedAmountTracksActiveSwaps() public {
        assertEq(htlc.lockedAmounts(address(wbtc)), 0, "starts at zero");

        _lock(1e8);
        assertEq(htlc.lockedAmounts(address(wbtc)), 1e8, "rises on create");

        vm.prank(bob);
        htlc.redeem(preimage, 1e8, address(wbtc), alice, timelock);
        assertEq(htlc.lockedAmounts(address(wbtc)), 0, "falls on settlement");
    }

    // -- Token recovery --

    function test_recoverExcessToken_movesOnlyTheSurplus() public {
        _lock(1e8);

        // Someone transfers straight to the contract, bypassing `create`.
        vm.prank(alice);
        wbtc.transfer(address(htlc), 3e8);

        assertEq(wbtc.balanceOf(address(htlc)), 4e8, "balance is swap + surplus");

        vm.expectEmit(true, true, false, true, address(htlc));
        emit ExcessTokenRecovered(address(wbtc), treasury, 3e8);
        htlc.recoverExcessToken(address(wbtc), treasury);

        assertEq(wbtc.balanceOf(treasury), 3e8, "surplus recovered");
        assertEq(wbtc.balanceOf(address(htlc)), 1e8, "swap funds remain");

        // The swap is still settleable afterwards.
        vm.prank(bob);
        htlc.redeem(preimage, 1e8, address(wbtc), alice, timelock);
        assertEq(wbtc.balanceOf(bob), 1e8, "swap paid out in full");
    }

    function test_recoverExcessToken_withNoSurplus_reverts() public {
        _lock(1e8);
        vm.expectRevert(HTLCErc20.NoExcess.selector);
        htlc.recoverExcessToken(address(wbtc), treasury);
    }

    function test_recoverExcessToken_fromNonOwner_reverts() public {
        vm.prank(alice);
        wbtc.transfer(address(htlc), 1e8);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        htlc.recoverExcessToken(address(wbtc), treasury);
    }

    function test_recoverExcessToken_toZeroAddress_reverts() public {
        vm.prank(alice);
        wbtc.transfer(address(htlc), 1e8);

        vm.expectRevert(HTLCErc20.ZeroRecipient.selector);
        htlc.recoverExcessToken(address(wbtc), address(0));
    }

    // -- Ether recovery --

    function test_recoverEther() public {
        vm.deal(address(htlc), 5 ether);

        vm.expectEmit(true, false, false, true, address(htlc));
        emit EtherRecovered(treasury, 5 ether);
        htlc.recoverEther(payable(treasury));

        assertEq(treasury.balance, 5 ether, "ether recovered");
        assertEq(address(htlc).balance, 0, "contract drained");
    }

    function test_recoverEther_withNoBalance_reverts() public {
        vm.expectRevert(HTLCErc20.NoExcess.selector);
        htlc.recoverEther(payable(treasury));
    }

    function test_recoverEther_fromNonOwner_reverts() public {
        vm.deal(address(htlc), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        htlc.recoverEther(payable(treasury));
    }

    // -- Ownership --

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(HTLCErc20.OwnershipRequired.selector);
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

    // -- Reentrancy --

    /// `lockedAmounts` is decremented before a settlement pays out, so for the rest of
    /// that call it understates what the contract still owes. Recovery is only correct
    /// against a settled obligation, so the guard keeps it out of that window entirely.
    /// Exercised with a second swap outstanding, whose backing must stay intact.
    function test_recoveryDuringSettlementReverts() public {
        ReenteringToken token = new ReenteringToken();

        htlc.transferOwnership(address(token));
        token.acceptHtlcOwnership(htlc);
        assertEq(htlc.owner(), address(token), "token owns the HTLC");

        token.transfer(alice, 5e8);

        uint256 otherTimelock = timelock + 1;
        vm.startPrank(alice);
        token.approve(address(htlc), 2e8);
        htlc.create(preimageHash, 1e8, address(token), bob, timelock);
        htlc.create(preimageHash, 1e8, address(token), bob, otherTimelock);
        vm.stopPrank();

        assertEq(htlc.lockedAmounts(address(token)), 2e8, "two swaps outstanding");

        token.arm();

        vm.prank(bob);
        htlc.redeem(preimage, 1e8, address(token), alice, timelock);

        assertTrue(token.reentryReverted(), "recovery inside a settlement must revert");
        assertEq(token.reentryError(), HTLCErc20.Reentrancy.selector, "with the declared Reentrancy() error");
        assertEq(token.balanceOf(bob), 1e8, "the settled swap paid out in full");
        assertEq(htlc.lockedAmounts(address(token)), 1e8, "one swap still outstanding");
        assertGe(
            token.balanceOf(address(htlc)),
            htlc.lockedAmounts(address(token)),
            "the untouched swap is still fully backed"
        );

        // And it can still be settled.
        vm.prank(bob);
        htlc.redeem(preimage, 1e8, address(token), alice, otherTimelock);
        assertEq(token.balanceOf(bob), 2e8, "second swap paid out too");
    }

    // -- Invariant --

    /// Whatever sequence of locks, settlements and stray transfers occurs, the balance
    /// covers the recorded obligation — recovery can never undercut a pending settlement.
    function testFuzz_balanceCoversLockedAmount(uint96 lockAmount, uint96 strayAmount, bool settle) public {
        uint256 locked = bound(uint256(lockAmount), 1, 5e8);
        uint256 stray = bound(uint256(strayAmount), 0, 4e8);

        _lock(locked);

        if (stray > 0) {
            vm.prank(alice);
            wbtc.transfer(address(htlc), stray);
        }

        if (settle) {
            vm.prank(bob);
            htlc.redeem(preimage, locked, address(wbtc), alice, timelock);
        }

        assertGe(wbtc.balanceOf(address(htlc)), htlc.lockedAmounts(address(wbtc)), "balance must cover the obligation");

        if (wbtc.balanceOf(address(htlc)) > htlc.lockedAmounts(address(wbtc))) {
            htlc.recoverExcessToken(address(wbtc), treasury);
        }

        assertGe(wbtc.balanceOf(address(htlc)), htlc.lockedAmounts(address(wbtc)), "still covered after recovery");

        // Anything still locked remains payable.
        if (!settle) {
            vm.prank(bob);
            htlc.redeem(preimage, locked, address(wbtc), alice, timelock);
            assertEq(wbtc.balanceOf(bob), locked, "swap paid out in full");
        }
    }
}
