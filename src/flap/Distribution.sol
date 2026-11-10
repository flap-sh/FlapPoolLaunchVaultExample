// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Selects where a launch's dev-reserved token remainder goes.
///           NONE     - no distribution (the remainder policy still runs; `amount` must be 0).
///           EXPLICIT - use `Distribution.strategy` as-is (caller-named IStrategy, non-zero).
///           VAULT    - route to THIS launch's provenance vault (PortalBase._getLaunchVault); the
///                      `strategy` field is ignored and overwritten with the resolved vault.
enum DistributionTarget {
    NONE,
    EXPLICIT,
    VAULT
}

/// @title Distribution
/// @notice Represents one distribution instruction: which target/strategy to use, how many tokens, and any custom data
/// @dev Named struct literals may list the fields in any order (all fields are required).
struct Distribution {
    DistributionTarget target;
    address strategy;
    uint128 amount;
    bytes configData;
}
