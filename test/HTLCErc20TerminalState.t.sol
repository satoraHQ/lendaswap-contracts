// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HTLCErc20, SwapKey} from "../src/HTLCErc20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 100e18);
    }
}

/// @notice A settled swap's outcome stays readable from storage: the state enum
///         classifies redeem vs refund, a redeem stores its preimage, and a
///         settled key can never be created again.
contract HTLCErc20TerminalStateTest is Test {
    HTLCErc20 htlc;
    MockToken token;

    address alice = makeAddr("alice");
    address bob;
    uint256 bobPk;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1e18;
    uint256 timelock;
    SwapKey key;

    function setUp() public {
        (bob, bobPk) = makeAddrAndKey("bob");
        htlc = new HTLCErc20(address(this));
        token = new MockToken();
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;
        token.transfer(alice, 10e18);
        key = htlc.computeKey(preimageHash, amount, address(token), alice, bob, timelock);
    }

    function _create() internal {
        vm.startPrank(alice);
        token.approve(address(htlc), amount);
        htlc.create(preimageHash, amount, address(token), bob, timelock);
        vm.stopPrank();
    }

    function test_lifecycleStates() public {
        (HTLCErc20.SwapState state, bytes32 storedPreimage) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.None), "unknown key is None");
        assertEq(storedPreimage, bytes32(0));

        _create();
        (state,) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.Active), "created swap is Active");
        assertTrue(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock));
    }

    function test_redeemStoresTerminalStateAndPreimage() public {
        _create();
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(token), alice, timelock);

        (HTLCErc20.SwapState state, bytes32 storedPreimage) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.Redeemed), "redeem is terminal");
        assertEq(storedPreimage, preimage, "revealed preimage is readable from storage");
        assertFalse(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock));
    }

    function test_refundStoresTerminalState() public {
        _create();
        vm.warp(timelock);
        vm.prank(alice);
        htlc.refund(preimageHash, amount, address(token), bob, timelock);

        (HTLCErc20.SwapState state, bytes32 storedPreimage) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.Refunded), "refund is terminal");
        assertEq(storedPreimage, bytes32(0), "no preimage was revealed");
        assertFalse(htlc.isActive(preimageHash, amount, address(token), alice, bob, timelock));
    }

    function test_redeemedKey_cannotBeCreatedAgain() public {
        _create();
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(token), alice, timelock);

        // The preimage is now public; locking tokens under the same key again
        // would be claimable by anyone, so create must reject the settled key.
        vm.startPrank(alice);
        token.approve(address(htlc), amount);
        vm.expectRevert(
            abi.encodeWithSelector(HTLCErc20.SwapExists.selector, key, HTLCErc20.SwapState.Redeemed)
        );
        htlc.create(preimageHash, amount, address(token), bob, timelock);
        vm.stopPrank();
    }

    /// A timelock refund can only happen after expiry, at which point re-creating
    /// the key already fails the "timelock too soon" check. The settled-key check
    /// is only reachable through a collaborative refund (before expiry), so that
    /// is the path exercised here.
    function test_refundedKey_cannotBeCreatedAgain() public {
        _create();
        (uint8 v, bytes32 r, bytes32 s) = _signRefund(bobPk, alice);
        vm.prank(alice);
        htlc.refundBySig(preimageHash, amount, address(token), timelock, v, r, s);

        (HTLCErc20.SwapState state,) = htlc.swapState(key);
        assertEq(uint8(state), uint8(HTLCErc20.SwapState.Refunded), "collab refund is terminal");

        // The timelock is still in the future, so only the settled-key check
        // can reject this create.
        vm.startPrank(alice);
        token.approve(address(htlc), amount);
        vm.expectRevert(
            abi.encodeWithSelector(HTLCErc20.SwapExists.selector, key, HTLCErc20.SwapState.Refunded)
        );
        htlc.create(preimageHash, amount, address(token), bob, timelock);
        vm.stopPrank();
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

    function test_settledSwap_cannotBeSettledAgain() public {
        _create();
        vm.prank(bob);
        htlc.redeem(preimage, amount, address(token), alice, timelock);

        // A second redeem must not pass the Active check; the error names the
        // terminal state the swap is actually in.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Redeemed)
        );
        htlc.redeem(preimage, amount, address(token), alice, timelock);

        // Neither may a refund of the already-redeemed swap.
        vm.warp(timelock);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Redeemed)
        );
        htlc.refund(preimageHash, amount, address(token), bob, timelock);
    }
}
