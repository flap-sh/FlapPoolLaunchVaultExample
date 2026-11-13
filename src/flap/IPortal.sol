// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Distribution} from "src/flap/Distribution.sol";
import {LauncherRecord} from "src/flap/ILauncher.sol";

/// @dev `FeeConfigDividend.dividendToken` sentinel: distribute the launched token itself.
address constant MAGIC_DIVIDEND_SELF = 0xfEEDFEEDfeEDFEedFEEdFEEDFeEdfEEdFeEdFEEd;

/// @dev `FeeConfigDividend.dividendToken` sentinel: ask the launch's vault factory to compute it.
address constant MAGIC_DIVIDEND_COMPUTED = 0xC0Dec0dec0DeC0Dec0dEc0DEC0DEC0DEC0DEC0dE;

/// @title IPortalTypes (Pool Launch vault and launcher subset)
/// @notice The part of the Direct Launch Portal's `IPortalTypes` that Vaults and Launchers reference.
///         Each definition below is copied verbatim from the Portal, so ABI encoding matches the deployed
///         contract. Admin, swap and lens types are left out on purpose.
/// @dev Append-only on the Portal side. Do not reorder.
interface IPortalTypes {
    /// @dev The launch KIND of a Direct-launched token. Only DIRECT_V2_POOL_TAX exists (V3SS / non-tax V2
    ///      were removed). Per-kind parameters live in LaunchState.kindData (decoded by this enum), NOT in
    ///      new struct fields.
    enum LaunchKind {
        DIRECT_V2_POOL_TAX // 0: plain direct-to-DEX, TAX token (TOKEN_DIRECT_TAXED) — seeded straight into a
        // V2 pool, LP burned to dead. Its own (kind,quote) registry entry supplies the graduation floor via
        // LaunchQuoteConfig.quotePriceUsd — quote token USD price (18-dec WAD).
    }

    /// @notice One entry of a launch's generic extension payload (see LaunchExtensions).
    struct Extension {
        bytes32 extensionId;
        bytes extensionData;
    }

    /// @notice Fee-slot type for FeeConfig.configData. Mirrors the legacy FeeType axis but is its
    ///         own append-only enum: Direct's fee config no longer shares a layout with the legacy V7
    ///         curve-launch FeeConfig[4], so it does not need to stay numerically aligned with FeeType.
    ///           NONE                → configData ignored (empty slot)
    ///           DEFLATION           → configData empty (burn to DEAD; no parameters)
    ///           LP_BPS              → configData empty (added to LP; no parameters)
    ///           MARKETING           → configData = abi.encode(FeeConfigMarket)
    ///           VAULT               → configData = abi.encode(FeeConfigVault)
    ///           DIVIDEND            → configData = abi.encode(FeeConfigDividend)
    enum FeeSlotType {
        NONE,
        DEFLATION,
        LP_BPS,
        MARKETING,
        VAULT,
        DIVIDEND
    }

    /// @notice One fee slot: a type tag, its bps share, and an opaque blob decoded by `feeType`.
    /// @dev Adding a new fee type never changes this struct — only
    ///      FeeSlotType gains a value and a new
    ///      FeeConfigXxx decode target is defined. All non-NONE slots' bps MUST sum to exactly 10000
    ///      (enforced by PortalLauncherBase._parseAndValidateFeeConfigsV2, mirroring the V7 parser).
    struct FeeConfig {
        FeeSlotType feeType;
        uint16 bps;
        bytes configData;
    }

    /// @notice FeeConfig.configData payload for FeeSlotType.MARKETING.
    struct FeeConfigMarket {
        address marketingAddress;
    }

    /// @notice FeeConfig.configData payload for FeeSlotType.VAULT.
    struct FeeConfigVault {
        address vaultFactory;
        bytes vaultData;
    }

    /// @notice FeeConfig.configData payload for FeeSlotType.DIVIDEND.
    /// @dev `dividendToken`: 0 = quote, MAGIC_DIVIDEND_SELF = launched token,
    ///      MAGIC_DIVIDEND_COMPUTED = ask the launch's vault factory (requires a VAULT slot),
    ///      otherwise a concrete ERC-20. A non-quote asset is allowed for this release only when the
    ///      DIVIDEND slot has bps == 0 (tracker-only metadata); with bps > 0 it must be the quote
    ///      token unless NON_QUOTE_DIVIDEND_ENABLED is turned on.
    ///      `minimumShareBalance` is validated whenever a DIVIDEND slot is supplied (including bps == 0
    ///      tracker-only mode); it MUST be within [0.001%, 0.1%] of this launch's own totalSupply
    ///      (totalSupply * MIN_SHARE_BALANCE_PPM / 1_000_000 .. totalSupply * MAX_SHARE_BALANCE_PPM /
    ///      1_000_000 — see PortalLauncherBase constants).
    struct FeeConfigDividend {
        address dividendToken;
        uint256 minimumShareBalance;
    }

