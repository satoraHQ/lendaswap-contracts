// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCErc20, SwapKey as Erc20SwapKey} from "../src/HTLCErc20.sol";
import {HTLCNative, SwapKey} from "../src/HTLCNative.sol";

/// @notice `_key` is hand-rolled assembly that zeroes the token word. The layout it
///         hashes is exactly `abi.encode` of the six ERC20 parameters with
///         `token = address(0)`, so every off-chain consumer — and `HTLCErc20`
///         itself — derives the same key from the same terms.
contract HTLCNativeKeyTest is Test {
    HTLCNative htlc;
    HTLCErc20 erc20;

    function setUp() public {
        htlc = new HTLCNative(address(this));
        erc20 = new HTLCErc20(address(this));
    }

    function testFuzz_keyIsAbiEncodedParametersWithZeroToken(
        bytes32 preimageHash,
        uint256 amount,
        address sender,
        address claimAddress,
        uint256 timelock
    ) public view {
        assertEq(
            SwapKey.unwrap(htlc.computeKey(preimageHash, amount, address(0), sender, claimAddress, timelock)),
            keccak256(abi.encode(preimageHash, amount, address(0), sender, claimAddress, timelock)),
            "key must equal abi.encode of its parameters with a zero token"
        );
    }

    function testFuzz_keyMatchesErc20KeyWithZeroToken(
        bytes32 preimageHash,
        uint256 amount,
        address sender,
        address claimAddress,
        uint256 timelock
    ) public view {
        assertEq(
            SwapKey.unwrap(htlc.computeKey(preimageHash, amount, address(0), sender, claimAddress, timelock)),
            Erc20SwapKey.unwrap(erc20.computeKey(preimageHash, amount, address(0), sender, claimAddress, timelock)),
            "native key must equal the ERC20 key for token = address(0)"
        );
    }

    /// The 6-arg views keep the ERC20 shape, but a non-zero token can never name a swap here.
    function testFuzz_computeKey_nonZeroToken_reverts(address token) public {
        vm.assume(token != address(0));
        vm.expectRevert(HTLCNative.TokenMustBeZero.selector);
        htlc.computeKey(bytes32(0), 1, token, address(1), address(2), 3);
    }

    function testFuzz_isActive_nonZeroToken_reverts(address token) public {
        vm.assume(token != address(0));
        vm.expectRevert(HTLCNative.TokenMustBeZero.selector);
        htlc.isActive(bytes32(0), 1, token, address(1), address(2), 3);
    }

    /// The shared vector that off-chain key derivation is pinned to: the ERC20 vector
    /// from `HTLCErc20KeyTest.test_offChainVector` with the token slot zeroed.
    function test_offChainVector() public view {
        bytes32 preimageHash = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
        address sender = 0x3333333333333333333333333333333333333333;
        address claimAddress = 0x4444444444444444444444444444444444444444;

        bytes32 key =
            SwapKey.unwrap(htlc.computeKey(preimageHash, 100_000_000, address(0), sender, claimAddress, 1_800_000_000));

        assertEq(
            key,
            keccak256(
                abi.encode(preimageHash, uint256(100_000_000), address(0), sender, claimAddress, uint256(1_800_000_000))
            ),
            "vector derivation"
        );
        assertEq(key, 0x1b35678160a334ddfbbcc658cdf0f5cda2c17c16c5e659cfe6191fef36486e23, "vector");
    }
}
