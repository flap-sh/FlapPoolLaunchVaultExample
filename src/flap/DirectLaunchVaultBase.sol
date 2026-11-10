// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultUISchema} from "src/flap/IVaultSchemas.sol";
import {IDirectLaunchVault} from "src/flap/ILaunchVaultSpec.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";

/// @title DirectLaunchVaultBase
/// @author The Flap Team
/// @notice Recommended (not mandatory) abstract helper base for Pool Launch vaults.
///
///         It provides ONLY:
///         - `onlyHub` and `onlyGuardian` modifiers (per-chain addresses);
///         - the Token Dock entry `_getTokenDockRouter()`, behind which routing (verified/open) and
///           migration live — a vault just calls `deposit` / `withdraw` / `balanceOf` on it.
///         The two mandatory `IDirectLaunchVault` methods, `description()` and `vaultUISchema()`, are
///         left abstract.
///
///         It has NO storage and no initializer, so it imposes no storage layout or deployment
///         pattern. Everything else (launch context, revenue accounting, payouts, distribution,
///         upgrade hygiene) is the vault's own design.
///
/// @dev ── TOKEN DOCK RULES ─────────────────────────────────────────────────────────────────────
///
///   - Never cache the dock address. Every deposit and withdrawal of `token` MUST call
///     `_getTokenDockRouter()` and use it. `TokenDockRouter` selects the labeled `VerifiedTokenDock`
///     once the DLP has whitelisted `(this, token)`, and the unlabeled `OpenTokenDock` before that —
///     and it moves this vault's balance across the first time it changes, so the vault never sees the
///     switch.
///   - Do not move a reserve into a dock until both docks are excluded from the token's dividends;
///     until then keep the reserve in the vault (the DLP excludes the vault).
///   - Until the docks are deployed, `LaunchVaultAddresses.tokenDockRouter()` returns `address(0)` and
///     `_getTokenDockRouter()` reverts `TokenDockNotConfigured()`.
abstract contract DirectLaunchVaultBase is IDirectLaunchVault {
    /// @notice The caller is not the Direct Launch Portal of this chain.
    error NotHub(address caller);
    /// @notice The caller is not the Guardian of this chain.
    error NotGuardian(address caller);
    /// @notice The Token Dock entry is not configured on this chain yet.
    error TokenDockNotConfigured();

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Restrict a function to the Direct Launch Portal of this chain.
    /// @dev Put it on `IStrategy.initializeDistribution` if the vault receives the remainder.
    modifier onlyHub() {
        if (msg.sender != _getHub()) revert NotHub(msg.sender);
        _;
    }

    /// @notice Restrict a function to the Flap Guardian of this chain.
    /// @dev For the low-risk badge, every permissioned vault function MUST also accept the Guardian,
    ///      e.g. `if (msg.sender != creator && msg.sender != _getGuardian()) revert`.
    modifier onlyGuardian() {
        if (msg.sender != _getGuardian()) revert NotGuardian(msg.sender);
        _;
    }

    /// @notice The Direct Launch Portal of this chain. NOT the Bonding Curve Portal.
    /// @dev `virtual` for tests and forks with a freshly deployed DLP.
    function _getHub() internal view virtual returns (address) {
        return LaunchVaultAddresses.hub();
    }

    /// @notice The Flap Guardian of this chain (same as the bonding-curve vault Guardian).
    /// @dev `virtual` for tests.
    function _getGuardian() internal view virtual returns (address) {
        return LaunchVaultAddresses.guardian();
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Token Dock entry
    // ────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The `TokenDockRouter` entry this vault uses for every reserve deposit / withdrawal. It
    ///         routes to the verified/open dock and migrates this vault's balance across on
    ///         whitelisting, so the vault does not implement any of that.
    /// @dev `virtual` for tests and forks with a freshly deployed `TokenDockRouter`.
    function _getTokenDockRouter() internal view virtual returns (address dock) {
        dock = LaunchVaultAddresses.tokenDockRouter();
        if (dock == address(0)) revert TokenDockNotConfigured();
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // IDirectLaunchVault: abstract
    // ────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Dynamic, human-readable status of the vault, shown by terminals and the vault UI.
    /// @dev MUST disclose fees/commission and every party that receives revenue or reserved tokens,
    ///      with current figures where useful (e.g. "Creator recouped 3.2 / 25 BNB; then 100% to
    ///      holders"). It may read state; keep it cheap enough for an `eth_call`.
    function description() public view virtual override returns (string memory);

    /// @notice On-chain description of the vault's user-facing methods, so a generic UI can render
    ///         them (`IVaultSchemas.VaultUISchema`, unchanged from the bonding-curve spec).
    /// @dev List every method a user or keeper is expected to call, with its inputs and any ERC20
    ///      approvals it needs.
    function vaultUISchema() public pure virtual override returns (VaultUISchema memory);
}
