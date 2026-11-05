// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";
import {HTLCNative} from "../src/HTLCNative.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 100e18);
    }
}

/// @notice The EIP-712 domain's version string tracks `VERSION`, and the domain name
///         plus the `token`-less struct keep an `HTLCNative` signature from ever
///         recovering to the claimant on `HTLCErc20` (or vice versa), on any chain.
contract HTLCNativeDomainTest is Test {
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    HTLCNative htlc;
    HTLCErc20 erc20;
    MockToken token;

    address alice = makeAddr("alice");
    address relayer = makeAddr("relayer");
    uint256 bobPk;
    address bob;

    bytes32 preimage = bytes32(uint256(0xdeadbeef));
    bytes32 preimageHash;
    uint256 amount = 1 ether;
    uint256 timelock;

    function setUp() public {
        htlc = new HTLCNative(address(this));
        erc20 = new HTLCErc20(address(this));
        token = new MockToken();
        (bob, bobPk) = makeAddrAndKey("bob");
        preimageHash = sha256(abi.encodePacked(preimage));
        timelock = block.timestamp + 1 hours;

        vm.deal(alice, 10 ether);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.approve(address(erc20), type(uint256).max);
    }

    function test_domainVersionTracksContractVersion() public view {
        bytes32 expected = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("HTLCNative"),
                keccak256(bytes(vm.toString(uint256(htlc.VERSION())))),
                block.chainid,
                address(htlc)
            )
        );

        assertEq(htlc.DOMAIN_SEPARATOR(), expected, "domain version must equal VERSION");
    }

    function test_redeemTypehashHasNoTokenField() public view {
        assertEq(
            htlc.TYPEHASH_REDEEM(),
            keccak256(
                "Redeem(bytes32 preimage,uint256 amount,address sender,uint256 timelock,address caller,address destination,address sweepToken,uint256 minAmountOut,bytes32 callsHash)"
            ),
            "typehash"
        );
        assertTrue(htlc.TYPEHASH_REDEEM() != erc20.TYPEHASH_REDEEM(), "struct differs from the ERC20 one");
    }

    /// The digest is `\x19\x01 || domainSeparator || structHash` with `caller = msg.sender`.
    function test_digestIsWhatTheContractVerifies() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        bytes32 structHash = keccak256(
            abi.encode(
                htlc.TYPEHASH_REDEEM(),
                preimage,
                amount,
                alice,
                timelock,
                relayer,
                bob,
                address(0),
                uint256(0),
                bytes32(0)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", htlc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(relayer);
        address recovered = htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);
        assertEq(recovered, bob, "digest accepted");
        assertEq(relayer.balance, amount, "settled");
    }

    // -- Cross-contract replay --

    /// A signature Bob made for the ERC20 contract over the same terms (token = 0) must
    /// not settle the native swap: the domain name and the struct differ.
    function test_erc20SignatureDoesNotRedeemOnNative() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        bytes32 structHash = keccak256(
            abi.encode(
                erc20.TYPEHASH_REDEEM(),
                preimage,
                amount,
                address(0),
                alice,
                timelock,
                relayer,
                bob,
                address(0),
                uint256(0),
                bytes32(0)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", erc20.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);

        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "still active");
    }

    /// And the other way round: a native signature over the same terms is not an
    /// authorisation on the ERC20 contract.
    function test_nativeSignatureDoesNotRedeemOnErc20() public {
        vm.prank(alice);
        erc20.create(preimageHash, amount, address(token), bob, timelock);

        (uint8 v, bytes32 r, bytes32 s) = _signNative(htlc.DOMAIN_SEPARATOR(), relayer);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCErc20.SwapNotActive.selector);
        erc20.redeemBySig(preimage, amount, address(token), alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);

        assertTrue(erc20.isActive(preimageHash, amount, address(token), alice, bob, timelock), "still active");
    }

    // -- Cross-chain replay --

    function test_signatureForAnotherChain_doesNotRedeem() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        // Same contract address and name, but the domain of a different chain.
        bytes32 foreignDomain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("HTLCNative"),
                keccak256(bytes(vm.toString(uint256(htlc.VERSION())))),
                block.chainid + 1,
                address(htlc)
            )
        );
        assertTrue(foreignDomain != htlc.DOMAIN_SEPARATOR(), "chainId is part of the domain");

        (uint8 v, bytes32 r, bytes32 s) = _signNative(foreignDomain, relayer);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);

        assertTrue(htlc.isActive(preimageHash, amount, address(0), alice, bob, timelock), "still active");
    }

    /// The domain is deliberately fixed at deployment. Should a fork ever change
    /// `chainid`, both forks keep the deployment separator and a signature made before
    /// the fork settles on both. That is accepted: the swap state is identical on both
    /// forks and a redeem pays the signed destination on each, so the claimant only
    /// settles a swap they are already entitled to. Signatures made after the fork,
    /// with the new chain id in the domain, are rejected by both.
    function test_domainSeparatorIsPinnedAtDeployment() public {
        bytes32 before = htlc.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertEq(htlc.DOMAIN_SEPARATOR(), before, "immutable across a chain-id change");
    }

    function test_preForkSignatureStillRedeemsAfterChainIdChange() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        // Signed under the deployment chain id, submitted after the chain id changed.
        (uint8 v, bytes32 r, bytes32 s) = _signNative(htlc.DOMAIN_SEPARATOR(), relayer);
        vm.chainId(block.chainid + 1);

        vm.prank(relayer);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);

        assertEq(relayer.balance, amount, "the signed caller is paid on the forked chain too");
    }

    function test_postForkSignatureWithNewChainId_doesNotRedeem() public {
        vm.prank(alice);
        htlc.create{value: amount}(preimageHash, bob, timelock);

        vm.chainId(block.chainid + 1);
        bytes32 newChainDomain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("HTLCNative"),
                keccak256(bytes(vm.toString(uint256(htlc.VERSION())))),
                block.chainid,
                address(htlc)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = _signNative(newChainDomain, relayer);

        vm.prank(relayer);
        vm.expectPartialRevert(HTLCNative.SwapNotActive.selector);
        htlc.redeemBySig(preimage, amount, alice, timelock, bob, address(0), 0, bytes32(0), v, r, s);
    }

    // -- Off-chain vector --

    /// The signature vector the SDK test reuses: chain 30, a fixed contract address, a
    /// fixed claimant key and fixed terms. Also proves the vector settles on-chain.
    function test_offChainSignatureVector() public {
        vm.chainId(30);
        address at = 0x1000000000000000000000000000000000000001;
        deployCodeTo("HTLCNative.sol:HTLCNative", abi.encode(address(this)), at);
        HTLCNative fixture = HTLCNative(at);

        uint256 claimPk = 0x4444444444444444444444444444444444444444444444444444444444444444;
        address claimant = vm.addr(claimPk);
        address sender = 0x3333333333333333333333333333333333333333;
        // In production `caller` is the coordinator contract, which enforces the
        // destination / sweep terms after the HTLC pays it. The vector keeps a fixed
        // address so the pinned digest and signature below stay stable.
        address coordinator = 0x5555555555555555555555555555555555555555;
        bytes32 fixturePreimage = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
        uint256 fixtureAmount = 100_000_000;
        uint256 fixtureTimelock = 1_800_000_000;

        bytes32 structHash = keccak256(
            abi.encode(
                fixture.TYPEHASH_REDEEM(),
                fixturePreimage,
                fixtureAmount,
                sender,
                fixtureTimelock,
                coordinator,
                claimant,
                address(0),
                uint256(0),
                bytes32(0)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", fixture.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimPk, digest);

        console.log("claimant", claimant);
        console.logBytes32(fixture.DOMAIN_SEPARATOR());
        console.logBytes32(digest);
        console.log("v", v);
        console.logBytes32(r);
        console.logBytes32(s);

        assertEq(claimant, 0x7564105E977516C53bE337314c7E53838967bDaC, "claimant");
        assertEq(
            fixture.DOMAIN_SEPARATOR(),
            0x1c9fb995b3c88f27a230057d6506e0ee2cc01e0fa343ddf8686ec40de9a8cca2,
            "domain separator"
        );
        assertEq(digest, 0xac9ed08bcc1fe72a670f9a87a5da9c7d99a4316f2be3031b32b30df9b01ee636, "digest");
        assertEq(v, 27, "v");
        assertEq(r, 0xe1dd1fad6f404ecaaa4ba9ce36afdba8e99a514a23e7a745157bfc38c2f01f16, "r");
        assertEq(s, 0x06f6b85450b1b97dd3a762dfba22d3cec5642968382f32fed3882b31da024e45, "s");

        // The vector settles: lock under the fixture's terms and submit it as `coordinator`.
        // (The sha256 precompile is a call and would consume the prank if inlined.)
        bytes32 fixtureHash = sha256(abi.encodePacked(fixturePreimage));
        vm.deal(sender, fixtureAmount);
        vm.prank(sender);
        fixture.create{value: fixtureAmount}(fixtureHash, claimant, fixtureTimelock);

        vm.prank(coordinator);
        address recovered = fixture.redeemBySig(
            fixturePreimage, fixtureAmount, sender, fixtureTimelock, claimant, address(0), 0, bytes32(0), v, r, s
        );
        assertEq(recovered, claimant, "vector recovers the claimant");
        assertEq(coordinator.balance, fixtureAmount, "vector settles");
    }

    // -- Helpers --

    function _signNative(bytes32 domainSeparator, address caller)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                htlc.TYPEHASH_REDEEM(),
                preimage,
                amount,
                alice,
                timelock,
                caller,
                bob,
                address(0),
                uint256(0),
                bytes32(0)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(bobPk, digest);
    }

    /// The `Refund` digest the contract verifies in `refundBySig`, under fixed terms
    /// on chain 30 at a fixed address. The backend's off-chain encoder pins the same
    /// digest (`swap/src/api/collab_refund_evm.rs`).
    function test_refundDigestVector() public {
        vm.chainId(30);
        address at = 0x1000000000000000000000000000000000000001;
        deployCodeTo("HTLCNative.sol:HTLCNative", abi.encode(address(this)), at);
        HTLCNative fixture = HTLCNative(at);

        bytes32 preimageHash = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
        uint256 amount = 100_000_000;
        address sender = 0x3333333333333333333333333333333333333333;
        uint256 timelock = 1_800_000_000;

        bytes32 structHash = keccak256(abi.encode(fixture.TYPEHASH_REFUND(), preimageHash, amount, sender, timelock));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", fixture.DOMAIN_SEPARATOR(), structHash));
        assertEq(fixture.VERSION(), 2, "vector pinned for v2");
        assertEq(
            fixture.DOMAIN_SEPARATOR(),
            0x1c9fb995b3c88f27a230057d6506e0ee2cc01e0fa343ddf8686ec40de9a8cca2,
            "domain separator"
        );
        assertEq(digest, 0xa8e3d1917c9e493c12d106d1caae2af58413bba3905dc940c466ef52ad748e84, "digest");
    }

    /// The `Rehash` digest the contract verifies in `rehash`, under the same fixed terms
    /// moving to a fixed new hash and timelock. Pinned by the backend's encoder in
    /// `swap/src/api/rehash_evm.rs`.
    function test_rehashDigestVector() public {
        vm.chainId(30);
        address at = 0x1000000000000000000000000000000000000001;
        deployCodeTo("HTLCNative.sol:HTLCNative", abi.encode(address(this)), at);
        HTLCNative fixture = HTLCNative(at);

        bytes32 preimageHash = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
        uint256 amount = 100_000_000;
        address sender = 0x3333333333333333333333333333333333333333;
        uint256 timelock = 1_800_000_000;
        bytes32 newPreimageHash = bytes32(uint256(0x4444444444444444444444444444444444444444444444444444444444444444));
        uint256 newTimelock = 1_800_007_200;

        bytes32 structHash = keccak256(
            abi.encode(fixture.TYPEHASH_REHASH(), preimageHash, amount, sender, timelock, newPreimageHash, newTimelock)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", fixture.DOMAIN_SEPARATOR(), structHash));
        assertEq(fixture.VERSION(), 2, "vector pinned for v2");
        assertEq(digest, 0x26634d5ccd7e33ff7295f11837232efe2de59bd0bd122631326633fe007c973e, "digest");
    }
}
