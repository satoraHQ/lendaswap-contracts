// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TronBridgeAdapter} from "../src/TronBridgeAdapter.sol";
import {IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "../src/interfaces/IOFT.sol";

contract TronMockToken is ERC20 {
    constructor() ERC20("USDT0", "USDT0") {
        _mint(msg.sender, 1_000_000e6);
    }
}

contract TronMockMesh is IOFT {
    TronMockToken public immutable asset;
    uint256 public constant NATIVE_FEE = 0.001 ether;
    uint256 public feeBps = 3;
    bytes32 public lastRecipient;

    constructor(TronMockToken token_) {
        asset = token_;
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function token() external view returns (address) {
        return address(asset);
    }

    function approvalRequired() external pure returns (bool) {
        return true;
    }

    function quoteSend(SendParam calldata, bool) external pure returns (MessagingFee memory) {
        return MessagingFee(NATIVE_FEE, 0);
    }

    function send(SendParam calldata param, MessagingFee calldata fee, address)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        require(msg.value == NATIVE_FEE, "wrong native fee");
        asset.transferFrom(msg.sender, address(this), param.amountLD);
        uint256 received = param.amountLD * (10000 - feeBps) / 10000;
        // Deliberately ignore param.minAmountLD to test the adapter's own guard.
        lastRecipient = param.to;
        return (MessagingReceipt(bytes32(uint256(123)), 1, fee), OFTReceipt(param.amountLD, received));
    }
}

contract TronBridgeAdapterTest is Test {
    TronMockToken token;
    TronMockMesh mesh;
    TronBridgeAdapter adapter;
    bytes32 constant RECIPIENT = bytes32(uint256(0x00a614f803b6fd780986a42c78ec9c7f77e6ded13c));
    /// 3 bps below the full 1,000,000 USDT0 balance.
    uint256 constant MIN = 999_700e6;

    function setUp() public {
        token = new TronMockToken();
        mesh = new TronMockMesh(token);
        adapter = new TronBridgeAdapter(address(token), address(mesh), address(this));
        token.approve(address(adapter), type(uint256).max);
        vm.deal(address(this), 1 ether);
    }

    function test_bridges_native_usdt_with_three_bps_fee_and_exact_gas() public {
        adapter.bridgeBalance{value: 0.002 ether}(30420, RECIPIENT, MIN);
        assertEq(mesh.lastRecipient(), RECIPIENT);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(address(mesh).balance, 0.001 ether);
        assertEq(address(adapter).balance, 0.001 ether);
        assertEq(token.allowance(address(adapter), address(mesh)), 0);
    }

    function test_reverts_entire_transfer_when_delivery_is_below_minimum() public {
        mesh.setFee(4);
        uint256 beforeBalance = token.balanceOf(address(this));
        vm.expectRevert(TronBridgeAdapter.InsufficientDelivery.selector);
        adapter.bridgeBalance{value: 0.001 ether}(30420, RECIPIENT, MIN);
        assertEq(token.balanceOf(address(this)), beforeBalance);
        assertEq(token.balanceOf(address(mesh)), 0);
    }

    function test_higher_mesh_fee_passes_when_minimum_allows_it() public {
        mesh.setFee(5);
        adapter.bridgeBalance{value: 0.001 ether}(30420, RECIPIENT, 999_500e6);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_rejects_zero_or_unreachable_minimum() public {
        vm.expectRevert(TronBridgeAdapter.InvalidAmount.selector);
        adapter.bridgeBalance{value: 0.001 ether}(30420, RECIPIENT, 0);
        vm.expectRevert(TronBridgeAdapter.InvalidAmount.selector);
        adapter.bridgeBalance{value: 0.001 ether}(30420, RECIPIENT, 1_000_000e6 + 1);
    }

    function test_rejects_wrong_destination_and_prefixed_tvm_address() public {
        vm.expectRevert(TronBridgeAdapter.InvalidRoute.selector);
        adapter.bridgeBalance{value: 0.001 ether}(30111, RECIPIENT, MIN);
        vm.expectRevert(TronBridgeAdapter.InvalidRecipient.selector);
        adapter.bridgeBalance{value: 0.001 ether}(30420, bytes32(uint256(0x41) << 160) | RECIPIENT, MIN);
        vm.expectRevert(TronBridgeAdapter.InvalidRecipient.selector);
        adapter.bridgeBalance{value: 0.001 ether}(30420, bytes32(0), MIN);
    }

    function test_insufficient_gas_rolls_back_token_pull() public {
        uint256 balance = token.balanceOf(address(this));
        vm.expectRevert(TronBridgeAdapter.InsufficientFee.selector);
        adapter.bridgeBalance(30420, RECIPIENT, MIN);
        assertEq(token.balanceOf(address(this)), balance);
    }

    function test_cannot_use_adapter_dust_to_subsidize_another_caller() public {
        vm.deal(address(adapter), 1 ether);
        vm.expectRevert(TronBridgeAdapter.InsufficientFee.selector);
        adapter.bridgeBalance(30420, RECIPIENT, MIN);
    }

    function test_owner_rescues_tokens_sent_by_mistake() public {
        token.transfer(address(adapter), 5e6);
        address recipient = makeAddr("rescue");
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(TronBridgeAdapter.NotOwner.selector);
        adapter.rescueToken(token, recipient, 5e6);
        adapter.rescueToken(token, recipient, 5e6);
        assertEq(token.balanceOf(recipient), 5e6);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    receive() external payable {}
}
