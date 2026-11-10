// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {IPortal, IPortalTypes} from "src/flap/IPortal.sol";

import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {DirectLaunchVaultFactoryBase} from "src/flap/DirectLaunchVaultFactoryBase.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "src/flap/IVaultSchemas.sol";
import {CrowdVault, ICrowdLauncher, CROWD_MIN_CONTRIBUTOR_BPS, CROWD_MAX_CONTRIBUTOR_BPS} from "./CrowdVault.sol";

/// @notice What the factory asks a Launcher to prove about itself.
interface ICrowdLauncherCheck is ICrowdLauncher {
    function token() external view returns (address);
    function launching() external view returns (bool);
}

/// @title CrowdVaultFactory
/// @notice Vault factory paired with `CrowdLauncherFactory`. It only serves Launchers created by that
///         factory, so the Vault's split can be trusted to come from the matching Launcher.
///
///         What `newVault` checks before it deploys (everything is rejected, not defaulted):
///           1. the caller is the Portal (`onlyHub`), and the common launch checks pass;
///           2. `creator` (the launch caller, i.e. the Launcher) was created by `launcherFactory`, which the
///              Portal itself records. A stranger contract cannot pose as a Launcher;
///           3. `vaultData` is exactly `abi.encode(address launcher, uint16 contributorBps)` and names the
///              calling Launcher, so a Launcher cannot point the vault at someone else's contributions;
///           4. `contributorBps` is within [10%, 90%];
///           5. the VAULT slot takes exactly 80% and the token is native-quote, so the Vault's
///              BNB accounting holds;
///           6. no reserve is routed to the vault (the Launcher keeps its own half).
contract CrowdVaultFactory is DirectLaunchVaultFactoryBase {
    address public immutable beacon;
    /// @notice The only Launcher factory whose Launchers this vault factory accepts.
    address public immutable launcherFactory;

    uint16 public constant VAULT_SLOT_BPS = 8000;

    error NotFromLauncherFactory(address launcher);
    error VaultDataLauncherMismatch(address expected, address got);
    error VaultSlotBpsMismatch(uint16 got, uint16 expected);
    error NativeQuoteOnly(address quoteToken);
    error LauncherNotLaunching(address launcher);
    error LauncherNotFunded(uint256 raised, uint256 target);
    error InvalidContributorBps(uint256 bps);

    event FlapVaultImplementationUpgraded(address implementation);
    event CrowdVaultCreated(address indexed vault, address indexed token, address indexed launcher);

    constructor(address launcherFactory_) {
        if (launcherFactory_ == address(0)) revert ZeroAddress();
        launcherFactory = launcherFactory_;
        beacon = address(new UpgradeableBeacon(address(this), address(new CrowdVault())));
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function newVault(address token, address creator, uint8 launchKind, bytes calldata launchParams)
        external
        override
        onlyHub
        returns (address vault)
    {
        (IPortalTypes.CreateTaxTokenParams memory p, Distribution memory d, bytes memory vaultData) =
            _validateLaunch(token, creator, launchKind, launchParams);
        _requireNoReserveDistribution(d);

        // 2. The caller must be a Launcher this factory family created.
        if (IPortal(_getHub()).getLauncher(creator).launcherFactory != launcherFactory) {
            revert NotFromLauncherFactory(creator);
        }

        // 3. Exact vaultData, naming the calling Launcher.
        if (vaultData.length != 64) revert InvalidVaultData();
        (address named, uint256 bps) = abi.decode(vaultData, (address, uint256));
        if (named != creator) revert VaultDataLauncherMismatch(creator, named);
        // 4.
        if (bps < CROWD_MIN_CONTRIBUTOR_BPS || bps > CROWD_MAX_CONTRIBUTOR_BPS) revert InvalidContributorBps(bps);

        // 5. Native quote and the slot size the vault's economics assume.
        if (p.quoteToken != address(0)) revert NativeQuoteOnly(p.quoteToken);
        uint16 slotBps = _vaultSlotBps(p.feeConfigs);
        if (slotBps != VAULT_SLOT_BPS) revert VaultSlotBpsMismatch(slotBps, VAULT_SLOT_BPS);

        // The Launcher must be mid-launch with the full raise in, so the split is final.
        ICrowdLauncherCheck l = ICrowdLauncherCheck(creator);
        if (!l.launching()) revert LauncherNotLaunching(creator);
        if (l.raised() != l.targetRaise()) revert LauncherNotFunded(l.raised(), l.targetRaise());

        vault = LibClone.deployDeterministicERC1967BeaconProxy(beacon, bytes32(uint256(uint160(token))));
        CrowdVault(payable(vault)).initialize(token, creator, uint16(bps));
        emit CrowdVaultCreated(vault, token, creator);
    }

    /// @dev `_validateLaunch` already guarantees exactly one VAULT slot naming this factory.
    function _vaultSlotBps(IPortalTypes.FeeConfig[] memory fees) internal view returns (uint16) {
        for (uint256 i; i < fees.length; ++i) {
            if (fees[i].feeType != IPortalTypes.FeeSlotType.VAULT) continue;
            IPortalTypes.FeeConfigVault memory v = abi.decode(fees[i].configData, (IPortalTypes.FeeConfigVault));
            if (v.vaultFactory == address(this)) return fees[i].bps;
        }
        return 0;
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Crowd vault: shares native BNB tax revenue between the contributors of the launching CrowdLauncher (pro rata) and its creator. Set by the launcher, not by hand.";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("launcher", "address", "The CrowdLauncher that is launching", 0);
        schema.fields[1] = FieldDescriptor("contributorBps", "uint16", "Contributors' share in bps (1000-9000)", 0);
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function isQuoteTokenSupported(address quoteToken) public pure override returns (bool) {
        return quoteToken == address(0);
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function factorySpecVersion() public pure override returns (string memory) {
        return "pl-v1";
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](2);
        policies[0] = FactoryPolicy({
            target: "quoteToken", operator: "eq", value: abi.encode(address(0)), description: "Native BNB quote only."
        });
        policies[1] = FactoryPolicy({
            target: "vaultSlotBps",
            operator: "eq",
            value: abi.encode(uint256(VAULT_SLOT_BPS)),
            description: "The VAULT slot must take exactly 80% of the tax."
        });
    }

    function upgradeVaultImplementation(address newImplementation) external override onlyGuardian {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit FlapVaultImplementationUpgraded(newImplementation);
    }

    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }
}