    /// @notice Parameters for createTaxToken.
    /// @dev `poolQuote`/`poolToken` are required HERE (not deferred to addV2Liquidity) so createTaxToken
    ///      can stash them in LaunchState.kindData and addV2Liquidity can cross-check that the pool it
    ///      actually seeds matches what was committed to at create time (see
    ///      PortalDirectLauncherLiquidity.addV2Liquidity). No funds are pulled here.
    struct CreateTaxTokenParams {
        string name;
        string symbol;
        string meta;
        uint256 totalSupply; // [MIN_SUPPLY, MAX_SUPPLY], 18 decimals
        bytes32 salt; // vanity address (reuses salt-lock)
        address quoteToken; // address(0) = native; pool identity is baked into the tax token at initialize()
        uint8 dexId; // which DEX provider (DEX0/1/2)
        uint256 poolQuote; // quote that WILL be injected at addV2Liquidity (> 0); committed here, checked there
        uint256 poolToken; // token that WILL be injected at addV2Liquidity (> 0 and <= totalSupply)
        uint16 buyTaxRate; // bps
        uint16 sellTaxRate; // bps
        uint32 taxDuration; // seconds; validated against protocol-wide bounds
        uint32 antiFarmerDuration; // seconds
        FeeConfig[] feeConfigs; // marketing + lp + optional single DIVIDEND slot; bps must sum to 10000
        uint8 antiSniperMode;
        // ---- temporary tax-exempt whitelist (exemptWindow == 0 or empty list = disabled) ----
        uint32 exemptWindow; // seconds after launch during which listed addresses pay no tax
        address[] exemptAddrs; // addresses granted the temporary tax exemption
        // ---- optional atomic creator first-buy signal ----
        // > 0 bakes antiSniperExempt = the resolved user into the token at initialize() (no post-init
        // setter exists). The ACTUAL swap is a separate, ordinary swapExactInput call later in the same
        // multicall — it pulls its own input funds from msg.sender independently; this field is a pure
        // boolean-ish signal, not funds pulled here.
        uint256 creatorBuyQuote;
        // ---- optional launch extensions (see LaunchExtensions.sol) ----
        // Two schemes, both parsed by LaunchExtensions.find:
        //   * single extension: extensionID names one extension, extensionData is its payload;
        //   * array: extensionID == EXTENSION_ARRAY_ID, extensionData = abi.encode(Extension[]), and
        //     the first matching entry wins.
        // Supported ids:
        //   * LaunchExtensions.CURVE_AUTH_EXTENSION_ID — signed quotePriceUsd fallback. Only consulted when the
        //     (kind, quoteToken) LaunchQuoteConfig is disabled; payload = (uint256 quotePriceUsd,
        //     uint256 deadline, bytes signature).
        //   * LaunchExtensions.CREATOR_EXTENSION_ID — declared creator for the FlapDirectLaunched event only. Payload =
        //     abi.encode(address creator). Honoured only for a Launcher recorded by Portal.newLauncher
        //     (or a contract Flap explicitly granted); vault resolution, the factory permission policy,
        //     the salt lock and payment all keep using msg.sender.
        // extensionID == 0: no extensions.
        bytes32 extensionID;
        bytes extensionData;
        // ---- optional commission ----
        // address(0) = disabled. When set, the commission bps is derived from the launch's effective tax
        // rate (max(buyTaxRate, sellTaxRate)) via PortalLauncherBase._commissionForTax and baked into the
        // token's TaxProcessorV2; the receiver is paid out of the protocol-fee remainder during dispatch.
        address commissionReceiver;
    }

    /// @notice Optional creator-first-buy swap knobs for the launch functions. The buy only executes when
    ///         the create params' `creatorBuyQuote > 0` (that field is already baked into the token's
    ///         antiSniperExempt at create time — see CreateTaxTokenParams.creatorBuyQuote); this struct
    ///         carries only the swap's OWN parameters, not the amount (== creatorBuyQuote) or direction
    ///         (implied: quoteToken/native -> the just-launched token), so it never duplicates a value
    ///         the caller already supplied elsewhere in the same call.
    struct CreatorBuyParams {
        uint256 minOutputAmount;
        bytes permitData;
    }
}

