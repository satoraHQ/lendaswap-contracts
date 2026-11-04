// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TronBridgeAdapter} from "../src/TronBridgeAdapter.sol";

contract DeployTronBridgeAdapter is Script {
    function run() external {
        require(block.chainid == 42161, "Arbitrum mainnet only");
        // Same key handling as DeployUSDT0BridgeAdapter: MNEMONIC (+ DERIVATION_INDEX)
        // from script/.env, or PRIVATE_KEY.
        uint256 key;
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            key = vm.deriveKey(mnemonic, uint32(vm.envOr("DERIVATION_INDEX", uint256(0))));
        } else {
            key = vm.envUint("PRIVATE_KEY");
        }
        address token = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        // https://docs.usdt0.to/api/deployments -> usdt0.legacyMesh.Arbitrum
        address mesh = 0x77652D5aba086137b595875263FC200182919B92;
        vm.startBroadcast(key);
        TronBridgeAdapter adapter = new TronBridgeAdapter(token, mesh, vm.envOr("OWNER", vm.addr(key)));
        vm.stopBroadcast();
        console.log("contracts.arbitrum.tron_bridge.adapter:", address(adapter));
        console.log("Owner:", adapter.owner());
    }
}
