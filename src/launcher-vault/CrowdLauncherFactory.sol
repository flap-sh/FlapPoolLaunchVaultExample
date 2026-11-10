// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {LauncherFactoryBase} from "src/flap/LauncherFactoryBase.sol";
import {LauncherDataSchema, FieldDescriptor} from "src/flap/IVaultSchemas.sol";
import {CrowdLauncher, CrowdConfig} from "./CrowdLauncher.sol";
import {CROWD_MIN_CONTRIBUTOR_BPS, CROWD_MAX_CONTRIBUTOR_BPS} from "./CrowdVault.sol";

/// @title CrowdLauncherFactory
/// @notice Launcher factory for `CrowdLauncher`. It is the Launcher half of a Launcher + Vault pair:
///         every Launcher it creates must name the paired `CrowdVaultFactory`, so a Launcher cannot be
///         created against some other vault.
///
///         Strict checks in `_newLauncher` (all rejected, none defaulted):
///           - `vaultFactory == pairedVaultFactory`, set once at construction;
///           - `contributorBps` within [10%, 90%];
///           - `targetRaise` and `saleDuration` non-zero and within sane bounds;
///           - non-empty name, symbol, salt.
///
///         Upgrades: Guardian only, through the beacon. No other privileged function.
contract CrowdLauncherFactory is LauncherFactoryBase {
    address public immutable hub;
    address public immutable guardian;
    address public immutable beacon;
    /// @notice The vault factory every Launcher of this factory must use. Fixed at construction.
    address public immutable pairedVaultFactory;

    uint256 public constant MIN_TARGET = 1 ether;
    uint256 public constant MAX_TARGET = 10_000 ether;
    uint256 public constant MAX_SALE_DURATION = 30 days;

    error ZeroAddress();
    error WrongVaultFactory(address got, address expected);
    error InvalidContributorBps(uint256 bps);
    error TargetOutOfRange(uint256 got);
    error SaleDurationOutOfRange(uint256 got);
    error EmptyField();
    error InvalidData();

    event CrowdLauncherCreated(address indexed launcher, address indexed creator, bytes32 launchSalt);
    event FlapLauncherImplementationUpgraded(address implementation);

    constructor(address hub_, address guardian_, address pairedVaultFactory_) {
        if (hub_ == address(0) || guardian_ == address(0) || pairedVaultFactory_ == address(0)) revert ZeroAddress();
        hub = hub_;
        guardian = guardian_;
        pairedVaultFactory = pairedVaultFactory_;
        beacon = address(new UpgradeableBeacon(address(this), address(new CrowdLauncher())));
    }

    function _getHub() internal view override returns (address) {
        return hub;
    }

    function _getGuardian() internal view override returns (address) {
        return guardian;
    }

    function _newLauncher(address creator, bytes calldata data) internal override returns (address launcher) {
        // `abi.decode` ignores trailing bytes, so insist on the exact canonical length first. The struct
        // has three dynamic strings, so compare against a re-encoding instead of a fixed size.
        CrowdConfig memory c = abi.decode(data, (CrowdConfig));
        if (keccak256(abi.encode(c)) != keccak256(data)) revert InvalidData();

        if (c.vaultFactory != pairedVaultFactory) revert WrongVaultFactory(c.vaultFactory, pairedVaultFactory);
        if (c.contributorBps < CROWD_MIN_CONTRIBUTOR_BPS || c.contributorBps > CROWD_MAX_CONTRIBUTOR_BPS) {
            revert InvalidContributorBps(c.contributorBps);
        }
        if (c.targetRaise < MIN_TARGET || c.targetRaise > MAX_TARGET) revert TargetOutOfRange(c.targetRaise);
        if (c.saleDuration == 0 || c.saleDuration > MAX_SALE_DURATION) revert SaleDurationOutOfRange(c.saleDuration);
        if (bytes(c.name).length == 0 || bytes(c.symbol).length == 0 || c.salt == bytes32(0)) revert EmptyField();

        launcher = LibClone.deployDeterministicERC1967BeaconProxy(beacon, c.salt);
        CrowdLauncher(launcher).initialize{value: msg.value}(hub, creator, c);
        emit CrowdLauncherCreated(launcher, creator, c.salt);
    }

    function upgradeVaultImplementation(address newImplementation) external override onlyGuardian {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit FlapLauncherImplementationUpgraded(newImplementation);
    }

    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    function launcherDataSchema() external pure override returns (LauncherDataSchema memory schema) {
        schema.description =
            "Crowd-funded launch: contributors fund the pool together. When the target is met the token launches; contributors then split 50% of the supply and share the token's tax revenue through a paired vault, pro rata to their contribution. The creator sets what share of that revenue goes to contributors (10% to 90%; the rest goes to the creator), and the vault states the exact split. If the target is missed, contributions are refunded.";
        FieldDescriptor[] memory f = new FieldDescriptor[](8);
        f[0] = FieldDescriptor("name", "string", "Token name", 0);
        f[1] = FieldDescriptor("symbol", "string", "Token symbol", 0);
        f[2] = FieldDescriptor("meta", "string", "Metadata URI", 0);
        f[3] = FieldDescriptor("salt", "bytes32", "Vanity-mined launch salt", 0);
        f[4] = FieldDescriptor("targetRaise", "uint256", "BNB target (1 to 10000)", 18);
        f[5] = FieldDescriptor("saleDuration", "uint256", "Contribution window in seconds (max 30 days)", 0);
        f[6] = FieldDescriptor("vaultFactory", "address", "Must be the paired CrowdVaultFactory", 0);
        f[7] = FieldDescriptor("contributorBps", "uint16", "Contributors' share of vault revenue (1000-9000)", 0);
        schema.fields = f;
    }
}
