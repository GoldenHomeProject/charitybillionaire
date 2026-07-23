// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CharityForwarder, ICharityRotationSource} from "../src/CharityForwarder.sol";
import {IEndaomentOrgFundFactory, IEndaomentEntity} from "../src/interfaces/IEndaomentOrgFundFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultAdmin {
    function setCharityIndex(uint256 index) external;
    function charityIndex() external view returns (uint256);
    function charityRotationLength() external view returns (uint256);
    function charityRotation(uint256) external view returns (bytes32);
    function owner() external view returns (address);
}

/// @notice Fork test against LIVE Base mainnet. Proves the OWNERLESS, vault-derived
///         forwarder donates to BOTH an already-deployed Endaoment Org (the July-30 brick
///         case) and a not-yet-deployed Org, tracking the vault's rotation with no index of
///         its own. Runs only when BASE_RPC_URL is set.
///     BASE_RPC_URL=https://mainnet.base.org forge test --match-path test/CharityForwarder.fork.t.sol -vv
contract CharityForwarderForkTest is Test {
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IEndaomentOrgFundFactory constant FACTORY =
        IEndaomentOrgFundFactory(0x10fD9348136dCea154F752fe0B6dB45Fc298A589);
    address constant VAULT = 0x3993bD557E0d4a1E5A8Ec09a005E7Eee3E032f70;

    // rotation[3] = EIN 35-1044585 (St. Jude) — ALREADY deployed (the July-30 brick case).
    bytes32 constant ORG_DEPLOYED = 0x33352d3130343435383500000000000000000000000000000000000000000000;
    // rotation[2] = EIN 27-3521132 — NOT deployed (first-time-deploy case).
    bytes32 constant ORG_UNDEPLOYED = 0x32372d3335323131333200000000000000000000000000000000000000000000;

    CharityForwarder forwarder;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        forwarder = new CharityForwarder(USDC, FACTORY, ICharityRotationSource(VAULT));
    }

    function _fund(uint256 amount) internal {
        deal(address(USDC), address(forwarder), amount);
    }

    // Set the vault pointer so that targetOrgId() == the entry BEFORE `idx`, i.e. to target
    // rotation[k] we set charityIndex = k+1 (mirrors the post-draw state).
    function _pointForwarderAt(uint256 k) internal {
        uint256 len = IVaultAdmin(VAULT).charityRotationLength();
        uint256 idx = (k + 1) % len;
        vm.prank(IVaultAdmin(VAULT).owner());
        IVaultAdmin(VAULT).setCharityIndex(idx);
    }

    function test_targetTracksVault_offByOne() public {
        if (!forked) return;
        _pointForwarderAt(3); // want St. Jude (rotation[3])
        assertEq(forwarder.targetOrgId(), ORG_DEPLOYED, "target = just-completed draw charity");
    }

    function test_forward_to_alreadyDeployedOrg_doesNotBrick() public {
        if (!forked) return;
        _pointForwarderAt(3); // St. Jude, already deployed — the exact July-30 case
        address org = FACTORY.computeOrgAddress(ORG_DEPLOYED);
        assertGt(org.code.length, 0, "precondition: org already deployed");

        _fund(5_000_000);
        uint256 orgBefore = USDC.balanceOf(org);
        uint256 g0 = gasleft();
        (address gotOrg, uint256 amt) = forwarder.forward();
        uint256 used = g0 - gasleft();

        assertEq(gotOrg, org, "org address");
        assertEq(amt, 5_000_000, "amount");
        assertGt(USDC.balanceOf(org), orgBefore, "donation landed");
        assertEq(USDC.balanceOf(address(forwarder)), 0, "swept clean");
        emit log_named_uint("forward() gas (already-deployed org)", used);
        assertLt(used, 1_000_000, "cheap enough to never brick");
    }

    function test_forward_to_undeployedOrg_deploysAndDonates() public {
        if (!forked) return;
        _pointForwarderAt(2); // EIN 27-3521132, not deployed
        address org = FACTORY.computeOrgAddress(ORG_UNDEPLOYED);
        assertEq(org.code.length, 0, "precondition: org not deployed");

        _fund(3_000_000);
        uint256 g0 = gasleft();
        (address gotOrg, uint256 amt) = forwarder.forward();
        uint256 used = g0 - gasleft();

        assertEq(gotOrg, org, "org address");
        assertEq(amt, 3_000_000, "amount");
        assertGt(org.code.length, 0, "org got deployed");
        assertGt(USDC.balanceOf(org), 0, "donation landed");
        emit log_named_uint("forward() gas (first-time deploy)", used);
    }

    function test_forward_revertsWhenEmpty() public {
        if (!forked) return;
        vm.expectRevert(CharityForwarder.NothingToForward.selector);
        forwarder.forward();
    }

    // Dust griefing is now harmless: with no index of its own, a dust forward just donates
    // the dust to the correct (vault-derived) charity and cannot desync anything.
    function test_dustForward_isHarmless() public {
        if (!forked) return;
        _pointForwarderAt(3);
        bytes32 before = forwarder.targetOrgId();
        _fund(1); // 1 unit of USDC (dust)
        forwarder.forward();
        assertEq(forwarder.targetOrgId(), before, "target unchanged by a forward()");
    }

    // The contract is ownerless: no functions to move funds anywhere but a vetted Org.
    function test_ownerless_noFundExitExceptDonation() public {
        if (!forked) return;
        _pointForwarderAt(3);
        _fund(10_000_000);
        (address org,) = forwarder.forward();
        assertGt(org.code.length, 0, "recipient is an Endaoment org");
        assertEq(USDC.balanceOf(address(forwarder)), 0, "only exit is the donation");
    }
}
