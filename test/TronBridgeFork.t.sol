// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TronBridgeAdapter} from "../src/TronBridgeAdapter.sol";
import {IOFT, SendParam, MessagingFee} from "../src/interfaces/IOFT.sol";

/// @dev Opt-in fork only. No signing keys or live broadcasts.
contract TronBridgeForkTest is Test {
    function test_live_arbitrum_mesh_accepts_tron_payout() public {
        string memory rpc = vm.envOr("TRON_BRIDGE_FORK_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        IERC20 token = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
        IOFT mesh = IOFT(0x77652D5aba086137b595875263FC200182919B92);
        TronBridgeAdapter adapter = new TronBridgeAdapter(address(token), address(mesh), address(this));
        uint256 existingAdapterBalance = token.balanceOf(address(adapter));
        uint256 amount = 100e6;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("Tron payout recipient"))));
        SendParam memory param = SendParam(30420, recipient, amount, 99_970_000, "", "", "");
        MessagingFee memory fee = mesh.quoteSend(param, false);
        deal(address(token), address(this), amount);
        vm.deal(address(this), fee.nativeFee * 2);
        token.approve(address(adapter), amount);
        adapter.bridgeBalance{value: fee.nativeFee}(30420, recipient, 99_970_000);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(adapter)), existingAdapterBalance);
        assertEq(token.allowance(address(adapter), address(mesh)), 0);
    }
}
