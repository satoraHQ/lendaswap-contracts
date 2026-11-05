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

/// @notice Mock DEX with configurable rates per token pair
contract MockDEX {
    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    mapping(bytes32 => Rate) public rates;

    function setRate(address tokenIn, address tokenOut, uint256 numerator, uint256 denominator) external {
        rates[keccak256(abi.encodePacked(tokenIn, tokenOut))] = Rate(numerator, denominator);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        Rate memory rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        amountOut = (amountIn * rate.numerator) / rate.denominator;
        require(amountOut >= minAmountOut, "MockDEX: slippage");

        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

/// @notice Tests for Permit2-based gasless HTLC creation
contract HTLCCoordinatorPermit2Test is Test {
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string internal constant PERMIT2_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    HTLCErc20 htlc;
    HTLCCoordinator coordinator;
    ISignatureTransfer permit2;
    MockUSDC usdc;
    MockWBTC wbtc;
    MockDEX dex;

    uint256 alicePk;
    address alice;
    address bob = makeAddr("bob");

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
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        // Fund alice
        usdc.transfer(alice, 100_000e6);
        wbtc.transfer(alice, 10e8);

        // Fund DEX with liquidity
        wbtc.transfer(address(dex), 50e8);
        usdc.transfer(address(dex), 500_000e6);

        // Configure rates: 60,000 USDC = 1 WBTC
        dex.setRate(address(usdc), address(wbtc), 1e8, 60_000e6);
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8);

        // Alice approves Permit2 for max
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);
    }

    // ---------------------------------------------------------------
    // Happy path: depositor-tracking variant (swap + lock, Bob redeems)
    // ---------------------------------------------------------------

    function test_permit2_depositorTracking_swapAndLock() public {
        // Build calls: approve DEX, swap USDC -> WBTC
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](2);
        calls[0] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), usdcAmount))
        });
        calls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(usdc), address(wbtc), usdcAmount, wbtcAmount
            )
        });

        // Permit2 transfer: pull USDC from Alice
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(usdc), amount: usdcAmount}),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        // Witness uses the HTLC lock token (wbtc), not the Permit2 transfer token (usdc)
        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, alice, timelock, calls);
        bytes memory signature = _signPermit2WitnessTransfer(permit, witness, alicePk);

        // Relayer submits on behalf of Alice
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );

        // Verify: HTLC created with the depositor as sender
        assertTrue(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock),
            "swap should be active"
        );

        assertFalse(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), address(coordinator), bob, timelock),
            "no key under the coordinator"
        );

        // Bob can redeem
        vm.prank(bob);
        htlc.redeem(preimage, wbtcAmount, address(wbtc), alice, timelock);
        assertEq(wbtc.balanceOf(bob), wbtcAmount, "bob should have 1 WBTC");
    }

    // ---------------------------------------------------------------
    // Zero calls: direct lock without swap
    // ---------------------------------------------------------------

    function test_permit2_zeroCalls_directLock() public {
        // No swap calls — just pull tokens and lock them directly
        // Alice approves Permit2 for WBTC too
        vm.prank(alice);
        wbtc.approve(address(permit2), type(uint256).max);

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(wbtc), amount: wbtcAmount}),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        // refundAddress in the witness is the depositor
        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, alice, timelock, calls);
        bytes memory signature = _signPermit2WitnessTransfer(permit, witness, alicePk);

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );

        assertTrue(
            htlc.isActive(preimageHash, wbtcAmount, address(wbtc), alice, bob, timelock),
            "swap should be active"
        );
    }

    // ---------------------------------------------------------------
    // The depositor refunds straight on the HTLC
    // ---------------------------------------------------------------

    function test_permit2_depositorRefundsOnTheHtlc() public {
        vm.prank(alice);
        wbtc.approve(address(permit2), type(uint256).max);

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(wbtc), amount: wbtcAmount}),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, alice, timelock, calls);
        bytes memory signature = _signPermit2WitnessTransfer(permit, witness, alicePk);

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );

        uint256 aliceWbtcBefore = wbtc.balanceOf(alice);

        // Timelock expires; only the depositor can refund, and does so on the HTLC
        vm.warp(timelock + 1);
        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.refund(preimageHash, wbtcAmount, address(wbtc), bob, timelock);

        vm.prank(alice);
        htlc.refund(preimageHash, wbtcAmount, address(wbtc), bob, timelock);

        assertEq(wbtc.balanceOf(alice), aliceWbtcBefore + wbtcAmount, "alice has the WBTC back");
    }

    // ---------------------------------------------------------------
    // Invalid signature reverts
    // ---------------------------------------------------------------

    function test_permit2_invalidSignature_reverts() public {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        vm.prank(alice);
        wbtc.approve(address(permit2), type(uint256).max);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(wbtc), amount: wbtcAmount}),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        // Sign with wrong private key
        (, uint256 wrongPk) = makeAddrAndKey("wrong");
        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, alice, timelock, calls);
        bytes memory signature = _signPermit2WitnessTransfer(permit, witness, wrongPk);

        vm.expectRevert();
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    // ---------------------------------------------------------------
    // Tampered calls (wrong callsHash) reverts
    // ---------------------------------------------------------------

    function test_permit2_tamperedCalls_reverts() public {
        vm.prank(alice);
        wbtc.approve(address(permit2), type(uint256).max);

        // Sign with empty calls
        HTLCCoordinator.Call[] memory signedCalls = new HTLCCoordinator.Call[](0);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(wbtc), amount: wbtcAmount}),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, alice, timelock, signedCalls);
        bytes memory signature = _signPermit2WitnessTransfer(permit, witness, alicePk);

        // Submit with different calls (attacker tries to steal tokens)
        HTLCCoordinator.Call[] memory tamperedCalls = new HTLCCoordinator.Call[](1);
        tamperedCalls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.transfer, (makeAddr("attacker"), wbtcAmount))
        });

        vm.expectRevert();
        coordinator.executeAndCreateWithPermit2(
            tamperedCalls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    // ---------------------------------------------------------------
    // Tampered claimAddress reverts
    // ---------------------------------------------------------------

    function test_permit2_tamperedClaimAddress_reverts() public {
        vm.prank(alice);
        wbtc.approve(address(permit2), type(uint256).max);

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(wbtc), amount: wbtcAmount}),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        // Sign with bob as claimAddress
        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, alice, timelock, calls);
        bytes memory signature = _signPermit2WitnessTransfer(permit, witness, alicePk);

        // Submit with attacker as claimAddress
        address attacker = makeAddr("attacker");
        vm.expectRevert();
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), attacker, timelock, alice, permit, signature
        );
    }

    // ---------------------------------------------------------------
    // Calls targeting PERMIT2 are blocked
    // ---------------------------------------------------------------

    function test_permit2_callTargetingPermit2_blocked() public {
        vm.prank(alice);
        wbtc.approve(address(permit2), type(uint256).max);

        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(permit2),
            value: 0,
            callData: abi.encodeWithSignature("VERSION()")
        });

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(wbtc), amount: wbtcAmount}),
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, alice, timelock, calls);
        bytes memory signature = _signPermit2WitnessTransfer(permit, witness, alicePk);

        vm.expectPartialRevert(HTLCCoordinator.RestrictedTarget.selector);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

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
}
