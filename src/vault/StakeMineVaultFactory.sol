// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {IPortalTypes} from "src/flap/IPortal.sol";

import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {StakeMineVault} from "./StakeMineVault.sol";
import {DirectLaunchVaultFactoryBase} from "src/flap/DirectLaunchVaultFactoryBase.sol";
import {Distribution, DistributionTarget} from "src/flap/Distribution.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "src/flap/IVaultSchemas.sol";

/// @title StakeMineVaultFactory
/// @notice Reference `IDirectLaunchVaultFactory` for `StakeMineVault`. It shows the three jobs a factory
///         has when its vault depends on the launch's reserve:
///           1. ENFORCE the launch shape before anything is deployed (the reserve must come to this
///              vault, be exactly 80% of the supply, and nothing may be left over);
///           2. DECODE its own `vaultData` (the lock tiers) and validate it;
///           3. DEPLOY one beacon-proxy vault per token and initialize it in the same call.
/// @author The Flap Team
/// @dev Follows the guide's conventions: `newVault` is `onlyHub`, validation runs before the deploy, the
///      factory never calls `token` (it has no code yet), and the factory is immutable. The beacon is
///      owned by the factory and `upgradeVaultImplementation` is Guardian-only, with no owner, proxy
///      admin or deployer path (the low-risk badge condition). To change the factory itself, deploy a
///      new one.
///
///      The returned vault is both the `VAULT` fee-slot recipient (quote revenue) and the
///      `Distribution.target == VAULT` target (the reserve). Launch with:
///        - a `VAULT` slot whose `vaultFactory` is this factory (`vaultData` = `abi.encode(Tier[])`,
///          or empty for the default tiers);
///        - `distribution = {target: VAULT, amount: totalSupply * 80%, ...}`, and
///          `poolToken = totalSupply * 20%`.
///        - no `MARKETING` slot (it cannot be combined with `VAULT`), and a `DIVIDEND` slot, if any,
///          paying in the quote (`dividendToken == address(0)`).
contract StakeMineVaultFactory is DirectLaunchVaultFactoryBase {
    /// @notice The solady `UpgradeableBeacon` every per-launch vault proxy points at.
    address public immutable beacon;

    /// @notice The chain's canonical WETH address; a native launch's quote is normalized to it.
    address public immutable weth;

    /// @notice Share of supply that must be handed to the vault as the reserve.
    uint16 public constant RESERVE_BPS = 8000;
    /// @notice Part of the supply that vests to the dev (taken out of the reserve).
    uint16 public constant DEV_VEST_BPS = 100;
    /// @notice The dev may recoup this multiple of the quote seeded into the pool (150% = 1.5x).
    uint16 public constant DEV_CAP_BPS = 15_000;
    uint32 public constant DEV_VEST_DURATION = 30 days;
    uint32 public constant MINING_DURATION = 90 days;

    uint256 public constant MAX_TIERS = 5;
    uint32 public constant MAX_LOCK = 365 days;
    uint16 public constant MIN_MULTIPLIER_BPS = 10_000; // x1
    uint16 public constant MAX_MULTIPLIER_BPS = 30_000; // x3

    error WrongDistributionTarget(DistributionTarget got);
    error WrongReserveAmount(uint256 got, uint256 expected);
    error SupplyMismatch();
    error DividendMustPayInQuote(address dividendToken);
    error MissingDividendSlot();
    error BadTiers();
    error ZeroPoolQuote();

    event FlapStakeMineVaultCreated(address vault, address taxToken, address creator);
    event FlapVaultImplementationUpgraded(address implementation);

    constructor(address weth_) {
        weth = weth_;
        StakeMineVault impl = new StakeMineVault();
        beacon = address(new UpgradeableBeacon(address(this), address(impl)));
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

        // 1. Enforce the launch shape. The vault's economics assume exactly this reserve.
        if (d.target != DistributionTarget.VAULT) revert WrongDistributionTarget(d.target);
        if (p.poolQuote == 0) revert ZeroPoolQuote();
        uint256 reserve = p.totalSupply * RESERVE_BPS / 10_000;
        if (d.amount != reserve) revert WrongReserveAmount(d.amount, reserve);
        if (p.poolToken + d.amount != p.totalSupply) revert SupplyMismatch();
        _requireDividendInQuote(p.feeConfigs);

        // 2. Decode and validate our own vaultData.
        StakeMineVault.Tier[] memory tiers = _decodeTiers(vaultData);

        // 3. Deploy deterministically from `token` (one vault per token) and initialize.
        StakeMineVault.InitParams memory c = StakeMineVault.InitParams({
            taxToken: token,
            quoteToken: p.quoteToken == address(0) ? weth : p.quoteToken,
            weth: weth,
            dev: creator,
            reserveAmount: reserve,
            devVestAmount: p.totalSupply * DEV_VEST_BPS / 10_000,
            devQuoteCap: p.poolQuote * DEV_CAP_BPS / 10_000,
            devVestDuration: DEV_VEST_DURATION,
            miningDuration: MINING_DURATION,
            tiers: tiers
        });
        vault = LibClone.deployDeterministicERC1967BeaconProxy(beacon, bytes32(uint256(uint160(token))));
        StakeMineVault(payable(vault)).initialize(c);

        emit FlapStakeMineVaultCreated(vault, token, creator);
    }

    /// @dev The vault deposits its holder share into the token's dividend contract as the quote. Without a
    ///      DIVIDEND slot the token has no such contract, `flushDividends` has nothing to pay into and the
    ///      holders' share would sit in the vault forever. So a DIVIDEND slot is required, and it must pay in
    ///      the quote (`dividendToken == address(0)`), not another asset.
    function _requireDividendInQuote(IPortalTypes.FeeConfig[] memory feeConfigs) internal pure {
        bool found;
        for (uint256 i = 0; i < feeConfigs.length; ++i) {
            if (feeConfigs[i].feeType != IPortalTypes.FeeSlotType.DIVIDEND) continue;
            IPortalTypes.FeeConfigDividend memory dv =
                abi.decode(feeConfigs[i].configData, (IPortalTypes.FeeConfigDividend));
            if (dv.dividendToken != address(0)) revert DividendMustPayInQuote(dv.dividendToken);
            found = true;
        }
        if (!found) revert MissingDividendSlot();
    }

    /// @dev `vaultData` is `abi.encode(StakeMineVault.Tier[])`. Empty means the default ladder:
    ///      30 days x1, 90 days x1.5, 180 days x2. Locks must strictly increase, and so must the
    ///      multipliers, so a longer lock is never worth less.
    function _decodeTiers(bytes memory vaultData) internal pure returns (StakeMineVault.Tier[] memory tiers) {
        if (vaultData.length == 0) {
            tiers = new StakeMineVault.Tier[](3);
            tiers[0] = StakeMineVault.Tier(30 days, 10_000);
            tiers[1] = StakeMineVault.Tier(90 days, 15_000);
            tiers[2] = StakeMineVault.Tier(180 days, 20_000);
            return tiers;
        }
        // Exactly the canonical encoding of n tiers: offset word + length word + n * 2 words. Anything else
        // (trailing bytes, truncation, a non-canonical offset) is rejected, not partially decoded.
        if (vaultData.length < 64) revert BadTiers();
        uint256 n;
        uint256 offset;
        assembly ("memory-safe") {
            offset := mload(add(vaultData, 32))
            n := mload(add(vaultData, 64))
        }
        if (offset != 32 || n == 0 || n > MAX_TIERS || vaultData.length != 64 + n * 64) revert BadTiers();
        tiers = abi.decode(vaultData, (StakeMineVault.Tier[]));
        if (tiers.length == 0 || tiers.length > MAX_TIERS) revert BadTiers();
        for (uint256 i = 0; i < tiers.length; ++i) {
            if (tiers[i].lockDuration > MAX_LOCK) revert BadTiers();
            if (tiers[i].multiplierBps < MIN_MULTIPLIER_BPS || tiers[i].multiplierBps > MAX_MULTIPLIER_BPS) {
                revert BadTiers();
            }
            if (
                i != 0
                    && (tiers[i].lockDuration <= tiers[i - 1].lockDuration
                        || tiers[i].multiplierBps <= tiers[i - 1].multiplierBps)
            ) revert BadTiers();
        }
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = "Stake-to-mine lock tiers (1-5 rows; locks and multipliers strictly increasing). "
            "Leave empty for the default 30d x1 / 90d x1.5 / 180d x2.";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("lockDuration", "uint32", "Lock in seconds (max 365 days)", 0);
        schema.fields[1] = FieldDescriptor("multiplierBps", "uint16", "Weight multiplier in bps (10000-30000)", 0);
        schema.isArray = true;
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    /// @dev Any quote works: native is normalized to WETH, and an ERC-20 quote is held and paid as is.
    function isQuoteTokenSupported(address) public pure override returns (bool) {
        return true;
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    function factorySpecVersion() public pure override returns (string memory) {
        return "pl-v1";
    }

    /// @inheritdoc DirectLaunchVaultFactoryBase
    /// @dev Informational mirror of the checks in `newVault`.
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](3);
        policies[0] = FactoryPolicy({
            target: "distribution.target",
            operator: "eq",
            value: abi.encode(uint8(DistributionTarget.VAULT)),
            description: "The reserve must be routed to this launch's vault (Distribution.target = VAULT)."
        });
        policies[1] = FactoryPolicy({
            target: "distribution.amountBps",
            operator: "eq",
            value: abi.encode(uint256(RESERVE_BPS)),
            description: "The reserve must be exactly 80% of totalSupply, and poolToken the other 20%."
        });
        policies[2] = FactoryPolicy({
            target: "dividendToken",
            operator: "eq",
            value: abi.encode(address(0)),
            description: "The launch must have a DIVIDEND slot, and it must pay in the quote token (dividendToken = address(0))."
        });
    }

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
