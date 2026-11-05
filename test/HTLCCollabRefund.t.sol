// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {DeployPermit2} from "../lib/permit2/test/utils/DeployPermit2.sol";
import {HTLCErc20, SwapKey} from "../src/HTLCErc20.sol";
import {HTLCCoordinator} from "../src/HTLCCoordinator.sol";

contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped Bitcoin", "WBTC") {
        _mint(msg.sender, 100e8);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

contract MockDEX {
    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }
    mapping(bytes32 => Rate) public rates;

    function setRate(address tokenIn, address tokenOut, uint256 numerator, uint256 denominator) external {
        rates[keccak256(abi.encodePacked(tokenIn, tokenOut))] = Rate(numerator, denominator);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        Rate memory rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        amountOut = (amountIn * rate.numerator) / rate.denominator;
        require(amountOut >= minAmountOut, "MockDEX: slippage");
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

/// @notice Tests for collaborative refund (pre-timelock refund with claimAddress signature)
contract HTLCCollabRefundTest is Test {
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT2_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    HTLCErc20 htlc;
    HTLCCoordinator coordinator;
    ISignatureTransfer permit2;
    MockUSDC usdc;
    MockWBTC wbtc;
    MockDEX dex;

    // Alice = depositor (client), needs known private key for EIP-712 signing
    uint256 alicePk;
    address alice;

    // Bob = claimAddress (server), needs known private key for EIP-712 signing
    uint256 bobPk;
    address bob;

    // Relay = anyone submitting the tx (server in production)
    address relay = makeAddr("relay");

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 usdcAmount = 60_000e6;
    uint256 wbtcAmount = 1e8;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCErc20(address(this));
        permit2 = ISignatureTransfer(new DeployPermit2().deployPermit2());
        coordinator = new HTLCCoordinator(address(htlc), address(permit2));
        usdc = new MockUSDC();
        wbtc = new MockWBTC();
        dex = new MockDEX();

        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        // Fund alice and DEX
        usdc.transfer(alice, 100_000e6);
        wbtc.transfer(alice, 10e8);
        wbtc.transfer(address(dex), 50e8);
        usdc.transfer(address(dex), 500_000e6);

        dex.setRate(address(usdc), address(wbtc), 1e8, 60_000e6);
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8);

        // Alice approves Permit2 for USDC
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);
    }

    // ---------------------------------------------------------------
    // HTLCErc20.refundBySig — direct HTLC-level collaborative refund
    // ---------------------------------------------------------------

    function test_refundBySig_basic() public {
        _aliceLockDirect();

        // Bob (claimAddress) signs a Refund with alice as the sender
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);

        // Alice (the sender) calls — tokens come back to her
        uint256 aliceBefore = wbtc.balanceOf(alice);
        vm.prank(alice);
        address recovered = htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);

        assertEq(recovered, bob, "should recover bob as claimAddress");
        assertEq(wbtc.balanceOf(alice), aliceBefore + wbtcAmount, "alice should have the WBTC back");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertFalse(htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock));
    }

    function test_refundBySig_beforeTimelock() public {
        _aliceLockDirect();
        assertLt(block.timestamp, timelock, "should be before timelock");

        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);

        vm.prank(alice);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);

        assertEq(wbtc.balanceOf(address(htlc)), 0, "should succeed before timelock");
    }

    function test_refundBySig_wrongSigner_reverts() public {
        _aliceLockDirect();

        // Alice signs instead of Bob: the recovered claimAddress addresses no active key
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(alicePk, alice);

        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);
    }

    function test_refundBySig_wrongCaller_reverts() public {
        _aliceLockDirect();

        // Signed with alice as sender, but relay calls: the key is built from msg.sender
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);

        vm.prank(relay);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);

        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "nothing moved");
    }

    /// The hole that got the previous refundBySig pulled: the claimAddress alone signs
    /// and submits, routing the lock to itself before the timelock. The signature now
    /// names the sender, and the sender is msg.sender, so bob can only ever address a
    /// key under himself — one that was never funded.
    function test_refundBySig_claimAddressCannotRefundToItself_reverts() public {
        _aliceLockDirect();

        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, bob);

        vm.prank(bob);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);

        assertEq(wbtc.balanceOf(bob), 0, "bob must not receive anything");
        assertEq(wbtc.balanceOf(address(htlc)), wbtcAmount, "htlc must still hold the tokens");
    }

    /// Every term is in the digest and in the key: a caller that changes any one of
    /// them recovers a different signer and addresses a key that was never funded.
    function test_refundBySig_tamperedTerms_reverts() public {
        _aliceLockDirect();
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);

        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount - 1, address(wbtc), timelock, v, r, s);

        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock + 1, v, r, s);

        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(usdc), timelock, v, r, s);

        assertTrue(htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock), "untouched");
    }

    /// The claimAddress's signature waives the timelock; it does not stop working once
    /// the timelock has passed. Pinned so a future deadline cannot slip in silently.
    function test_refundBySig_afterTimelock_stillWorks() public {
        _aliceLockDirect();
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);

        vm.warp(timelock + 1 days);
        vm.prank(alice);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);
        assertEq(wbtc.balanceOf(address(htlc)), 0);
    }

    /// A Redeem signature is not a Refund signature: the type strings differ, so the
    /// digest differs, so the recovered signer addresses no active key.
    function test_refundBySig_redeemSignature_reverts() public {
        _aliceLockDirect();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        preimage,
                        wbtcAmount,
                        address(wbtc),
                        alice,
                        timelock,
                        alice,
                        alice,
                        address(wbtc),
                        uint256(0),
                        bytes32(0)
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);
    }

    function test_refundBySig_replay_reverts() public {
        _aliceLockDirect();
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);

        vm.prank(alice);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);

        SwapKey key = htlc.computeKey(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Refunded));
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);
    }

    function test_refundBySig_thenRedeem_reverts() public {
        _aliceLockDirect();
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);

        vm.prank(alice);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);

        SwapKey key = htlc.computeKey(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HTLCErc20.SwapNotActive.selector, key, HTLCErc20.SwapState.Refunded));
        htlc.redeem(preimage, wbtcAmount, address(wbtc), alice, timelock);
    }

    // ---------------------------------------------------------------
    // Coordinator-created swaps: the depositor is the HTLC sender, so every
    // refund path is a direct HTLC call by the depositor. The coordinator has
    // no refund function and holds no record of the swap.
    // ---------------------------------------------------------------

    function test_coordinatorSwap_depositorIsTheSender() public {
        _aliceSwapAndLock();
        assertTrue(htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock), "key under alice");
        assertFalse(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), address(coordinator), bob, timelock),
            "no key under the coordinator"
        );
    }

    function test_coordinatorSwap_refundBySig_byDepositor() public {
        _aliceSwapAndLock();
        assertLt(block.timestamp, timelock, "before timelock");
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);

        vm.prank(alice);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);

        assertEq(wbtc.balanceOf(alice), 10e8 + wbtcAmount, "alice holds the WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc empty");
        assertEq(wbtc.balanceOf(address(coordinator)), 0, "coordinator never touched");
    }

    function test_coordinatorSwap_refund_afterTimelock_byDepositor() public {
        _aliceSwapAndLock();
        vm.warp(timelock + 1);

        vm.prank(alice);
        htlc.refund(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        assertEq(wbtc.balanceOf(alice), 10e8 + wbtcAmount, "alice holds the WBTC");
    }

    function test_coordinatorSwap_refundToDestination_byDepositor() public {
        _aliceSwapAndLock();
        vm.warp(timelock + 1);

        vm.prank(alice);
        htlc.refund(preimageHash, wbtcAmount, address(wbtc), bob, timelock, relay);
        assertEq(wbtc.balanceOf(relay), wbtcAmount, "paid where alice pointed");
    }

    /// A signature over `sender = coordinator` addresses a key that was never
    /// created: the coordinator is not the sender of anything.
    function test_coordinatorSwap_signatureForCoordinatorAsSender_isUseless() public {
        _aliceSwapAndLock();
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, address(coordinator));

        vm.prank(address(coordinator));
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);

        vm.prank(alice);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);
        assertTrue(htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock), "untouched");
    }

    /// `refundFor` on a coordinator-created swap pays the depositor. Naming the
    /// coordinator as sender addresses a key that was never created, so no refund can
    /// land in the coordinator's sweepable balance.
    function test_coordinatorSwap_refundFor_paysTheDepositor() public {
        _aliceSwapAndLock();
        vm.warp(timelock + 1);

        vm.prank(relay);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundFor(preimageHash, wbtcAmount, address(wbtc), address(coordinator), bob, timelock);

        vm.prank(relay);
        htlc.refundFor(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock);

        assertEq(wbtc.balanceOf(alice), 10e8 + wbtcAmount, "alice holds the WBTC");
        assertEq(wbtc.balanceOf(address(coordinator)), 0, "nothing landed in the coordinator");
        assertEq(wbtc.balanceOf(relay), 0, "relay paid gas only");
    }

    function test_coordinatorSwap_strangerCannotRefund() public {
        _aliceSwapAndLock();
        vm.warp(timelock + 1);

        vm.prank(relay);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refund(preimageHash, wbtcAmount, address(wbtc), bob, timelock);

        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRefund(bobPk, alice);
        vm.prank(relay);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refundBySig(preimageHash, wbtcAmount, address(wbtc), timelock, v, r, s);
    }

    function test_coordinatorSwap_redeemAndExecute_withDepositorAsSender() public {
        _aliceSwapAndLock();

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);
        bytes32 callsHash = _computeCallsHash(calls);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        preimage,
                        wbtcAmount,
                        address(wbtc),
                        alice,
                        timelock,
                        address(coordinator),
                        bob,
                        address(wbtc),
                        wbtcAmount,
                        callsHash
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(relay);
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock, calls, address(wbtc), wbtcAmount, bob, v, r, s
        );
        assertEq(wbtc.balanceOf(bob), wbtcAmount, "bob paid through the coordinator");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _aliceLockDirect() internal {
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();
    }

    /// @dev Alice does executeAndCreateWithPermit2: USDC -> DEX swap -> WBTC, lock with bob as claimAddress
    function _aliceSwapAndLock() internal {
        _aliceSwapAndLockWith(bob, 0);
    }

    function _aliceSwapAndLockWith(address claimAddress, uint256 nonce) internal {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](2);
        calls[0] = HTLCCoordinator.Call({
            target: address(usdc), value: 0, callData: abi.encodeCall(IERC20.approve, (address(dex), usdcAmount))
        });
        calls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)", address(usdc), address(wbtc), usdcAmount, wbtcAmount
            )
        });

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, nonce, claimAddress, calls);

        vm.prank(alice);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), claimAddress, timelock, alice, permit, signature
        );
    }

    function _signPermit2(
        address token,
        uint256 amount,
        uint256 nonce,
        address claimAddress,
        HTLCCoordinator.Call[] memory calls
    ) internal view returns (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) {
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });

        bytes32 witness =
            _computeWitness(preimageHash, address(wbtc), claimAddress, alice, timelock, calls);
        signature = _signPermit2WitnessTransfer(permit, witness, alicePk);
    }

    function _computeWitness(
        bytes32 _preimageHash,
        address token,
        address claimAddress,
        address refundAddress,
        uint256 _timelock,
        HTLCCoordinator.Call[] memory calls
    ) internal view returns (bytes32 witness) {
        bytes32 callsHash;
        {
            bytes memory callsData = abi.encode(calls);
            assembly ("memory-safe") {
                callsHash := keccak256(add(callsData, 0x20), mload(callsData))
            }
        }

        bytes32 typeHash = coordinator.TYPEHASH_EXECUTE_AND_CREATE();
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), _preimageHash)
            mstore(add(ptr, 0x40), token)
            mstore(add(ptr, 0x60), claimAddress)
            mstore(add(ptr, 0x80), refundAddress)
            mstore(add(ptr, 0xa0), _timelock)
            mstore(add(ptr, 0xc0), callsHash)
            witness := keccak256(ptr, 0xe0)
            mstore(0x40, add(ptr, 0xe0))
        }
    }

    function _signPermit2WitnessTransfer(
        ISignatureTransfer.PermitTransferFrom memory permit,
        bytes32 witness,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT2_WITNESS_TYPEHASH_STUB, coordinator.TYPESTRING_EXECUTE_AND_CREATE())
        );
        bytes32 tokenPermissionsHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permit2.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        typehash, tokenPermissionsHash, address(coordinator), permit.nonce, permit.deadline, witness
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function _computeCallsHash(HTLCCoordinator.Call[] memory calls) internal pure returns (bytes32) {
        bytes memory callsData = abi.encode(calls);
        return keccak256(callsData);
    }

    /// @dev HTLC-level `Refund`: the claimAddress signs over the swap terms with the
    ///      sender that will call refundBySig.
    function _signHTLCRefund(uint256 pk, address sender) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(htlc.TYPEHASH_REFUND(), preimageHash, wbtcAmount, address(wbtc), sender, timelock)
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }
}
