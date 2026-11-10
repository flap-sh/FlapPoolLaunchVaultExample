// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LauncherDataSchema} from "src/flap/IVaultSchemas.sol";

/// @notice Minimal on-Portal record for a created Launcher. Stored only in the Portal; the
///         Launcher contract owns every mechanism-specific field (creator, mint state, ...). The
///         floor multiplier is NOT snapshotted: it is read live from the factory's `FactoryConfig`.
struct LauncherRecord {
    address launcherFactory;
}

/// @title ILauncherFactory
/// @notice Interface an enabled LauncherFactory exposes to the Portal. `newLauncher` is called by
///         the Portal (which records the returned address); a factory must only accept calls from its
///         configured Portal. The floor multiplier lives in the Portal's `FactoryConfig`, not here.
interface ILauncherFactory {
    /// @notice Deploy a new Launcher (or mechanism/fundraising contract) for `creator`. `msg.value` is
    ///         forwarded by the Portal, so a factory can use it for deployment, salt locking, or
    ///         initial funding.
    /// @dev If the value is used to lock a launch salt, the lock MUST be executed by the Launcher
    ///      itself: `Portal.lockSalt` records `msg.sender` as the locker, and the Launcher's later
    ///      launch requires `locker == Launcher`. A lock executed by the factory records the factory
    ///      as locker and makes the Launcher's launch revert with FlapSaltLockedByAnotherUser.
    ///      The Launcher's own display data is not returned here: the Portal reads the optional
    ///      `ILauncherDescription.description()` from the deployed Launcher and folds it into
    ///      `FlapNewLauncherCreated`.
    /// @param creator The account that called `Portal.newLauncher`.
    /// @param data Mechanism-specific payload. Its layout and use are entirely up to the factory; the
    ///        Portal never decodes it. There is no required initializer function.
    /// @return launcher The deployed Launcher (must be a contract).
    function newLauncher(address creator, bytes calldata data) external payable returns (address launcher);

    /// @notice The factory-side spec revision this implementation conforms to. MUST return `"lf-v1"`
    ///         (launcher factory spec, v1).
    /// @return The version string.
    function factorySpecVersion() external pure returns (string memory);

    /// @notice Schema of the `data` bytes `newLauncher` expects, for UI form generation.
    function launcherDataSchema() external pure returns (LauncherDataSchema memory);

    /// @notice Upgrade the implementation every Launcher of this factory delegates to.
    /// @dev Guardian-only. Factories that deploy beacon proxies forward this to their
    ///      `UpgradeableBeacon`; factories with immutable Launchers revert.
    function upgradeVaultImplementation(address newImplementation) external;
}

/// @notice Optional display surface of a Launcher. Read by the Portal right after creation and folded
///         into `FlapNewLauncherCreated`; display-only, never used for gating, accounting or payments.
/// @dev Implemented by `LauncherBase`. A Launcher that does not implement it (or reverts, returns
///      malformed data, or exceeds the Portal's size limits) is still created; its description is "".
interface ILauncherDescription {
    /// @notice The v1 JSON description of this Launcher.
    /// @dev Format: the JSON object built by `LauncherHelper.toJson`: `v` plus `name`, `symbol`,
    ///      `quoteToken`, `targetRaise`, `poolTokenRatio`, `titleZh`, `titleEn`, `summaryZh`,
    ///      `summaryEn`, all strings except `v`. Return "" when there is nothing to show.
    /// @return The JSON object as a UTF-8 string.
    function description() external view returns (string memory);
}
