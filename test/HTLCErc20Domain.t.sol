// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";

/// @notice The EIP-712 domain's version string tracks `VERSION`. Signers hardcode this
///         value off-chain, so a drift between the two silently breaks every
///         `redeemBySig` / `refundBySig` signature rather than failing loudly at deploy.
contract HTLCErc20DomainTest is Test {
    HTLCErc20 htlc;

    function setUp() public {
        htlc = new HTLCErc20(address(this));
    }

    function test_domainVersionTracksContractVersion() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("HTLCErc20"),
                keccak256(bytes(vm.toString(uint256(htlc.VERSION())))),
                block.chainid,
                address(htlc)
            )
        );

        assertEq(htlc.DOMAIN_SEPARATOR(), expected, "domain version must equal VERSION");
    }

    /// The `Refund` digest the contract verifies in `refundBySig`, under fixed terms
    /// on chain 137 at a fixed address. The backend's off-chain encoder pins the same
    /// digest (`swap/src/api/collab_refund_evm.rs`), so a drift between the two fails
    /// here and there rather than as a rejected signature on-chain.
    function test_refundDigestVector() public {
        vm.chainId(137);
        address at = 0x1000000000000000000000000000000000000001;
        deployCodeTo("HTLCErc20.sol:HTLCErc20", abi.encode(address(this)), at);
        HTLCErc20 fixture = HTLCErc20(at);

        bytes32 preimageHash = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
        uint256 amount = 100_000_000;
        address token = 0x2222222222222222222222222222222222222222;
        address sender = 0x3333333333333333333333333333333333333333;
        uint256 timelock = 1_800_000_000;

        bytes32 structHash =
            keccak256(abi.encode(fixture.TYPEHASH_REFUND(), preimageHash, amount, token, sender, timelock));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", fixture.DOMAIN_SEPARATOR(), structHash));
        assertEq(fixture.VERSION(), 7, "vector pinned for v7");
        assertEq(
            fixture.DOMAIN_SEPARATOR(),
            0xf1950b8cb4c5b064d00b1dce2ad6d34462be54ae3a76241abe58c78096d124d2,
            "domain separator"
        );
        assertEq(digest, 0x78cf422de0588e960f5d2b233491b8e4bb97baee0f087d8d75794976caa235fe, "digest");
    }

    /// The `Rehash` digest the contract verifies in `rehash`, under the same fixed terms
    /// moving to a fixed new hash and timelock. Pinned by the backend's encoder in
    /// `swap/src/api/rehash_evm.rs`.
    function test_rehashDigestVector() public {
        vm.chainId(137);
        address at = 0x1000000000000000000000000000000000000001;
        deployCodeTo("HTLCErc20.sol:HTLCErc20", abi.encode(address(this)), at);
        HTLCErc20 fixture = HTLCErc20(at);

        bytes32 preimageHash = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
        uint256 amount = 100_000_000;
        address token = 0x2222222222222222222222222222222222222222;
        address sender = 0x3333333333333333333333333333333333333333;
        uint256 timelock = 1_800_000_000;
        bytes32 newPreimageHash = bytes32(uint256(0x4444444444444444444444444444444444444444444444444444444444444444));
        uint256 newTimelock = 1_800_007_200;

        bytes32 structHash = keccak256(
            abi.encode(
                fixture.TYPEHASH_REHASH(), preimageHash, amount, token, sender, timelock, newPreimageHash, newTimelock
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", fixture.DOMAIN_SEPARATOR(), structHash));
        assertEq(fixture.VERSION(), 7, "vector pinned for v7");
        assertEq(digest, 0xb15dd9760f48c24b5009fb8d991e6a42eed6dcb3ee157baedcc20786f1908ca1, "digest");
    }
}
