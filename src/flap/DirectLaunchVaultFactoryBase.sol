// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {IPortalTypes} from "src/flap/IPortal.sol";

import {IDirectLaunchVaultFactory} from "src/flap/ILaunchVaultSpec.sol";
import {Distribution, DistributionTarget} from "src/flap/Distribution.sol";
import {VaultDataSchema, FactoryPolicy} from "src/flap/IVaultSchemas.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";

/// @title DirectLaunchVaultFactoryBase
/// @author The Flap Team
/// @notice Recommended (not mandatory) abstract base for Pool Launch vault factories.
///
///         It provides ONLY the caller checks and the per-chain addresses every factory needs in
///         exactly the same way:
///         - `onlyHub`:      the caller is the Direct Launch Portal (Hub) of this chain;
///         - `onlyGuardian`: the caller is the Flap Guardian of this chain;
///         - the two per-chain getters behind them (`internal view virtual`).
///
///         Every `IDirectLaunchVaultFactory` method is left abstract. The base enforces no implementation
///         convention: how a vault is deployed, initialized, validated or upgraded is the factory's
///         own design. The natspec on each method states what the Hub, the UI and the low-risk audit
///         expect. `SplitVaultFactory` / `StakeMineVaultFactory` are worked examples.
///
/// @dev  ── WHAT A LAUNCHER VAULT FACTORY IS ─────────────────────────────────
///
/// The Hub's create facets resolve a launch's `FeeSlotType.VAULT` slot by calling
/// `IDirectLaunchVaultFactory(vaultFactory).newVault(predictedToken, creator, uint8(kind), launchParams)` — see
/// `PortalLauncherBase._parseAndValidateFeeConfigs`. `launchParams` is
/// `abi.encode(<that kind's create params>, Distribution)`: the factory reads the RAW `p.quoteToken`
/// (`address(0)` = native, no WBNB normalization) and its own VAULT-slot `vaultData` from it. The
/// returned vault address is the recipient of the VAULT fee slot (VAULT and MARKETING are mutually
/// exclusive) and receives that slot's bps share of the token's quote revenue from then on. No on-chain
/// registration is needed to deploy a factory, but during the beta a launch only goes through a Launcher
/// whose LauncherFactory Flap has audited and enabled.
///
/// `newVault` runs BEFORE the token is deployed (`predictedToken` is a CREATE2 prediction), so a
/// factory can revert or return a bogus address but cannot re-enter the Hub: the token is not cloned
/// yet and no launch state has been written. Gate `newVault` with `onlyHub` to stop a third party
/// pre-creating a deterministic clone (a squat that would make the real launch revert on the CREATE2
/// collision) — see `SplitVaultFactory` for the reference.
///
///
/// ── HOW TO IMPLEMENT ───────────────────────────────────────────────────────
///
/// 1. Inherit `DirectLaunchVaultFactoryBase`.
/// 2. Implement `newVault(...)` and gate it with `onlyHub`: validate the launch, deploy (or clone)
///    your vault, initialize it with `p.quoteToken` (raw; `address(0)` = native), and return a
///    non-zero address with code. Never call `token` (it has no code yet).
/// 3. Implement `isQuoteTokenSupported(quoteToken)` truthfully. Misdeclaring support strands users'
///    tax revenue in a vault that ignores it.
/// 4. Implement `vaultDataSchema()` / `factorySpecVersion()` / `tokenCreationPolicies()`.
///
/// NOTE ON UPGRADEABILITY: per Flap verification conventions a FACTORY should be immutable — to change
/// one, deploy a new factory and register it. The VAULTS it deploys SHOULD be upgradeable via a
/// solady `UpgradeableBeacon` + `LibClone.deployDeterministicERC1967BeaconProxy` (the launcher's own
/// per-token pattern — see `PortalBase.dividendBeacon` / `PortalDirectLauncherCreate._setupDividend`),
/// so one beacon upgrade retargets the logic of every already-launched vault at once. Give the vault
/// implementation a `version()` marker and bump it on each beacon upgrade (mirrors `Dividend.version`).
/// `StakeMineVaultFactory` is a complete worked example. This base itself is deliberately storage-free.
abstract contract DirectLaunchVaultFactoryBase is IDirectLaunchVaultFactory {
    /// @notice The caller is not the Direct Launch Portal (Hub) of this chain.
    error NotHub(address caller);
    /// @notice The caller is not the Guardian of this chain.
    error NotGuardian(address caller);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Restrict a function to the Direct Launch Portal (Hub) of this chain.
    /// @dev Put it on `newVault`. Without it, anyone could deploy a vault at a deterministic address
    ///      before the launch and make the real launch revert on the address collision.
    modifier onlyHub() {
        if (msg.sender != _getHub()) revert NotHub(msg.sender);
        _;
    }

    /// @notice Restrict a function to the Flap Guardian of this chain.
    /// @dev Put it on the upgrade path. For the low-risk badge the Guardian MUST be the only upgrade
    ///      authority.
    modifier onlyGuardian() {
        if (msg.sender != _getGuardian()) revert NotGuardian(msg.sender);
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Chain addresses
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The Direct Launch Portal (Hub) of this chain (see `LaunchVaultAddresses`). `virtual`.
    function _getHub() internal view virtual returns (address) {
        return LaunchVaultAddresses.hub();
    }

    /// @notice The Flap Guardian of this chain (see `LaunchVaultAddresses`). `virtual`.
    function _getGuardian() internal view virtual returns (address) {
        return LaunchVaultAddresses.guardian();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IDirectLaunchVaultFactory: all abstract
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Validate the launch and create its vault, in one call. Called by the Hub during the
    ///         create step, before the token is deployed.
    /// @dev `launchParams` by `launchKind` (`IPortalTypes.LaunchKind`):
    ///      | kind                   | launchParams                                                     |
    ///      |------------------------|------------------------------------------------------------------|
    ///      | DIRECT_V2_POOL_TAX (0) | abi.encode(IPortalTypes.CreateTaxTokenParams, Distribution) |
    ///      The params are the RAW launch input: `p.quoteToken == address(0)` means native (no WBNB
    ///      normalization). The factory's own `vaultData` is in `p.feeConfigs`: the VAULT slot whose
    ///      `FeeConfigVault.vaultFactory == address(this)`.
    ///
    ///      MUST: gate the caller with `onlyHub`; validate the launch (the reserved share, who the
    ///      strategy is, and any other rule its economics need) BEFORE deploying; revert with a clear
    ///      reason unless the launch is acceptable; initialize the vault in this same call and return
    ///      a non-zero address with code; NEVER call `token` (it has no code yet). SHOULD deploy
    ///      deterministically from `token` (one vault per token) behind an upgradeable proxy.
    /// @param token        The launch token's predicted address.
    /// @param creator      The launch caller (`msg.sender` of the launch).
    /// @param launchKind   `IPortalTypes.LaunchKind` as `uint8`.
    /// @param launchParams `abi.encode(<create params of that kind>, Distribution)`.
    /// @return vault       The vault, placed in the launch's VAULT fee slot.
    function newVault(address token, address creator, uint8 launchKind, bytes calldata launchParams)
        external
        virtual
        override
        returns (address vault);

    /// @notice Whether this factory's vault can account for revenue in `quoteToken`.
    /// @dev For UIs (to grey out unsupported quotes). MUST be truthful and consistent with `newVault`,
    ///      which MUST revert for a quote this returns false for.
    /// @param quoteToken Raw quote (`address(0)` = native).
    /// @return Whether the quote is supported.
    function isQuoteTokenSupported(address quoteToken) public view virtual override returns (bool);

    /// @notice Schema describing the `vaultData` bytes `newVault` expects, for UI form generation.
    /// @dev Field order and types MUST match how `newVault` decodes `vaultData`.
    /// @return The schema (`IVaultSchemas.VaultDataSchema`).
    function vaultDataSchema() public pure virtual override returns (VaultDataSchema memory);

    /// @notice The factory-side spec revision this implementation conforms to. Distinct from the
    ///         vault-side `StakeMineVault.version()`. MUST return `"pl-v1"`.
    /// @return The version string.
    function factorySpecVersion() public pure virtual override returns (string memory) {
        return "pl-v1";
    }

    /// @notice Informational constraints this factory places on launch parameters, for proactive UI
    ///         hints. Informational only; `newVault` enforces. Keep the two consistent.
    /// @return The policies (empty if none).
    function tokenCreationPolicies() public view virtual override returns (FactoryPolicy[] memory);

    /// @notice Upgrade the implementation of every vault this factory has deployed.
    /// @dev For the low-risk badge this MUST be callable by the Guardian only: use `onlyGuardian`, and
    ///      leave no other upgrade path (no owner, proxy admin, upgrader role or deployer EOA). A
    ///      factory that wants no upgrades at all may revert unconditionally.
    /// @param newImplementation The new vault implementation.
    function upgradeVaultImplementation(address newImplementation) external virtual override;

    // ─────────────────────────────────────────────────────────────────────────
    // Strict launch validation (call from newVault before deploying anything)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `token` or `creator` passed to `newVault` was the zero address.
    error ZeroAddress();
    /// @notice The launch has no VAULT slot naming this factory.
    error MissingVaultSlot(address factory);
    /// @notice The launch has more than one VAULT slot naming this factory.
    error DuplicateVaultSlot(address factory);
    /// @notice The VAULT slot naming this factory carries a zero bps share.
    error ZeroVaultSlotBps();
    /// @notice The launch's quote token is not supported by this factory (`isQuoteTokenSupported`).
    error UnsupportedQuoteToken(address quoteToken);
    /// @notice `Distribution.target` is not the one this factory's vault can serve.
    error UnexpectedDistributionTarget(DistributionTarget got, DistributionTarget expected);
    /// @notice `Distribution.amount` must be zero because this vault does not receive reserved tokens.
    error UnexpectedDistributionAmount(uint256 got);
    /// @notice `vaultData` is not the exact size/shape this factory decodes.
    error InvalidVaultData();

    /// @dev Checks every launch input that does not depend on a particular vault, and returns the decoded
    ///      launch plus this factory's own `vaultData`. Reverts with a specific error for each rule so a
    ///      wrong input is rejected before anything is deployed and the cause is obvious:
    ///        - `token` and `creator` are non-zero;
    ///        - exactly ONE VAULT slot names this factory (zero -> MissingVaultSlot, two -> DuplicateVaultSlot),
    ///          and that slot's bps is non-zero;
    ///        - the raw `p.quoteToken` passes `isQuoteTokenSupported`.
    ///      The caller (`onlyHub`) runs its own vault-specific rules afterwards.
    function _validateLaunch(address token, address creator, uint8 launchKind, bytes calldata launchParams)
        internal
        view
        returns (IPortalTypes.CreateTaxTokenParams memory p, Distribution memory d, bytes memory vaultData)
    {
        if (token == address(0) || creator == address(0)) revert ZeroAddress();
        (p, d) = _decodeLaunchParams(launchKind, launchParams);

        uint16 slotBps;
        bool found;
        for (uint256 i = 0; i < p.feeConfigs.length; ++i) {
            if (p.feeConfigs[i].feeType != IPortalTypes.FeeSlotType.VAULT) continue;
            IPortalTypes.FeeConfigVault memory v = abi.decode(p.feeConfigs[i].configData, (IPortalTypes.FeeConfigVault));
            if (v.vaultFactory != address(this)) continue;
            if (found) revert DuplicateVaultSlot(address(this));
            found = true;
            slotBps = p.feeConfigs[i].bps;
            vaultData = v.vaultData;
        }
        if (!found) revert MissingVaultSlot(address(this));
        if (slotBps == 0) revert ZeroVaultSlotBps();
        if (!isQuoteTokenSupported(p.quoteToken)) revert UnsupportedQuoteToken(p.quoteToken);
    }

    /// @dev For vaults that do NOT receive the launch's reserved tokens: the Distribution must be unused
    ///      or addressed elsewhere. `target == VAULT` would make the Portal hand the remainder to a vault
    ///      that has no `initializeDistribution`, so it is rejected, and a stray `amount` is rejected so
    ///      nothing is silently left unrouted.
    function _requireNoReserveDistribution(Distribution memory d) internal pure {
        if (d.target == DistributionTarget.VAULT) {
            revert UnexpectedDistributionTarget(d.target, DistributionTarget.NONE);
        }
        if (d.target == DistributionTarget.NONE && d.amount != 0) revert UnexpectedDistributionAmount(d.amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Decode helpers (optional convenience)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Thrown by `_vaultDataFor` when the launch's feeConfigs carry no VAULT slot for this
    ///         factory.
    error VaultDataNotFound(address factory);

    /// @notice `newVault` was called with a `launchKind` this factory does not support.
    error UnsupportedLaunchKind(uint8 launchKind);

    /// @dev Decode the launch payload passed to `newVault`, keyed by `launchKind` so each kind decodes
    ///      its own params struct. Only `DIRECT_V2_POOL_TAX` is supported today; any other kind reverts
    ///      (`UnsupportedLaunchKind`) rather than being mis-decoded, so a future kind — with different
    ///      create params — is opt-in and never breaks this one.
    function _decodeLaunchParams(uint8 launchKind, bytes calldata launchParams)
        internal
        pure
        returns (IPortalTypes.CreateTaxTokenParams memory p, Distribution memory d)
    {
        if (launchKind != uint8(IPortalTypes.LaunchKind.DIRECT_V2_POOL_TAX)) {
            revert UnsupportedLaunchKind(launchKind);
        }
        return abi.decode(launchParams, (IPortalTypes.CreateTaxTokenParams, Distribution));
    }

    /// @dev Extract this factory's own VAULT-slot `vaultData` from the launch's feeConfigs.
    function _vaultDataFor(address factory, IPortalTypes.FeeConfig[] memory feeConfigs)
        internal
        pure
        returns (bytes memory vaultData)
    {
        for (uint256 i = 0; i < feeConfigs.length; ++i) {
            if (feeConfigs[i].feeType != IPortalTypes.FeeSlotType.VAULT) continue;
            IPortalTypes.FeeConfigVault memory v = abi.decode(feeConfigs[i].configData, (IPortalTypes.FeeConfigVault));
            if (v.vaultFactory == factory) return v.vaultData;
        }
        revert VaultDataNotFound(factory);
    }
}
