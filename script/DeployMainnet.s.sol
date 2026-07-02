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

/// @notice MAINNET bring-up of the hardened stack on Base mainnet (chainId 8453).
///         Differs from DeployAll (testnet) in two deliberate ways:
///           1. NO seeding and NO burner operator — every ownership/role address is the
///              LLC-controlled wallet (Golden Home Project, LLC), read from env. The
///              operator is the LLC wallet, so the company's own deposits are excluded
///              from winning ("the owner can't win").
///           2. Charity, Endaoment, and any seed deposit are deliberate POST-deploy owner
///              actions (see docs/mainnet-runbook.md), not baked in here.
///
///         Reads every address/param from env (.env.mainnet). VERIFY every address
///         against official sources (Circle, aave-address-book, docs.chain.link) before
///         broadcasting with real funds. The deployer signing this MUST be the LLC wallet
///         (it becomes owner/treasury/operator and the VRF subscription owner).
contract DeployMainnet is Script {
    function run() external {
        // Chainlink VRF (Base mainnet)
        address coordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEYHASH");
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");

        // Protocol addresses (Base mainnet)
        address asset = vm.envAddress("USDC"); // Circle USDC, 6 decimals
        address aavePool = vm.envAddress("AAVE_POOL");
        address aToken = vm.envAddress("AAVE_AUSDC");

        // Ownership — ALL the LLC-controlled wallet (Golden Home Project, LLC) or its Safe.
        // owner: admin (charity rotation, treasury/Endaoment config); also the VRF lock admin.
        // companyTreasury: receives the 5% operations slice.
        // operator: excluded from winning (the company's own deposits cannot win).
        address llcOwner = vm.envAddress("OWNER");
        address companyTreasury = vm.envAddress("COMPANY_TREASURY");
        address operator = vm.envAddress("OPERATOR");

        require(llcOwner != address(0) && companyTreasury != address(0), "LLC owner/treasury required");

        vm.startBroadcast();

        // 1) Adapter + vault, wired.
        ChainlinkVRFProvider adapter = new ChainlinkVRFProvider(coordinator, keyHash, subId);
        CharityPrizeVault vault = new CharityPrizeVault(
            IERC20(asset),
            IAavePool(aavePool),
            IERC20(aToken),
            IRandomProvider(address(adapter)),
            companyTreasury,
            operator,
            llcOwner
        );
        adapter.setVault(address(vault));

        // 2) C-1 lock: the adapter's owner becomes the immutable lock (admin = LLC), so no
        //    human can ever repoint the VRF coordinator.
        VRFProviderOwner providerOwner = new VRFProviderOwner(address(adapter), llcOwner);
        adapter.transferOwnership(address(providerOwner));
        providerOwner.acceptProviderOwnership();

        // 3) Register the adapter as a consumer on the (deployer-owned) VRF subscription.
        IVRFCoordinatorConsumer(coordinator).addConsumer(subId, address(adapter));

        // 4) Automation target.
        DrawUpkeep upkeep = new DrawUpkeep(IDrawVault(address(vault)));

        vm.stopBroadcast();

        console2.log("== Base MAINNET deploy ==");
        console2.log("ChainlinkVRFProvider (adapter):", address(adapter));
        console2.log("CharityPrizeVault (vault):     ", address(vault));
        console2.log("VRFProviderOwner (lock):       ", address(providerOwner));
        console2.log("DrawUpkeep:                    ", address(upkeep));
        console2.log("vault.owner()/treasury/operator = LLC:", vault.owner() == llcOwner);
        console2.log("adapter.owner() == lock:       ", adapter.owner() == address(providerOwner));
        console2.log("");
        console2.log("POST-DEPLOY (owner actions, see docs/mainnet-runbook.md):");
        console2.log(" - Endaoment rotation: setEndaomentFactory + setCharityRotation([orgIds]) + setUseEndaoment(true)");
        console2.log("   (or direct fallback: allowCharity + setCharity)");
        console2.log(" - verify all 4 contracts on Basescan");
        console2.log(" - register a custom-logic Automation upkeep -> the DrawUpkeep address");
        console2.log(" - update web/app.js to mainnet (chainId 8453, addresses, RPC) + CSP connect-src");
        console2.log(" - optional: seed the pool from the LLC wallet (excluded from winning)");
    }
}
