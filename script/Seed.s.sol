// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CharityPrizeVault} from "../src/CharityPrizeVault.sol";
import {DrawUpkeep, IDrawVault} from "../src/DrawUpkeep.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVRFSubscriptionManager {
    function addConsumer(uint256 subId, address consumer) external;
}

interface IAutomationRegistry {
    function cancelUpkeep(uint256 id) external;
}

/// @notice Post-deploy wiring + testnet seeding for the Thursday-schedule vault, in
///         ONE broadcast: registers the new adapter as a VRF consumer, deploys the
///         DrawUpkeep automation target, pulls the deployer's principal out of the
///         retired vault, seeds the new vault so eligibleTotal > 0 (operator is a
///         burner, so this deposit CAN win), sets a visible charity, and cancels the
///         old vault's Automation upkeep (its LINK is withdrawable ~50 blocks later).
contract Seed is Script {
    function run() external {
        address coordinator = vm.envAddress("VRF_COORDINATOR");
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        address adapter = vm.envAddress("VRF_PROVIDER_ADDRESS");
        CharityPrizeVault vault = CharityPrizeVault(vm.envAddress("VAULT_ADDRESS"));
        CharityPrizeVault oldVault = CharityPrizeVault(vm.envAddress("OLD_VAULT_ADDRESS"));
        IERC20 usdc = IERC20(vm.envAddress("USDC"));
        address charity = vm.envAddress("CHARITY_ADDRESS");
        address registry = vm.envAddress("AUTOMATION_REGISTRY");
        uint256 oldUpkeepId = vm.envUint("OLD_AUTOMATION_UPKEEP_ID");
        uint256 seedAmount = vm.envUint("SEED_AMOUNT");
        address me = vm.envAddress("OWNER");

        vm.startBroadcast();

        // 1) New adapter becomes a consumer on the existing VRF subscription.
        IVRFSubscriptionManager(coordinator).addConsumer(subId, adapter);

        // 2) Automation target that tracks nextDrawTime exactly (and self-heals).
        DrawUpkeep upkeep = new DrawUpkeep(IDrawVault(address(vault)));

        // 3) Reclaim principal from the retired rolling-schedule vault.
        uint256 oldBal = oldVault.balanceOf(me);
        if (oldBal > 0) oldVault.withdraw(oldBal);

        // 4) Seed the new vault so the smoke-test draw has an eligible depositor.
        usdc.approve(address(vault), seedAmount);
        vault.deposit(seedAmount);

        // 5) Visible charity so the 5% slice lands somewhere observable on-chain.
        vault.allowCharity(charity, true);
        vault.setCharity(charity);

        // 6) Retire the old vault's time-based upkeep.
        IAutomationRegistry(registry).cancelUpkeep(oldUpkeepId);

        vm.stopBroadcast();

        console2.log("DrawUpkeep:", address(upkeep));
        console2.log("vault nextDrawTime:", vault.nextDrawTime());
        console2.log("vault eligibleTotal:", vault.eligibleTotal());
        console2.log("");
        console2.log("NEXT: register a CUSTOM LOGIC Automation upkeep at the DrawUpkeep address");
    }
}
