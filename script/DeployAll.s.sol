// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CharityPrizeVault} from "../src/CharityPrizeVault.sol";
import {ChainlinkVRFProvider} from "../src/ChainlinkVRFProvider.sol";
import {VRFProviderOwner} from "../src/VRFProviderOwner.sol";
import {DrawUpkeep, IDrawVault} from "../src/DrawUpkeep.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {IRandomProvider} from "../src/interfaces/IRandomProvider.sol";

interface IVRFCoordinatorConsumer {
    function addConsumer(uint256 subId, address consumer) external;
}

/// @notice One-broadcast bring-up of the FULL hardened (post-audit) stack on Base
///         Sepolia. Does everything the deployer can sign in a single tx batch:
///         deploy adapter + vault + the C-1 owner-lock, wire them, add the adapter as a
///         VRF consumer, deploy the DrawUpkeep automation target, seed the vault, and
///         set a visible charity. The only remaining manual step is registering a
///         custom-logic Automation upkeep at the printed DrawUpkeep address (or firing
///         requestDraw manually — it is permissionless).
contract DeployAll is Script {
    function run() external {
        address coordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEYHASH");
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");

        address asset = vm.envAddress("USDC");
        address aavePool = vm.envAddress("AAVE_POOL");
        address aToken = vm.envAddress("AAVE_AUSDC");
        address companyTreasury = vm.envAddress("COMPANY_TREASURY");
        address operator = vm.envAddress("OPERATOR");
        address owner = vm.envAddress("OWNER");

        address charity = vm.envAddress("CHARITY_ADDRESS");
        uint256 seedAmount = vm.envUint("SEED_AMOUNT");

        vm.startBroadcast();

        // 1) Randomness adapter + vault, wired together.
        ChainlinkVRFProvider adapter = new ChainlinkVRFProvider(coordinator, keyHash, subId);
        CharityPrizeVault vault = new CharityPrizeVault(
            IERC20(asset),
            IAavePool(aavePool),
            IERC20(aToken),
            IRandomProvider(address(adapter)),
            companyTreasury,
            operator,
            owner
        );
        adapter.setVault(address(vault));

        // 2) C-1 fix: hand the adapter's ownership to the immutable lock so no human
        //    can ever repoint the VRF coordinator and rig the winner.
        VRFProviderOwner providerOwner = new VRFProviderOwner(address(adapter), owner);
        adapter.transferOwnership(address(providerOwner));
        providerOwner.acceptProviderOwnership();

        // 3) Register the adapter as a consumer on the existing VRF subscription
        //    (deployer is the subscription owner).
        IVRFCoordinatorConsumer(coordinator).addConsumer(subId, address(adapter));

        // 4) Automation target that tracks nextDrawTime exactly and self-heals.
        DrawUpkeep upkeep = new DrawUpkeep(IDrawVault(address(vault)));

        // 5) Seed so eligibleTotal > 0 (operator is a burner on testnet, so this
        //    deposit is eligible to win), and set a visible charity for the 5% slice.
        IERC20(asset).approve(address(vault), seedAmount);
        vault.deposit(seedAmount);
        vault.allowCharity(charity, true);
        vault.setCharity(charity);

        vm.stopBroadcast();

        console2.log("ChainlinkVRFProvider (adapter):", address(adapter));
        console2.log("CharityPrizeVault (vault):     ", address(vault));
        console2.log("VRFProviderOwner (lock):       ", address(providerOwner));
        console2.log("DrawUpkeep:                    ", address(upkeep));
        console2.log("adapter.owner() == lock:       ", adapter.owner() == address(providerOwner));
        console2.log("vault.eligibleTotal():         ", vault.eligibleTotal());
        console2.log("vault.nextDrawTime():          ", vault.nextDrawTime());
        console2.log("");
        console2.log("NEXT: register a custom-logic Automation upkeep at the DrawUpkeep address,");
        console2.log("      or fire vault.requestDraw() manually at the scheduled time.");
    }
}
