// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {IPortalTypes} from "src/flap/IPortal.sol";

import {SplitVault} from "./SplitVault.sol";
import {DirectLaunchVaultFactoryBase} from "src/flap/DirectLaunchVaultFactoryBase.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "src/flap/IVaultSchemas.sol";

/// @title SplitVaultFactory
/// @notice IDirectLaunchVaultFactory implementation backing FeeSlotType.VAULT: deploys one SplitVault beacon proxy
///         per launch, deterministically keyed by the launch token's predicted address, and initializes
///         it with the recipient list decoded from `vaultData`.
/// @dev Mirrors the launcher's own per-token pattern (see `PortalBase.dividendBeacon` and
///      `PortalDirectLauncherCreate._setupDividend`): the implementation is wrapped in a solady
///      `UpgradeableBeacon`, and each launch deploys an ERC-1967 beacon proxy via
///      `LibClone.deployDeterministicERC1967BeaconProxy`. One beacon upgrade therefore retargets the
///      split logic of every already-launched token at once. Adapted from the production
///      FlapTaxVaults/src/SplitVaultFactory.sol, which gated `newVault` to a single fixed VAULT_PORTAL
///      and rejected any non-native quote token; this version drops the quote restriction and instead
///      gates `newVault` to the chain's Hub from `LaunchVaultAddresses` (`onlyHub`; the Hub's own
///      _parseAndValidateFeeConfigs is what actually triggers a `newVault` call, from inside a
///      create-facet delegatecall — never callable standalone against a real launch). The caller gate
///      prevents a third party from pre-creating the deterministic proxy (a squat that would make the
///      real launch's `newVault` revert on the CREATE2 collision).
///
///      UPGRADES: the factory owns the beacon and `upgradeVaultImplementation` is Guardian-only, with no
///      owner, proxy admin or deployer path (the low-risk badge condition). To change the factory itself,
///      deploy a new one and have it audited and enabled by Flap.
///
///      BEHIND A LAUNCHER: the recipient list is the launch's `vaultData`. A Launcher using this vault
///      MUST fix the list in code or validate it; never forward creator input unchecked.
///
///      STRICT INPUTS: `newVault` rejects anything that is not exactly the documented shape before it
///      deploys: a single VAULT slot naming this factory (non-zero bps), a non-zero `token` / `creator`,
///      a Distribution that does not route reserve tokens to the vault, and `vaultData` that decodes to
///      a non-empty list of at most `MAX_RECIPIENTS` recipients with unique non-zero addresses, non-zero
///      bps each and bps summing to exactly 10_000. The vault re-checks the same invariants in
///      `initialize`, so a direct call cannot bypass them.
contract SplitVaultFactory is DirectLaunchVaultFactoryBase {
    /// @notice The solady `UpgradeableBeacon` every per-launch vault proxy points at.
    address public immutable beacon;

    /// @notice The chain's canonical WETH address, forwarded to every SplitVault this factory deploys —
    ///         see SplitVault.sol's top-of-file natspec for why each vault needs it (deciding whether
    ///         its own `quoteToken` means native BNB or a real ERC20).
    address public immutable weth;

    /// @notice Upper bound on recipients; mirrors `SplitVault.initialize`.
    uint256 public constant MAX_RECIPIENTS = 10;
    uint16 public constant TOTAL_BPS = 10_000;

    error NoRecipients();
    error TooManyRecipients(uint256 got, uint256 max);
    error NonCanonicalVaultData();
    error ZeroRecipient();
    error ZeroRecipientBps(address recipient);
    error DuplicateRecipient();
    error InvalidBpsSum(uint256 got);

    event FlapVaultImplementationUpgraded(address implementation);

    constructor(address weth_) {
        weth = weth_;
        SplitVault impl = new SplitVault();
        beacon = address(new UpgradeableBeacon(address(this), address(impl)));
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    /// @dev The VAULT-slot `vaultData` is `abi.encode(SplitVault.Recipient[])`. A native launch's raw quote
    ///      (`address(0)`) is normalized to WETH before initializing the vault.
    function newVault(address token, address creator, uint8 launchKind, bytes calldata launchParams)
        external
        override
        onlyHub
        returns (address vault)
    {
        (IPortalTypes.CreateTaxTokenParams memory p, Distribution memory d, bytes memory vaultData) =
            _validateLaunch(token, creator, launchKind, launchParams);
        _requireNoReserveDistribution(d);
        SplitVault.Recipient[] memory recipientsArr = _decodeRecipients(vaultData);
        address quoteToken = p.quoteToken == address(0) ? weth : p.quoteToken;

        bytes32 salt = bytes32(uint256(uint160(token)));
        vault = LibClone.deployDeterministicERC1967BeaconProxy(beacon, salt);
        SplitVault(payable(vault)).initialize(token, quoteToken, weth, recipientsArr);
    }

    /// @dev Strict decode of `abi.encode(Recipient[])`. The byte length must equal the canonical encoding of
    ///      `n` recipients exactly (offset word + length word + n * 2 words), so trailing or truncated
    ///      bytes are rejected instead of being silently ignored. Each entry must be non-zero, unique,
    ///      carry non-zero bps (and fit in uint16), and the total must be exactly 10_000.
    function _decodeRecipients(bytes memory vaultData) internal pure returns (SplitVault.Recipient[] memory r) {
        // offset(32) + length(32) is the minimum; the array length word sits at byte 64.
        if (vaultData.length < 64) revert InvalidVaultData();
        uint256 n;
        uint256 offset;
        assembly ("memory-safe") {
            offset := mload(add(vaultData, 32))
            n := mload(add(vaultData, 64))
        }
        if (n == 0) revert NoRecipients();
        if (n > MAX_RECIPIENTS) revert TooManyRecipients(n, MAX_RECIPIENTS);
        if (offset != 32 || vaultData.length != 64 + n * 64) revert NonCanonicalVaultData();

        // Raw words first: `abi.decode` into uint16 would revert on overflow with no useful reason.
        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            uint256 who;
            uint256 bps;
            assembly ("memory-safe") {
                who := mload(add(vaultData, add(96, mul(i, 64))))
                bps := mload(add(vaultData, add(128, mul(i, 64))))
            }
            if (who == 0 || who > type(uint160).max) revert ZeroRecipient();
            if (bps == 0 || bps > TOTAL_BPS) revert ZeroRecipientBps(address(uint160(who)));
            total += bps;
        }
        if (total != TOTAL_BPS) revert InvalidBpsSum(total);

        r = abi.decode(vaultData, (SplitVault.Recipient[]));
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (r[i].recipient == r[j].recipient) revert DuplicateRecipient();
            }
        }
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Split vault: distribute the launch's quote revenue among 1-10 unique recipients by bps (each > 0, sum = 10000).";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("recipient", "address", "Recipient address", 0);
        schema.fields[1] = FieldDescriptor("bps", "uint16", "Share in bps (sum across recipients = 10000)", 0);
        schema.isArray = true;
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function isQuoteTokenSupported(address) public pure override returns (bool) {
        return true;
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function factorySpecVersion() public pure override returns (string memory) {
        return "pl-v1";
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory) {
        return new FactoryPolicy[](0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Beacon administration (Guardian only)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Upgrade the implementation every per-launch vault delegates to. Guardian-only.
    function upgradeVaultImplementation(address newImplementation) external override onlyGuardian {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit FlapVaultImplementationUpgraded(newImplementation);
    }

    /// @notice The implementation every per-launch vault currently delegates to.
    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }
}
