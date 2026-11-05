// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HTLCErc20, SwapKey} from "../src/HTLCErc20.sol";
import {HTLCNative, SwapKey as NativeSwapKey} from "../src/HTLCNative.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 100e18);
    }
}

/// @notice A sender that refuses the native coin.
contract NonReceiver {
    function lock(HTLCNative h, bytes32 hash, address claim, uint256 tl) external payable {
        h.create{value: msg.value}(hash, claim, tl);
    }
}

/// @notice `refundFor` is a permissionless post-timelock refund that pays the recorded
///         sender. Anyone may pay the gas; nobody can change where the funds go.
contract HTLCRefundForTest is Test {
    HTLCErc20 htlc;
    HTLCNative native;
    MockToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1e18;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20(address(this));
        native = new HTLCNative(address(this));
        token = new MockToken();
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;
        token.transfer(alice, 10e18);
        vm.deal(alice, 10 ether);

        vm.startPrank(alice);
        token.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(token), bob, timelock);
        native.create{value: amount}(preimageHash, bob, timelock);
        vm.stopPrank();
    }

    // -- ERC20 --

    function test_erc20_strangerRefundsForTheSender() public {
        vm.warp(timelock);
        SwapKey key = htlc.computeKey(preimageHash, amount, address(token), alice, bob, timelock);

        vm.expectEmit(true, true, false, true, address(htlc));
        emit HTLCErc20.SwapRefunded(preimageHash, key);

        vm.prank(stranger);
        htlc.refundFor(preimageHash, amount, address(token), alice, bob, timelock);

        assertEq(token.balanceOf(alice), 10e18, "alice made whole");
        assertEq(token.balanceOf(stranger), 0, "stranger gets nothing");
        assertEq(htlc.lockedAmounts(address(token)), 0, "accounting settled");
        (HTLCErc20.SwapState state,) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.Refunded));
    }

    function test_erc20_senderCanAlsoUseIt() public {
        vm.warp(timelock);
        vm.prank(alice);
        htlc.refundFor(preimageHash, amount, address(token), alice, bob, timelock);
        assertEq(token.balanceOf(alice), 10e18);
    }

    function test_erc20_beforeTimelock_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(HTLCErc20.TimelockNotExpired.selector);
        htlc.refundFor(preimageHash, amount, address(token), alice, bob, timelock);
    }

    /// Naming someone else as sender addresses a key nobody funded; the caller
    /// cannot route alice's tokens anywhere but to alice.
    function test_erc20_wrongSender_reverts() public {
        vm.warp(timelock);
        vm.prank(stranger);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundFor(preimageHash, amount, address(token), stranger, bob, timelock);
        assertTrue(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock), "untouched");
    }

    function test_erc20_afterRedeem_reverts() public {
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(token), alice, timelock);
        vm.warp(timelock);
        SwapKey key = htlc.computeKey(preimageHash, amount, address(token), alice, bob, timelock);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Redeemed));
        htlc.refundFor(preimageHash, amount, address(token), alice, bob, timelock);
    }

    function test_erc20_twice_reverts() public {
        vm.warp(timelock);
        htlc.refundFor(preimageHash, amount, address(token), alice, bob, timelock);
        SwapKey key = htlc.computeKey(preimageHash, amount, address(token), alice, bob, timelock);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Refunded));
        htlc.refundFor(preimageHash, amount, address(token), alice, bob, timelock);
    }

    function test_erc20_plainRefundStillKeysOnCaller() public {
        vm.warp(timelock);
        vm.prank(stranger);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refund(preimageHash, amount, address(token), bob, timelock);
    }

    // -- Native --

    function test_native_strangerRefundsForTheSender() public {
        vm.warp(timelock);
        NativeSwapKey key = native.computeKey(preimageHash, amount, address(0), alice, bob, timelock);

        vm.expectEmit(true, true, false, true, address(native));
        emit HTLCNative.SwapRefunded(preimageHash, key);

        vm.prank(stranger);
        native.refundFor(preimageHash, amount, alice, bob, timelock);

        assertEq(alice.balance, 10 ether, "alice made whole");
        assertEq(stranger.balance, 0, "stranger gets nothing");
        assertEq(native.lockedTotal(), 0, "accounting settled");
    }

    function test_native_beforeTimelock_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(HTLCNative.TimelockNotExpired.selector);
        native.refundFor(preimageHash, amount, alice, bob, timelock);
    }

    function test_native_wrongSender_reverts() public {
        vm.warp(timelock);
        vm.prank(stranger);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        native.refundFor(preimageHash, amount, stranger, bob, timelock);
        assertTrue(native.isActive(preimageHash, amount, address(0), alice, bob, timelock), "untouched");
    }

    function test_native_twice_reverts() public {
        vm.warp(timelock);
        native.refundFor(preimageHash, amount, alice, bob, timelock);
        NativeSwapKey key = native.computeKey(preimageHash, amount, address(0), alice, bob, timelock);
        vm.expectRevert(abi.encodeWithSelector(HTLCNative.SwapNotActive.selector, key, HTLCNative.SwapState.Refunded));
        native.refundFor(preimageHash, amount, alice, bob, timelock);
    }

    /// A sender that cannot receive the coin is not reachable through refundFor; the
    /// lock stays intact for the sender's own destination refund.
    function test_native_nonReceivingSender_revertsAtomically() public {
        NonReceiver nr = new NonReceiver();
        vm.deal(address(nr), 2 ether);
        bytes32 h2 = sha256(abi.encodePacked(bytes32(uint256(0xcafe))));
        nr.lock{value: amount}(native, h2, bob, timelock);

        vm.warp(timelock);
        vm.prank(stranger);
        vm.expectRevert(HTLCNative.EtherTransferFailed.selector);
        native.refundFor(h2, amount, address(nr), bob, timelock);
        assertTrue(native.isActive(h2, amount, address(0), address(nr), bob, timelock), "lock intact");
    }
}
