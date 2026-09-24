// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HTLCNative} from "../src/HTLCNative.sol";
import {HTLCNativeCoordinator} from "../src/HTLCNativeCoordinator.sol";

/// @notice Deploys the native-coin HTLC pair. Same key derivation, CREATE2 salt and
///         owner handling as DeployHTLCCoordinator.s.sol; see deploy-rootstock.sh for
///         the Rootstock-specific forge flags (legacy transactions, Blockscout).
///
///         Idempotent: a contract whose CREATE2 address already holds code is reused
///         instead of redeployed, so a run that broke between the two deployments
///         (Rootstock's per-account tx-pool quota rejects the second tx of a burst)
///         is resumed by running the same command again.
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

        // Same factory as forge's salted `new`, so the prediction matches the deploy.
        address htlcAddress = vm.computeCreate2Address(
            salt, keccak256(abi.encodePacked(type(HTLCNative).creationCode, abi.encode(htlcOwner)))
        );
        HTLCNative htlc;
        if (htlcAddress.code.length > 0) {
            htlc = HTLCNative(htlcAddress);
            console.log("HTLCNative already deployed at:", htlcAddress);
        } else {
            htlc = new HTLCNative{salt: salt}(htlcOwner);
            console.log("HTLCNative deployed at:", address(htlc));
        }
        console.log("HTLCNative owner:", htlcOwner);

        address coordinatorAddress = vm.computeCreate2Address(
            salt, keccak256(abi.encodePacked(type(HTLCNativeCoordinator).creationCode, abi.encode(address(htlc))))
        );
        if (coordinatorAddress.code.length > 0) {
            console.log("HTLCNativeCoordinator already deployed at:", coordinatorAddress);
        } else {
            HTLCNativeCoordinator coordinator = new HTLCNativeCoordinator{salt: salt}(address(htlc));
            console.log("HTLCNativeCoordinator deployed at:", address(coordinator));
        }

        vm.stopBroadcast();
    }
}
