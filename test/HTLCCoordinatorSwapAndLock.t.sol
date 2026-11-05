// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {DeployPermit2} from "../lib/permit2/test/utils/DeployPermit2.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";
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

/// @notice E2E: Alice swaps USDC -> WBTC via DEX and locks WBTC in an HTLC, Bob claims the WBTC
contract HTLCCoordinatorCreateAndClaimTest is Test {
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
    uint256 usdcAmount = 60_000e6; // 60,000 USDC
    uint256 expectedWbtc = 1e8; // 1 WBTC
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

        // Fund alice with USDC
        usdc.transfer(alice, 100_000e6);

        // Fund the DEX with liquidity
        wbtc.transfer(address(dex), 50e8);
        usdc.transfer(address(dex), 500_000e6);

        // Configure rates: 60,000 USDC = 1 WBTC
        dex.setRate(address(usdc), address(wbtc), 1e8, 60_000e6); // USDC -> WBTC
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8); // WBTC -> USDC

        // Alice approves Permit2 for USDC
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);
    }

    function test_executeAndCreate_thenBobClaims() public {
        // 1. Build calls: approve DEX, swap USDC -> WBTC
        HTLCCoordinator.Call[] memory calls = _buildSwapCalls(
            address(usdc), address(wbtc), usdcAmount, expectedWbtc
        );

        // 2. Alice signs Permit2 to pull USDC
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, alice, calls);

        // 3. Create the swap via the coordinator (Bob is claimAddress)
        vm.prank(alice);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );

        // Verify: USDC left Alice, WBTC is locked in the HTLC
        assertEq(usdc.balanceOf(alice), 40_000e6, "alice should have 40k USDC left");
        assertEq(wbtc.balanceOf(address(htlc)), expectedWbtc, "htlc should hold 1 WBTC");
        assertTrue(
            htlc.isActive(preimageHash, expectedWbtc, address(wbtc), alice, bob, timelock),
            "swap should be active"
        );

        // 4. Bob claims directly on the HTLC (msg.sender = claimAddress)
        vm.prank(bob);
        htlc.redeem(preimage, expectedWbtc, address(wbtc), alice, timelock);

        // Verify: Bob received WBTC, HTLC is empty
        assertEq(wbtc.balanceOf(bob), expectedWbtc, "bob should have 1 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
    }

    function test_claimWithInvalidPreimage_reverts() public {
        // 1. Alice creates the swap
        HTLCCoordinator.Call[] memory calls = _buildSwapCalls(
            address(usdc), address(wbtc), usdcAmount, expectedWbtc
        );

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, alice, calls);

        vm.prank(alice);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );

        // 2. Bob tries to claim with the wrong preimage
        bytes32 wrongPreimage = bytes32(uint256(0xbaadf00d));
        vm.prank(bob);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        htlc.redeem(wrongPreimage, expectedWbtc, address(wbtc), alice, timelock);

        // Verify: WBTC still locked
        assertEq(wbtc.balanceOf(bob), 0, "bob should still have 0 WBTC");
        assertEq(wbtc.balanceOf(address(htlc)), expectedWbtc, "htlc should still hold 1 WBTC");
    }

    function test_executeAndCreate_thenDepositorRefundsOnTheHtlc() public {
        // 1. Alice creates the swap via Permit2; she is the HTLC sender
        HTLCCoordinator.Call[] memory calls = _buildSwapCalls(
            address(usdc), address(wbtc), usdcAmount, expectedWbtc
        );

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, alice, calls);

        vm.prank(alice);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );

        assertEq(wbtc.balanceOf(address(htlc)), expectedWbtc, "htlc should hold 1 WBTC");
        assertEq(wbtc.balanceOf(alice), 0, "alice should have 0 WBTC");

        // 2. Bob never claims — timelock expires
        vm.warp(timelock + 1);

        // 3. Alice refunds straight on the HTLC; the coordinator is not involved
        vm.prank(alice);
        htlc.refund(preimageHash, expectedWbtc, address(wbtc), bob, timelock);

        // Verify: Alice received the WBTC directly
        assertEq(wbtc.balanceOf(address(htlc)), 0, "htlc should be empty");
        assertEq(wbtc.balanceOf(alice), expectedWbtc, "alice should have 1 WBTC");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _buildSwapCalls(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal view returns (HTLCCoordinator.Call[] memory calls) {
        calls = new HTLCCoordinator.Call[](2);
        calls[0] = HTLCCoordinator.Call({
            target: tokenIn,
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), amountIn))
        });
        calls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                tokenIn, tokenOut, amountIn, minAmountOut
            )
        });
    }

    function _signPermit2(
        address token,
        uint256 amount,
        uint256 nonce,
        address refundAddress,
        HTLCCoordinator.Call[] memory calls
    ) internal view returns (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) {
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });

        bytes32 witness = _computeWitness(preimageHash, address(wbtc), bob, refundAddress, timelock, calls);
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
}
