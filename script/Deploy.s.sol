// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CharityPrizeVault} from "../src/CharityPrizeVault.sol";
import {ChainlinkVRFProvider} from "../src/ChainlinkVRFProvider.sol";
import {VRFProviderOwner} from "../src/VRFProviderOwner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {IRandomProvider} from "../src/interfaces/IRandomProvider.sol";

/// @notice Deploys the production randomness adapter + the vault and wires them
///         together, resolving the constructor circular dependency via the adapter's
///         one-time `setVault`. Reads every address/param from the environment (.env).
///
/// Run (Base Sepolia), supplying the deployer key on the CLI so it never lives on disk:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url https://sepolia.base.org \
///     --private-key $YOUR_DEPLOYER_KEY \
///     --broadcast
///
/// After this completes you still must (per the deploy ORDER):
///   1. Add the printed ADAPTER address as a consumer on the VRF subscription
///      (vrf.chain.link UI).
///   2. Register a time-based Automation upkeep calling vault.requestDraw() weekly
///      (automation.chain.link UI).
contract Deploy is Script {
    function run() external {
        // --- Constructor inputs from .env ---
        address coordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEYHASH");
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");

        address asset = vm.envAddress("USDC");
        address aavePool = vm.envAddress("AAVE_POOL");
        address aToken = vm.envAddress("AAVE_AUSDC");
        address companyTreasury = vm.envAddress("COMPANY_TREASURY");
        address operator = vm.envAddress("OPERATOR");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast();

        // 1) Randomness adapter (deployer becomes its owner via VRFConsumerBaseV2Plus).
        ChainlinkVRFProvider adapter = new ChainlinkVRFProvider(coordinator, keyHash, subId);

        // 2) Vault, pointed at the adapter as its immutable randomProvider.
        CharityPrizeVault vault = new CharityPrizeVault(
            IERC20(asset),
            IAavePool(aavePool),
            IERC20(aToken),
            IRandomProvider(address(adapter)),
            companyTreasury,
            operator,
            owner
        );

        // 3) Close the loop: tell the adapter which vault it serves (one-time, frozen).
        adapter.setVault(address(vault));

        // 4) Lock down the adapter's ownership so NO human can repoint the VRF
        //    coordinator and rig the winner (audit finding C-1). The lock has no
        //    setCoordinator path; Chainlink's coordinator-migration path still works.
        //    Admin (bounded gas tuning only) = owner, intended to be a multisig.
        VRFProviderOwner providerOwner = new VRFProviderOwner(address(adapter), owner);
        adapter.transferOwnership(address(providerOwner));
        providerOwner.acceptProviderOwnership();

        vm.stopBroadcast();

        console2.log("ChainlinkVRFProvider (adapter):", address(adapter));
        console2.log("CharityPrizeVault (vault):     ", address(vault));
        console2.log("VRFProviderOwner (lock):       ", address(providerOwner));
        console2.log("adapter.owner() is now lock:   ", adapter.owner() == address(providerOwner));
        console2.log("");
        console2.log("NEXT: add the adapter as a consumer on VRF sub", subId);
        console2.log("THEN: register a custom-logic Automation upkeep -> DrawUpkeep");
    }
}
