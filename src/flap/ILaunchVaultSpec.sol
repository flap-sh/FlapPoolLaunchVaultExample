// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultUISchema, VaultDataSchema, FactoryPolicy} from "src/flap/IVaultSchemas.sol";

/// @title IDirectLaunchVault
/// @author The Flap Team
/// @notice The ONLY mandatory vault surface in a Pool Launch vault.
/// @dev A vault that also receives the launch's dev-reserved remainder additionally implements
///      `IStrategy.initializeDistribution`, because the DLP calls it. Nothing else is required.
interface IDirectLaunchVault {
    /// @notice Dynamic, human-readable status of the vault.
    /// @dev MUST disclose fees/commission and every party that receives revenue or reserved tokens.
    function description() external view returns (string memory);

    /// @notice On-chain UI description of the vault's user-facing methods (`IVaultSchemas`, unchanged
    ///         from the bonding-curve spec).
    function vaultUISchema() external pure returns (VaultUISchema memory);
}

/// @title IDirectLaunchVaultFactory
/// @author The Flap Team
/// @notice Pool Launch vault factory interface.
/// @dev `newVault` receives the FULL launch input (create params + Distribution), so it creates the vault
///      AND validates the launch in one call. There is no separate `validateLaunch`.
interface IDirectLaunchVaultFactory {
    /// @notice Validate the launch and create its vault. Called by the DLP in the create step.
    /// @param token        The launch token's PREDICTED address (not deployed yet).
    /// @param creator      The launch caller.
    /// @param launchKind   `IPortalTypes.LaunchKind` as `uint8`.
    /// @param launchParams `abi.encode(<create params of that kind>, Distribution)`.
    /// @return vault       The vault that is placed in the launch's VAULT fee slot.
    function newVault(address token, address creator, uint8 launchKind, bytes calldata launchParams)
        external
        returns (address vault);

    /// @notice Whether this factory's vault supports `quoteToken` (`address(0)` = native). For UIs.
    function isQuoteTokenSupported(address quoteToken) external view returns (bool);

    /// @notice The only spec version getter: `"pl-v1"`.
    function factorySpecVersion() external pure returns (string memory);

    /// @notice Schema of this factory's `FeeConfigVault.vaultData`, for UI form generation.
    function vaultDataSchema() external pure returns (VaultDataSchema memory);

    /// @notice UI hints that mirror the checks in `newVault`. Informational only.
    function tokenCreationPolicies() external view returns (FactoryPolicy[] memory);

    /// @notice Upgrade the implementation of every vault this factory has deployed.
    /// @dev For the low-risk badge this MUST be callable by the Guardian only.
    function upgradeVaultImplementation(address newImplementation) external;
}

/// @title ITokenDock
/// @author The Flap Team
/// @notice Shared custody for reserved tokens. Same interface for both singletons.
interface ITokenDock {
    /// @notice Credit `amount` of `token` to `msg.sender`'s balance. Pulls via `transferFrom` and checks
    ///         the balance delta. VerifiedTokenDock reverts unless `isWhitelisted(msg.sender, token)`.
    function deposit(address token, uint256 amount) external;

    /// @notice Debit `msg.sender`'s balance and send to `to`. NEVER gated.
    function withdraw(address token, uint256 amount, address to) external;

    /// @notice `owner`'s stored balance of `token`.
    function balanceOf(address token, address owner) external view returns (uint256);

    /// @notice Total of `token` held for all owners.
    function totalReserved(address token) external view returns (uint256);

    /// @notice Whether `vault` may deposit `token`. Verified: pair whitelist. Open: always true.
    function isWhitelisted(address vault, address token) external view returns (bool);

    event FlapTokenDockDeposited(address token, address owner, uint256 amount);
    event FlapTokenDockWithdrawn(address token, address owner, address to, uint256 amount);
}

/// @title ITokenDockCustody
/// @notice Trusted, owner-scoped custody surface on a dock, callable only by the `TokenDockRouter` so
///         it can deposit/withdraw and migrate a vault's balance on its behalf. Not part of the vault
///         API — a vault only ever talks to `TokenDockRouter`.
interface ITokenDockCustody {
    /// @notice Credit `amount` of `token` to `owner`. Pulls via `transferFrom` from the caller (the
    ///         router) and checks the balance delta.
    function depositFor(address owner, address token, uint256 amount) external;

    /// @notice Debit `owner`'s balance and send `amount` of `token` to `to`. Never gated.
    function withdrawFor(address owner, address token, uint256 amount, address to) external;
}

/// @title IVerifiedTokenDock
/// @notice Extra surface on the labeled store only.
interface ITokenDockRouter is ITokenDock {
    /// @notice Which dock deposit/withdraw would use for `(vault, token)` right now.
    function dockFor(address vault, address token) external view returns (address);

    /// @notice Move an already-whitelisted vault's reserve from the open dock to the verified dock.
    function migrate(address vault, address token) external;

    /// @notice Whether `token` was already registered as a Direct-launch token by the Portal.
    function isFlapToken(address token) external view returns (bool);
}

interface IVerifiedTokenDock is ITokenDock {
    /// @notice Whitelist the `(vault, token)` pair. Callable ONLY by the Direct Launch Portal.
    function addToWhitelist(address vault, address token) external;

    event FlapTokenDockWhitelisted(address vault, address token);
}

/// @title IVaultFactoryDividend
/// @notice Optional vault-factory extension: compute the launch's dividend asset.
/// @dev Invoked only when `FeeConfigDividend.dividendToken == MAGIC_DIVIDEND_COMPUTED` and the launch
///      carries a VAULT slot. Factories that do not implement it are rejected.
interface IVaultFactoryDividend {
    function resolveDividendToken(address predictedToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        view
        returns (address dividendToken);
}
