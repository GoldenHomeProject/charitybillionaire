// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CharityPrizeVault} from "../src/CharityPrizeVault.sol";

interface IAutomationRegistry {
    function cancelUpkeep(uint256 id) external;
}

/// @notice Retire the pre-audit deploy: withdraw the deployer's seed principal from the
///         old (unhardened) vault and cancel its Automation upkeep so only the hardened
///         v2 stack draws. The old upkeep's LINK becomes reclaimable after the registry's
///         cancellation delay via withdrawFunds (easiest from the automation.chain.link UI).
contract Cleanup is Script {
    function run() external {
        CharityPrizeVault oldVault = CharityPrizeVault(vm.envAddress("OLD_VAULT_ADDRESS"));
        address me = vm.envAddress("OWNER");
        address registry = vm.envAddress("AUTOMATION_REGISTRY");
        uint256 oldUpkeep = vm.envUint("OLD_AUTOMATION_UPKEEP_ID");

        vm.startBroadcast();

        uint256 bal = oldVault.balanceOf(me);
        if (bal > 0) oldVault.withdraw(bal);

        IAutomationRegistry(registry).cancelUpkeep(oldUpkeep);

        vm.stopBroadcast();

        console2.log("Withdrew from old vault (USDC, 6dp):", bal);
        console2.log("Cancelled old upkeep:", oldUpkeep);
        console2.log("Old upkeep LINK is reclaimable after the cancellation delay (UI: Withdraw funds).");
    }
}
