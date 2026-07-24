// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IEndaomentOrgFundFactory, IEndaomentEntity} from "./interfaces/IEndaomentOrgFundFactory.sol";

/// @notice Minimal read interface into the prize vault's weekly charity rotation.
interface ICharityRotationSource {
    function charityIndex() external view returns (uint256);
    function charityRotationLength() external view returns (uint256);
    function charityRotation(uint256 index) external view returns (bytes32);
}

/// @title  CharityForwarder
/// @notice Receives the weekly charity slice from the prize vault and donates it to that
///         week's charity via Endaoment — in its OWN transaction, decoupled from the VRF
///         draw callback.
///
///         WHY THIS EXISTS: the vault used to donate to Endaoment inside the draw's VRF
///         callback. When a charity's Endaoment Org was already deployed, that path hit a
///         failed CREATE2 (`deployOrgAndDonate` reverts on an existing Org); a failed
///         CREATE2 burns ~all forwarded gas, so under the callback's fixed 1.5M gas budget
///         the whole draw reverted to `DrawSkipped` — no winner paid, rotation frozen.
///         This forwarder moves the donation OUT of that gas-starved callback: the draw
///         simply transfers the slice here (a cheap ERC20 transfer that can never brick),
///         and a separate, permissionless `forward()` — run with a full block's gas —
///         donates it onward. It checks whether the Org already exists and calls `donate`
///         directly in that case, so it NEVER triggers the failing CREATE2 at all.
///
///         SINGLE SOURCE OF TRUTH: the forwarder holds NO rotation state of its own. It
///         reads the target charity straight from the vault. The vault advances its
///         `charityIndex` once per completed draw (AFTER transferring the slice here), so
///         the charity owed the pending slice is the entry just BEHIND the vault's current
///         pointer: `rotation[(charityIndex - 1) mod len]`. This keeps the forwarder in
///         perfect lockstep with the vault (and the site, which already reads the vault) —
///         no independent index to drift, and dust sent by a griefer just donates that dust
///         to the correct charity and changes nothing.
///
///         CUSTODY GUARANTEE: this contract is OWNERLESS and has no withdraw, no receive/
///         fallback, no delegatecall. The ONLY exit for funds is a donation to the vault's
///         current vetted rotation charity via Endaoment. There is no path — for anyone —
///         to move the held asset to an arbitrary, personal, or company address. Ever.
contract CharityForwarder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The donated asset (USDC). Immutable.
    IERC20 public immutable asset;
    /// @notice Endaoment's OrgFundFactory. Immutable.
    IEndaomentOrgFundFactory public immutable endaomentFactory;
    /// @notice The prize vault whose weekly rotation this forwarder mirrors. Immutable.
    ICharityRotationSource public immutable vault;

    error EmptyRotation();
    error NothingToForward();

    /// @notice A weekly slice was donated onward to a charity.
    event CharityForwarded(bytes32 indexed orgId, address indexed org, uint256 amount);

    /// @param _asset   the donated asset (USDC)
    /// @param _factory Endaoment OrgFundFactory
    /// @param _vault   the prize vault (rotation source)
    constructor(IERC20 _asset, IEndaomentOrgFundFactory _factory, ICharityRotationSource _vault) {
        asset = _asset;
        endaomentFactory = _factory;
        vault = _vault;
    }

    /// @notice The Org id the next `forward()` will donate to — the charity for the most
    ///         recently completed draw (the entry just behind the vault's current pointer).
    function targetOrgId() public view returns (bytes32) {
        uint256 len = vault.charityRotationLength();
        if (len == 0) return bytes32(0);
        return vault.charityRotation((vault.charityIndex() + len - 1) % len);
    }

    /// @notice The pending balance waiting to be forwarded to the current charity.
    function pending() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Donate the FULL held balance to the current charity. Permissionless — any
    ///         keeper (or anyone) may call it. Runs in its own transaction with a full
    ///         block's gas, so the Endaoment interaction can never brick a draw. Checks
    ///         whether the Org already exists and donates directly if so, avoiding the
    ///         failing CREATE2 entirely.
    /// @return org    the Endaoment Org address that received the donation
    /// @return amount the amount donated (Endaoment skims its fee from this)
    function forward() external nonReentrant returns (address org, uint256 amount) {
        uint256 len = vault.charityRotationLength();
        if (len == 0) revert EmptyRotation();
        amount = asset.balanceOf(address(this));
        if (amount == 0) revert NothingToForward();

        bytes32 orgId = vault.charityRotation((vault.charityIndex() + len - 1) % len);
        org = endaomentFactory.computeOrgAddress(orgId);

        if (org.code.length == 0) {
            // Org not yet deployed: factory deploys the clone and pulls the donation.
            asset.forceApprove(address(endaomentFactory), amount);
            endaomentFactory.deployOrgAndDonate(orgId, amount);
            asset.forceApprove(address(endaomentFactory), 0);
        } else {
            // Org already deployed: it pulls the donation directly. No CREATE2, no brick.
            asset.forceApprove(org, amount);
            IEndaomentEntity(org).donate(amount);
            asset.forceApprove(org, 0);
        }

        emit CharityForwarded(orgId, org, amount);
    }
}
