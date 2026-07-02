// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal subset of Endaoment's OrgFundFactory (endaoment-contracts-v2).
///         Endaoment is an on-chain 501(c)(3) community foundation: a donation to an
///         Org entity (identified by its IRS EIN, encoded into bytes32) is a tax-
///         deductible grant that Endaoment disburses to that nonprofit in USD/USDC —
///         so the charity itself never needs a crypto wallet or a Base address.
///
/// @dev    `deployOrgAndDonate` deploys the Org clone if it does not yet exist and
///         then donates; it REVERTS if the Org is already deployed. `computeOrgAddress`
///         returns the deterministic clone address so an already-deployed Org can be
///         donated to directly via `IEndaomentEntity.donate`. Both donation paths pull
///         `_amount` of the base token (USDC) from `msg.sender`, so the caller must have
///         approved the puller (the factory for deployOrgAndDonate, the Org for donate).
interface IEndaomentOrgFundFactory {
    function deployOrgAndDonate(bytes32 _orgId, uint256 _amount) external returns (address);

    function computeOrgAddress(bytes32 _orgId) external view returns (address);
}

/// @notice Minimal subset of an Endaoment Entity (Org). `donate` charges Endaoment's
///         protocol fee out of the donated amount and credits the remainder to the Org's
///         grantable balance.
interface IEndaomentEntity {
    function donate(uint256 _amount) external;
}
