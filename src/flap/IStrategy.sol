// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title IStrategy
/// @notice Interface for token distribution strategies, invoked by PortalDistribute.distributeToken.
/// @dev A strategy is a standalone, pluggable contract; new distribution mechanisms (Migrator,
///      Airdrop, Vault, ...) are new IStrategy implementations, not new Portal branches.
interface IStrategy {
    /// @notice Emitted when a distribution is initialized.
    /// @dev Emitted BY the strategy, so the log's emitter address identifies it — no `distributor` field.
    /// @param token The token being distributed.
    /// @param amount The amount of `token` handed to this distribution.
    event FlapDistributionInitialized(address token, uint256 amount);

    /// @notice Initialize a distribution of tokens under this strategy.
    /// @dev The strategy is responsible for pulling `amount` of `token` from `msg.sender`
    ///      (Portal has already approved the strategy for exactly `amount` — see
    ///      PortalDistribute.distributeToken). Implementations that deploy or predict deterministic
    ///      distributors MUST fold `salt` into the address derivation so callers can domain-separate
    ///      otherwise-identical distributions.
    /// @param token The token being distributed.
    /// @param amount The amount of `token` to distribute.
    /// @param configData Arbitrary, strategy-specific parameters.
    /// @param salt Domain separator, opaque to Portal.
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt) external;
}
