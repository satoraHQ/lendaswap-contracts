// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {DeployPermit2} from "../lib/permit2/test/utils/DeployPermit2.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";
import {HTLCCoordinator} from "../src/HTLCCoordinator.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
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

/// @notice Edge-case and error-path tests for HTLCCoordinator
contract HTLCCoordinatorEdgeCasesTest is Test {
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

    // Bob needs a known private key for EIP-712 signing
    uint256 bobPk;
    address bob;

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

        // Fund alice
        usdc.transfer(alice, 100_000e6);
        wbtc.transfer(alice, 10e8);

        // Fund DEX with liquidity
        wbtc.transfer(address(dex), 50e8);
        usdc.transfer(address(dex), 500_000e6);

        // Configure rates: 60,000 USDC = 1 WBTC
        dex.setRate(address(usdc), address(wbtc), 1e8, 60_000e6);
        dex.setRate(address(wbtc), address(usdc), 60_000e6, 1e8);

        // Alice approves Permit2 for USDC and WBTC
        vm.startPrank(alice);
        usdc.approve(address(permit2), type(uint256).max);
        wbtc.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // RestrictedTarget
    // ---------------------------------------------------------------

    function test_restrictedTarget_htlc_reverts() public {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(htlc),
            value: 0,
            callData: abi.encodeWithSignature("VERSION()")
        });

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, address(coordinator), calls);

        vm.expectPartialRevert(HTLCCoordinator.RestrictedTarget.selector);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    function test_restrictedTarget_coordinator_reverts() public {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(coordinator),
            value: 0,
            callData: abi.encodeWithSignature("VERSION()")
        });

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, address(coordinator), calls);

        vm.expectPartialRevert(HTLCCoordinator.RestrictedTarget.selector);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    // ---------------------------------------------------------------
    // InsufficientBalance
    // ---------------------------------------------------------------

    function test_executeAndCreate_zeroBalance_reverts() public {
        // Calls that don't produce any WBTC for the coordinator
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](0);

        // Pull USDC but lock token is WBTC — no swap means zero WBTC balance
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, address(coordinator), calls);

        vm.expectRevert(HTLCCoordinator.InsufficientBalance.selector);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    function test_redeemAndExecute_minAmountOut_reverts() public {
        // Alice locks WBTC with Bob as claimAddress
        vm.startPrank(alice);
        wbtc.approve(address(htlc), wbtcAmount);
        htlc.create(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
        vm.stopPrank();

        uint256 tooHighMinOut = usdcAmount + 1;

        // Bob redeems and swaps, but sets minAmountOut higher than DEX output
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](2);
        calls[0] = HTLCCoordinator.Call({
            target: address(wbtc),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(dex), wbtcAmount))
        });
        calls[1] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)",
                address(wbtc), address(usdc), wbtcAmount, usdcAmount
            )
        });

        bytes32 callsHash = _computeCallsHash(calls);

        // Bob signs EIP-712 redeem authorizing the coordinator, with bob as destination
        (uint8 v, bytes32 r, bytes32 s) = _signHTLCRedeem(
            bobPk, preimage, wbtcAmount, address(wbtc), alice, timelock,
            address(coordinator), bob, address(usdc), tooHighMinOut, callsHash
        );

        vm.prank(bob);
        vm.expectRevert(HTLCCoordinator.InsufficientBalance.selector);
        coordinator.redeemAndExecute(
            preimage, wbtcAmount, address(wbtc), alice, timelock,
            calls, address(usdc), tooHighMinOut,
            bob,
            v, r, s
        );
    }

    // ---------------------------------------------------------------
    // UnknownHTLC
    // ---------------------------------------------------------------

    function test_refundTo_unknownHTLC_reverts() public {
        vm.warp(timelock + 1);

        vm.expectRevert(HTLCCoordinator.UnknownHtlc.selector);
        coordinator.refundTo(preimageHash, wbtcAmount, address(wbtc), bob, timelock);
    }

    // ---------------------------------------------------------------
    // CallFailed
    // ---------------------------------------------------------------

    function test_executeAndCreate_callFailed_reverts() public {
        // Call a contract with bogus calldata that will revert
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(dex),
            value: 0,
            callData: abi.encodeWithSignature("nonExistentFunction()")
        });

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, address(coordinator), calls);

        vm.expectPartialRevert(HTLCCoordinator.CallFailed.selector);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    // ---------------------------------------------------------------
    // transferFrom selector blocklist (defense-in-depth)
    // ---------------------------------------------------------------

    function test_transferFrom_in_calls_reverts() public {
        HTLCCoordinator.Call[] memory calls = new HTLCCoordinator.Call[](1);
        calls[0] = HTLCCoordinator.Call({
            target: address(usdc),
            value: 0,
            callData: abi.encodeCall(IERC20.transferFrom, (alice, address(coordinator), usdcAmount))
        });

        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory signature) =
            _signPermit2(address(usdc), usdcAmount, 0, address(coordinator), calls);

        vm.expectPartialRevert(HTLCCoordinator.DangerousSelector.selector);
        coordinator.executeAndCreateWithPermit2(
            calls, preimageHash, address(wbtc), bob, timelock, alice, permit, signature
        );
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _signHTLCRedeem(
        uint256 pk,
        bytes32 _preimage,
        uint256 amount,
        address token,
        address sender,
        uint256 _timelock,
        address caller,
        address destination,
        address sweepToken,
        uint256 minAmountOut,
        bytes32 callsHash
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                htlc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        htlc.TYPEHASH_REDEEM(),
                        _preimage, amount, token, sender, _timelock, caller,
                        destination, sweepToken, minAmountOut, callsHash
                    )
                )
            )
        );
        (v, r, s) = vm.sign(pk, digest);
    }

    function _computeCallsHash(HTLCCoordinator.Call[] memory calls) internal pure returns (bytes32 callsHash) {
        bytes memory callsData = abi.encode(calls);
        assembly ("memory-safe") {
            callsHash := keccak256(add(callsData, 0x20), mload(callsData))
        }
    }

    /// @dev Build the standard 2-call sequence: approve DEX, swap
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
