// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HTLCNative} from "../src/HTLCNative.sol";
import {HTLCNativeCoordinator} from "../src/HTLCNativeCoordinator.sol";

/// @notice Deploys the native-coin HTLC pair. Same key derivation, CREATE2 salt and
///         owner handling as DeployHTLCCoordinator.s.sol; see deploy-rootstock.sh for
///         the Rootstock-specific forge flags (legacy transactions, Blockscout).
contract DeployHTLCNative is Script {
    function run() external {
        uint256 deployerPrivateKey;

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            uint32 index = uint32(vm.envOr("DERIVATION_INDEX", uint256(0)));
            deployerPrivateKey = vm.deriveKey(mnemonic, index);
        } else {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        }

        // CREATE2 salt for deterministic addresses across chains (testnet == mainnet).
        bytes32 salt = vm.envOr("DEPLOY_SALT", bytes32(0));

        // Owner of HTLCNative — may only recover balances no swap is owed. Part of the
        // init code, so it must match on every chain for the addresses to match.
        address htlcOwner = vm.envOr("HTLC_OWNER", vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);

        HTLCNative htlc = new HTLCNative{salt: salt}(htlcOwner);
        console.log("HTLCNative deployed at:", address(htlc));
        console.log("HTLCNative owner:", htlcOwner);

        HTLCNativeCoordinator coordinator = new HTLCNativeCoordinator{salt: salt}(address(htlc));
        console.log("HTLCNativeCoordinator deployed at:", address(coordinator));

        vm.stopBroadcast();
    }
}
