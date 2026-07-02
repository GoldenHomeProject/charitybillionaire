// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CharityPrizeVault} from "../src/CharityPrizeVault.sol";

/// @notice One-shot post-deploy owner configuration for the LIVE Base mainnet vault.
///         Bundles every owner call into a SINGLE broadcast so it's one keystore-password
///         entry instead of four separate `cast send` commands — and it's reproducible and
///         auditable (the charity list lives in version control, not a shell history).
///         Run once, signed by the LLC owner wallet:
///
///   forge script script/ConfigureMainnet.s.sol:ConfigureMainnet \
///     --rpc-url "$BASE_MAINNET_RPC_URL" --account deployer --broadcast --slow
///
contract ConfigureMainnet is Script {
    // Live Base mainnet deploy (2026-06-24).
    CharityPrizeVault constant VAULT = CharityPrizeVault(0x3993bD557E0d4a1E5A8Ec09a005E7Eee3E032f70);
    // Endaoment OrgFundFactory on Base mainnet (verified on-chain).
    address constant ENDAOMENT_FACTORY = 0x10fD9348136dCea154F752fe0B6dB45Fc298A589;
    // Self-healing keeper bounty: $1 (USDC, 6 decimals). Paid from the company slice only
    // when a draw is fired late. Set to 0 to disable.
    uint256 constant DRAW_BOUNTY = 1_000_000;

    function run() external {
        // 10 vetted charities, in weekly-rotation order. A bytes32 string literal is the
        // EIN encoded exactly as Endaoment expects (ASCII, left-aligned, zero-padded =
        // formatBytes32String). EINs cross-verified (ProPublica + Charity Navigator + IRS).
        bytes32[] memory rotation = new bytes32[](10);
        rotation[0] = "95-1831116"; // Direct Relief
        rotation[1] = "36-3673599"; // Feeding America (national)
        rotation[2] = "27-3521132"; // World Central Kitchen
        rotation[3] = "35-1044585"; // ALSAC / St. Jude (donation entity, NOT hospital 62-0646012)
        rotation[4] = "20-3069841"; // Against Malaria Foundation (US 501c3)
        rotation[5] = "27-1661997"; // GiveDirectly
        rotation[6] = "22-3936753"; // charity: water (Charity Global, Inc.)
        rotation[7] = "13-3433452"; // Doctors Without Borders USA (MSF-USA)
        rotation[8] = "91-1914868"; // Habitat for Humanity International (national)
        rotation[9] = "53-0242652"; // The Nature Conservancy (national)

        vm.startBroadcast();
        VAULT.setEndaomentFactory(ENDAOMENT_FACTORY);
        VAULT.setCharityRotation(rotation);
        VAULT.setUseEndaoment(true);
        VAULT.setDrawBounty(DRAW_BOUNTY);
        vm.stopBroadcast();

        console2.log("Configured. current charity orgId:");
        console2.logBytes32(VAULT.currentCharityOrgId());
        console2.log("next charity orgId:");
        console2.logBytes32(VAULT.nextCharityOrgId());
        console2.log("useEndaoment:", VAULT.useEndaoment());
        console2.log("drawBounty:", VAULT.drawBounty());
    }
}
