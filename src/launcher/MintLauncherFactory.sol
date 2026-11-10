// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {LauncherFactoryBase} from "src/flap/LauncherFactoryBase.sol";
import {MintLauncher, MintConfig} from "./MintLauncher.sol";
import {LauncherDataSchema, FieldDescriptor} from "src/flap/IVaultSchemas.sol";

/// @title MintLauncherFactory
/// @notice Reference factory for `MintLauncher`. Shows what a Launcher factory has to do:
///           1. accept calls only from the Portal (`onlyHub`, applied by the base);
///           2. decode its own `data` layout (`MintConfig`) and deploy one Launcher per call;
///           3. hand the Launcher the salt-lock fee, so the Launcher locks the salt itself;
///           4. expose a Guardian-only upgrade path for the Launcher implementation.
///
///         Each Launcher is an ERC1967 beacon proxy at an address fixed by `(beacon, config.salt)`. The
///         factory owns the beacon; upgrading the implementation keeps every Launcher's address and storage.
///         `upgradeVaultImplementation` is the only privileged function, callable only by the Guardian. There
///         is no owner, pause, fee withdrawal or allowlist.
///
///         Call path:
///           Portal.newLauncher{value: fee}(factory, abi.encode(MintConfig))
///             -> factory.newLauncher(creator, data)            (onlyHub)
///             -> LibClone.deployDeterministicERC1967BeaconProxy(beacon, config.salt)
///             -> MintLauncher.initialize{value: fee}(hub, creator, config)   (locks the salt)
///           Portal records {factory} for the new Launcher.
///
///         The factory computes no multiplier. Flap enables it on the Portal with
///         `setLauncherFactoryMultiplier(factory, multiplier, enabled)`.
contract MintLauncherFactory is LauncherFactoryBase {
    /// @notice The Pool Launch Portal this factory deploys Launchers for.
    address public immutable hub;
    /// @notice The only account allowed to upgrade the Launcher implementation.
    address public immutable guardian;
    /// @notice The solady `UpgradeableBeacon` every Launcher proxy points at.
    address public immutable beacon;

    event MintLauncherCreated(
        address indexed factory, address indexed launcher, address indexed creator, bytes32 launchSalt
    );
    event FlapLauncherImplementationUpgraded(address implementation);

    error ZeroAddress();

    constructor(address hub_, address guardian_) {
        if (hub_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        hub = hub_;
        guardian = guardian_;

        MintLauncher impl = new MintLauncher();
        beacon = address(new UpgradeableBeacon(address(this), address(impl)));
    }

    /// @dev This reference takes both addresses as constructor arguments so it runs against any hub (test,
    ///      fork, local). A production factory normally keeps the base's chain-registry `_getHub()` and
    ///      `_getGuardian()`.
    function _getHub() internal view override returns (address) {
        return hub;
    }

    function _getGuardian() internal view override returns (address) {
        return guardian;
    }

    /// @inheritdoc LauncherFactoryBase
    /// @dev `msg.value` (the salt-lock fee) is forwarded to the Launcher, which pays the Portal itself so the
    ///      lock is recorded against the Launcher and not against this factory.
    function _newLauncher(address creator, bytes calldata data) internal override returns (address launcher) {
        MintConfig memory config = abi.decode(data, (MintConfig));

        launcher = LibClone.deployDeterministicERC1967BeaconProxy(beacon, config.salt);
        MintLauncher(launcher).initialize{value: msg.value}(hub, creator, config);

        emit MintLauncherCreated(address(this), launcher, creator, config.salt);
    }

    /// @inheritdoc LauncherFactoryBase
    /// @dev Retargets the beacon. Existing Launchers keep their address and storage; only the code they run
    ///      changes.
    function upgradeVaultImplementation(address newImplementation) external override onlyGuardian {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
        emit FlapLauncherImplementationUpgraded(newImplementation);
    }

    /// @notice The implementation every Launcher of this factory currently delegates to.
    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    /// @inheritdoc LauncherFactoryBase
    function launcherDataSchema() external pure override returns (LauncherDataSchema memory schema) {
        schema.description =
            "Contribution round: BNB is collected until the target is met. The raise and 50% of the supply then seed the pool; the other 50% is claimed by contributors in proportion to their share. If the target is missed, contributions are refunded.";
        schema.isArray = false;

        FieldDescriptor[] memory fields = new FieldDescriptor[](6);
        fields[0] = FieldDescriptor({name: "name", fieldType: "string", description: "Token name", decimals: 0});
        fields[1] = FieldDescriptor({name: "symbol", fieldType: "string", description: "Token symbol", decimals: 0});
        fields[2] = FieldDescriptor({name: "meta", fieldType: "string", description: "Metadata URI", decimals: 0});
        fields[3] = FieldDescriptor({
            name: "salt",
            fieldType: "bytes32",
            description: "CREATE2 salt; vanity-mined so the token address ends in 0x7777",
            decimals: 0
        });
        fields[4] = FieldDescriptor({
            name: "targetRaise",
            fieldType: "uint256",
            description: "BNB target that must be reached before the launch (also the pool quote)",
            decimals: 18
        });
        fields[5] = FieldDescriptor({
            name: "saleDuration", fieldType: "uint256", description: "Contribution window in seconds", decimals: 0
        });
        schema.fields = fields;
    }
}