/// @title IPortal (Pool Launch vault and launcher subset)
/// @notice The Portal functions a Launcher or a launcher app calls, and the few Flap-only ones the fork tests use to
///         open a factory. A Vault never calls the Portal: the Portal calls the Vault factory's `newVault`, see
///         `IDirectLaunchVaultFactory`. Every declaration and comment below is copied from the Portal's own
///         interfaces.
interface IPortal {
    // ─────────────────────────────────────────────────────────────────────────
    // Launching
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The fee, in native currency, that `lockSalt` charges.
    function SALT_LOCK_FEE() external view returns (uint256);

    /// @notice Reserve a CREATE2 salt for a future Direct launch. Permissionless, payable. The caller becomes the
    ///         locker, so a Launcher must call it itself.
    function lockSalt(bytes32 salt, uint8 kind) external payable;

    /// @notice The one-call Direct launch entry. A Launcher calls this from its own address once its conditions are
    ///         met. `p.poolQuote`, `p.poolToken` and `p.creatorBuyQuote` all live on `p`. `distribution` routes the
    ///         dev-reserved remainder; a launch must either seed the whole supply into the pool or hand the
    ///         remainder off here. `creatorBuy` is the optional creator first-buy swap.
    function launchTaxTokenV2(
        IPortalTypes.CreateTaxTokenParams calldata p,
        Distribution calldata distribution,
        IPortalTypes.CreatorBuyParams calldata creatorBuy
    ) external payable returns (address token, address pool);

    // ─────────────────────────────────────────────────────────────────────────
    // Launchers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Create a Launcher through an enabled factory and record it on the Portal.
    /// @dev Payable: `msg.value` is forwarded to the factory (deployment / salt lock / initial funding).
    ///      Salt locking must be performed by the Launcher itself (Portal.lockSalt records msg.sender);
    ///      a factory-originated lock would block the Launcher's launch.
    /// @param launcherFactory The enabled LauncherFactory to call.
    /// @param data Mechanism-specific payload forwarded to the factory.
    /// @return launcher The created Launcher.
    function newLauncher(address launcherFactory, bytes calldata data) external payable returns (address launcher);

    /// @notice Read the Portal record for a Launcher (zeroed when it was not created through Portal).
    function getLauncher(address launcher) external view returns (LauncherRecord memory record);

    // ─────────────────────────────────────────────────────────────────────────
    // Reading a launch
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Vault provenance for a launch's VAULT fee slot. Both values are address(0) when the
    ///         launch had no VAULT slot (or `token` was not a launch).
    function getLaunchVault(address token) external view returns (address vault, address vaultFactory);

    // ─────────────────────────────────────────────────────────────────────────
    // Flap-only: how a factory is opened. You do not call these; the fork tests do, to stand in for Flap.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pause or resume NEW token creation for non-tester callers globally. Existing tokens are
    ///         unaffected.
    function setCreationPaused(bool paused) external;

    /// @notice Read the raw creation-gate bitmask (bit 0 = creation paused).
    function featureFlags() external view returns (uint256);

    /// @notice Set the V2 liquidity-floor multiplier and enabled flag for a vault factory. `newMultiplier` is
    ///         0..10_000 bps (10_000 = 1x; lower = lower creation gate and an easier `FlapTokenGraduated`
    ///         milestone) and scales both floors. `enabled` is independent of the multiplier: an enabled
    ///         factory may use any value including 0, and a disabled one is ignored. During the beta,
    ///         Flap enables LauncherFactories; the pause bypass is decided by the caller's LauncherFactory.
    ///         V2-only (V3SS graduation is a separate price-crossing mechanism). Callable by
    ///         DEFAULT_ADMIN_ROLE, MANAGE_ROLE or AUDITOR_ROLE.
    function setVaultFactoryMultiplier(address factory, uint16 newMultiplier, bool enabled) external;

    /// @notice Set a LauncherFactory's floor multiplier and enabled flag. DEFAULT_ADMIN_ROLE, MANAGE_ROLE or
    ///         AUDITOR_ROLE only.
    /// @dev `newMultiplier` is 0..10_000 (10_000 = no discount) and `enabled` is a separate switch, so an
    ///      enabled factory may have any multiplier including 0. A disabled factory keeps the multiplier it
    ///      was last given but is ignored everywhere: `newLauncher` reverts, and its existing Launchers fall
    ///      back to 1x and lose the pause bypass. Enabling requires a deployed contract. Public semantics
    ///      are unchanged: the multiplier used by the graduation lens is `10_000 - multiplierDiscount`.
    function setLauncherFactoryMultiplier(address factory, uint16 newMultiplier, bool enabled) external;

    /// @notice A LauncherFactory's enabled flag and multiplier in bps.
    function launcherFactoryMultiplier(address factory) external view returns (bool enabled, uint16 multiplierBps);
}
