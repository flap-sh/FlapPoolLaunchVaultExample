// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ILauncherFactory} from "src/flap/ILauncher.sol";
import {LauncherDataSchema} from "src/flap/IVaultSchemas.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";

/// @title LauncherFactoryBase
/// @author The Flap Team
/// @notice Abstract base for Launcher factories. Flap only enables factories that inherit it.
///
///         A Launcher setup is two contracts: the Launcher (the mechanism: IDO, mint, presale, ...)
///         and this factory, which deploys it. The base fixes the Portal-facing surface so none of it
///         can be forgotten:
///         - `newLauncher(creator, data)` is `onlyHub` and delegates to `_newLauncher`;
///         - `factorySpecVersion()` returns `"lf-v1"`;
///         - `launcherDataSchema()` is abstract: it drives the creation form;
///         - `upgradeVaultImplementation()` is abstract and guardian-only (`onlyGuardian`);
///         - `_getHub()` / `_getGuardian()` resolve the Portal and the Flap Guardian per chain.
///         Deployment model, salt locking and funding stay the factory's own design. The base has no storage.
///
/// @dev  How it is called: the Portal runs
///       `factory.newLauncher{value: msg.value}(msg.sender, data)` from `PortalPoolLauncher.newLauncher`.
///       The caller is always the Portal, `creator` is the wallet that called the Portal, and `data` is
///       passed through undecoded, so its layout is the factory's public ABI.
///
///       The floor multiplier is not returned by the factory. Flap enables the factory and sets it on the
///       Portal with `setLauncherFactoryMultiplier(factory, multiplier, enabled)`; the Portal reads it live.
///
///       Salt: the Launcher, not the factory, must call `Portal.lockSalt`. The Portal records
///       `msg.sender` as the locker and the launch requires `locker == Launcher`; a lock taken by the
///       factory makes the launch revert with `FlapSaltLockedByAnotherUser`.
///
///       Upgrades: the factory itself is immutable; to change it, deploy a new one and have Flap enable it.
///       Launchers behind a beacon proxy can still be upgraded through `upgradeVaultImplementation`, which
///       only the Guardian may call. A factory with immutable Launchers reverts there.
///
///       Usage:
///         1. Inherit `LauncherFactoryBase`.
///         2. `_newLauncher`: decode `data`, deploy the Launcher, initialize it with the Portal address,
///            `creator` and the decoded config. `msg.value` is available to forward.
///         3. Implement `launcherDataSchema()` and `upgradeVaultImplementation()`.
abstract contract LauncherFactoryBase is ILauncherFactory {
    /// @notice The caller is not the Pool Launch Portal of this chain.
    error NotHub(address caller);
    /// @notice The caller is not the Flap Guardian of this chain.
    error NotGuardian(address caller);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Restrict a function to the Pool Launch Portal of this chain.
    /// @dev Already applied to `newLauncher` below. Use it on any other Portal-facing entry you add.
    modifier onlyHub() {
        if (msg.sender != _getHub()) revert NotHub(msg.sender);
        _;
    }

    /// @notice Restrict a function to the Flap Guardian of this chain.
    /// @dev Used by `upgradeVaultImplementation`. The guardian MUST be the only upgrade path.
    modifier onlyGuardian() {
        if (msg.sender != _getGuardian()) revert NotGuardian(msg.sender);
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Chain addresses
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The Pool Launch Portal of this chain (see `LaunchVaultAddresses`). `virtual`.
    function _getHub() internal view virtual returns (address) {
        return LaunchVaultAddresses.hub();
    }

    /// @notice The Flap Guardian of this chain (see `LaunchVaultAddresses`). `virtual`.
    function _getGuardian() internal view virtual returns (address) {
        return LaunchVaultAddresses.guardian();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ILauncherFactory
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The factory-side spec revision this implementation conforms to. MUST return `"lf-v1"`.
    /// @return The version string.
    function factorySpecVersion() external pure virtual override returns (string memory) {
        return "lf-v1";
    }

    /// @inheritdoc ILauncherFactory
    /// @dev Portal-only: `onlyHub` cannot be bypassed by a subclass.
    function newLauncher(address creator, bytes calldata data)
        external
        payable
        override
        onlyHub
        returns (address launcher)
    {
        return _newLauncher(creator, data);
    }

    /// @inheritdoc ILauncherFactory
    function launcherDataSchema() external pure virtual override returns (LauncherDataSchema memory);

    /// @notice Upgrade the implementation every Launcher of this factory delegates to. Guardian-only.
    /// @dev Factories that deploy beacon proxies (the recommended pattern) forward this to their
    ///      `UpgradeableBeacon`. A factory that deploys immutable Launchers reverts.
    function upgradeVaultImplementation(address newImplementation) external virtual override;

    // ─────────────────────────────────────────────────────────────────────────
    // Factory-specific
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploy the Launcher for `creator`.
    /// @dev Called by `newLauncher` after the Hub check. `msg.value` is available as usual, so a factory
    ///      can fund or initialize the Launcher with it.
    ///
    ///      `data` is opaque to the Portal: it is forwarded unchanged and never decoded there. Decode it
    ///      here with your own layout. Keep the layout stable: it is the factory's public ABI.
    /// @param creator The wallet that called `Portal.newLauncher`.
    /// @param data Mechanism-specific payload from `Portal.newLauncher`; never decoded by the Portal.
    /// @return launcher The deployed Launcher (must be a contract).
    function _newLauncher(address creator, bytes calldata data) internal virtual returns (address launcher);
}
