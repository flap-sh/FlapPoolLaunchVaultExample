// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {IPortalTypes, IPortal} from "src/flap/IPortal.sol";

import {Distribution} from "src/flap/Distribution.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";
import {ILauncherDescription} from "src/flap/ILauncher.sol";
import {LauncherDescription, LauncherHelper} from "src/flap/LauncherHelper.sol";

/// @title LauncherBase
/// @author The Flap Team
/// @notice Abstract helper base for Launcher contracts. Optional, storage-free.
///
///         Provides:
///         - `_getHub()` / `_getGuardian()`: the Portal and the Flap Guardian this Launcher answers to;
///         - `onlyHub` / `onlyGuardian`: caller checks built on them;
///         - `_launchOnHub(...)`: a typed wrapper around `Portal.launchTaxTokenV2`;
///         - `description()`: the v1 JSON display string the Portal reads on creation (see
///           `ILauncherDescription`). Implement `_description()`.
///
///         It adds no storage and no initializer, so it forces no layout or deployment pattern (plain
///         contract, clone, or beacon proxy all work). The mechanism itself (deposits, mint, presale,
///         allowlist, pricing, claims) is yours; the Portal never reads it.
///
/// @dev  A Launcher is the contract users talk to BEFORE the DEX launch. When its own conditions are met
///       it calls `Portal.launchTaxTokenV2` from its own address. The Portal then:
///         - records which Launcher launched the token;
///         - applies the Launcher factory's floor multiplier, read live (see `setLauncherFactoryMultiplier`);
///         - lets this Launcher launch exactly once (`LauncherAlreadyLaunched` afterwards);
///         - lets it through the creation pause while its factory is enabled.
///       A Launcher is not an ERC20 and holds no launch logic: token, pool and vault come from the Portal.
///
///       Salt: locking is recommended. If used, `Portal.lockSalt` records `msg.sender` as the locker,
///       so the Launcher must call it itself. A lock taken by the factory makes the launch revert.
///
///       Usage:
///         1. Inherit `LauncherBase`.
///         2. Keep the Portal address in your own storage at initialization and return it from `_getHub()`.
///         3. Implement `_description()` with the values users should see next to the Launcher.
///         4. When the mechanism completes, call `_launchOnHub(p, distribution, creatorBuy)`.
abstract contract LauncherBase is ILauncherDescription {
    /// @notice The caller is not the Pool Launch Portal of this chain.
    error NotHub(address caller);
    /// @notice The caller is not the Flap Guardian of this chain.
    error NotGuardian(address caller);

    /// @notice Restrict a function to the Pool Launch Portal. Use it on Portal callbacks such as
    ///         `IStrategy.initializeDistribution`.
    modifier onlyHub() {
        if (msg.sender != _getHub()) revert NotHub(msg.sender);
        _;
    }

    /// @notice Restrict a function to the Flap Guardian. Typical use: an emergency or recovery path that
    ///         must stay reachable even if the creator key is lost.
    modifier onlyGuardian() {
        if (msg.sender != _getGuardian()) revert NotGuardian(msg.sender);
        _;
    }

    /// @inheritdoc ILauncherDescription
    function description() external view virtual override returns (string memory) {
        return LauncherHelper.toJson(_description());
    }

    /// @notice The display data `description()` renders. Display-only: the Portal never uses it for
    ///         gating, accounting or payments.
    function _description() internal view virtual returns (LauncherDescription memory);

    /// @notice The Pool Launch Portal this Launcher launches on.
    /// @dev Return a value stored at initialization. For a non-cloned deployment a constructor argument
    ///      works too.
    function _getHub() internal view virtual returns (address);

    /// @notice The Flap Guardian of this chain. Defaults to the chain registry; override in tests.
    function _getGuardian() internal view virtual returns (address) {
        return LaunchVaultAddresses.guardian();
    }

    /// @notice Launch through the Portal, forwarding this call's `msg.value` as the launch value.
    /// @dev Native quote: `msg.value` must equal `p.poolQuote + p.creatorBuyQuote` exactly. ERC-20 quote:
    ///      hold the quote and approve the Portal instead, then call the overload below with `value == 0`.
    function _launchOnHub(
        IPortalTypes.CreateTaxTokenParams calldata p,
        Distribution calldata distribution,
        IPortalTypes.CreatorBuyParams calldata creatorBuy
    ) internal returns (address token, address pool) {
        return _launchOnHub(p, distribution, creatorBuy, msg.value);
    }

    /// @notice Launch through the Portal with an explicit native value (`0` for an ERC-20 quote).
    function _launchOnHub(
        IPortalTypes.CreateTaxTokenParams calldata p,
        Distribution calldata distribution,
        IPortalTypes.CreatorBuyParams calldata creatorBuy,
        uint256 value
    ) internal returns (address token, address pool) {
        return IPortal(_getHub()).launchTaxTokenV2{value: value}(p, distribution, creatorBuy);
    }
}
