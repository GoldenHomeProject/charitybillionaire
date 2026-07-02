// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVRFProviderOwnable {
    function acceptOwnership() external;
    function setRequestConfig(uint16 requestConfirmations, uint32 callbackGasLimit) external;
}

/// @title VRFProviderOwner
/// @notice Immutable owner for ChainlinkVRFProvider that exists to REMOVE a power,
///         not add one. ChainlinkVRFProvider inherits Chainlink's
///         VRFConsumerBaseV2Plus, whose owner can call `setCoordinator(address)` —
///         and the randomness callback trusts whatever coordinator is set. An EOA
///         owner could therefore repoint the coordinator at itself and hand-pick the
///         winning random word, silently defeating the vault's verifiable-fairness
///         guarantee.
///
///         By transferring the provider's ownership to this contract, that attack is
///         closed permanently: this contract has NO function that calls
///         `setCoordinator`, so no human can ever repoint the coordinator. Chainlink's
///         own coordinator MIGRATION path is unaffected — the provider's
///         `onlyOwnerOrCoordinator` modifier still lets the active coordinator
///         migrate itself.
///
///         The only retained privilege is bounded gas-config tuning, gated to an
///         immutable `admin` (intended to be a company multisig). The provider itself
///         also clamps these values, so even a compromised admin cannot brick the
///         draw. This contract cannot transfer the provider's ownership onward, so
///         the lock is irreversible by design.
contract VRFProviderOwner {
    /// @notice The ChainlinkVRFProvider this contract owns.
    IVRFProviderOwnable public immutable provider;
    /// @notice The only address allowed to tune the provider's request config.
    address public immutable admin;

    event RequestConfigForwarded(uint16 requestConfirmations, uint32 callbackGasLimit);

    error OnlyAdmin();

    constructor(address _provider, address _admin) {
        provider = IVRFProviderOwnable(_provider);
        admin = _admin;
    }

    /// @notice Complete the two-step ownership transfer of the provider to this lock.
    ///         Call after `provider.transferOwnership(address(this))`. Permissionless:
    ///         it can only ever make THIS contract the owner, which is the goal.
    function acceptProviderOwnership() external {
        provider.acceptOwnership();
    }

    /// @notice Forward a bounded gas-config update to the provider. Admin-only. The
    ///         provider re-validates the bounds, so this is defense in depth, not the
    ///         sole guard.
    function setProviderRequestConfig(uint16 requestConfirmations, uint32 callbackGasLimit) external {
        if (msg.sender != admin) revert OnlyAdmin();
        provider.setRequestConfig(requestConfirmations, callbackGasLimit);
        emit RequestConfigForwarded(requestConfirmations, callbackGasLimit);
    }
}
