// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {IPortalTypes, IPortal} from "src/flap/IPortal.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LauncherBase} from "src/flap/LauncherBase.sol";
import {Distribution, DistributionTarget} from "src/flap/Distribution.sol";
import {IStrategy} from "src/flap/IStrategy.sol";
import {LaunchExtensionHelper} from "src/flap/LaunchExtensionHelper.sol";
import {LauncherDescription} from "src/flap/LauncherHelper.sol";

// Display copy for `description()`. Chinese constants must be `unicode` literals.
string constant CROWD_TITLE_ZH = unicode"众筹发射";
string constant CROWD_TITLE_EN = "Crowd-funded launch";
string constant CROWD_SUMMARY_ZH =
    unicode"贡献者共同出资建池。达到目标后代币发射，贡献者按出资比例分得 50% 的代币供应，并通过配套金库分享代币的税收收入。金库收入中归贡献者的比例由创建者设定（10% 到 90%，其余归创建者），确切比例以金库的说明为准。未达到目标时，出资可以退回。";
string constant CROWD_SUMMARY_EN =
    "Contributors fund the pool together. When the target is met the token launches; contributors then split 50% of the supply and share the token's tax revenue through a paired vault, pro rata to their contribution. The creator sets what share of that revenue goes to contributors (10% to 90%; the rest goes to the creator), and the vault states the exact split. If the target is missed, contributions are refunded.";

/// @notice Payload for `Portal.newLauncher(factory, abi.encode(CrowdConfig))`.
/// @param name            Token name.
/// @param symbol          Token symbol.
/// @param meta            Metadata URI.
/// @param salt            Launch salt, mined so the token address ends in `0x7777`.
/// @param targetRaise     BNB that must be raised before the launch. All of it becomes `poolQuote`.
/// @param saleDuration    Contribution window in seconds.
/// @param vaultFactory    The `CrowdVaultFactory` whose vault will take the tax revenue.
/// @param contributorBps  Share of the vault's revenue that goes to contributors (10% to 90%).
struct CrowdConfig {
    string name;
    string symbol;
    string meta;
    bytes32 salt;
    uint256 targetRaise;
    uint256 saleDuration;
    address vaultFactory;
    uint16 contributorBps;
}

/// @title CrowdLauncher
/// @notice A crowd-funded launch that pairs a Launcher with a Vault.
///
///         Users fund a token launch together. When the target is met, the token launches with a
///         `CrowdVault` in its VAULT slot, and from then on contributors earn from the token's tax in
///         proportion to what they put in, on top of the tokens they receive.
///
///         Two layers, one flow:
///
///           LAUNCHER (before the DEX)                    VAULT (after the DEX)
///           ─────────────────────────                    ─────────────────────
///           contribute()  ──┐                            tax dispatch ─► CrowdVault
///           contribute()  ──┤ raised == target                 │
///                           ▼                                  ▼
///                       _launch() ──► Portal ──► token + pool + CrowdVault
///                           │                                  │
///                  50% of supply back here              claim() by contributors / creator
///                  contributors claim() tokens          (shares read back from this Launcher)
///
///         The Vault reads each contributor's stake from this Launcher, so the two always agree.
///         Contributions are frozen once the target is reached: no more contributions, no refunds.
///
/// @dev Deployed by `CrowdLauncherFactory` as an ERC1967 beacon proxy.
contract CrowdLauncher is LauncherBase, Initializable, IStrategy {
    using SafeTransferLib for address;

    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant POOL_TOKEN = TOTAL_SUPPLY / 2;
    uint256 internal constant DISTRIBUTED_TOKEN = TOTAL_SUPPLY - POOL_TOKEN;

    address public hub;
    address public creator;
    bytes32 public launchSalt;
    uint256 public targetRaise;
    uint256 public saleDeadline;
    address public vaultFactory;
    uint16 public contributorBps;

    string public name;
    string public symbol;
    string public meta;

    uint256 public raised;
    mapping(address account => uint256 amount) public contributions;

    bool public launched;
    /// @notice True only while the Portal launch call is running. The paired vault factory reads it to
    ///         confirm the vault is being created by this very launch.
    bool public launching;
    bool internal distributionInitialized;

    address public token;
    address public pool;
    mapping(address account => uint256 amount) public claimed;

    event Contributed(address indexed account, uint256 amount);
    event Launched(address indexed token, address indexed pool, address indexed vaultFactory);
    event Claimed(address indexed account, uint256 amount);
    event Refunded(address indexed account, uint256 amount);

    error InvalidConfig();
    error SaleClosed();
    error ZeroContribution();
    error TargetExceeded();
    error LaunchInProgress();
    error UnauthorizedDistribution();
    error NotLaunched();
    error NothingToClaim();
    error RefundUnavailable();
    error NothingToRefund();
    error EthTransferFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address creator_, CrowdConfig calldata c) external payable initializer {
        if (hub_ == address(0) || creator_ == address(0)) revert InvalidConfig();
        if (c.salt == bytes32(0) || c.targetRaise == 0 || c.saleDuration == 0) revert InvalidConfig();
        if (c.vaultFactory == address(0) || c.contributorBps == 0) revert InvalidConfig();

        hub = hub_;
        creator = creator_;
        launchSalt = c.salt;
        targetRaise = c.targetRaise;
        saleDeadline = block.timestamp + c.saleDuration;
        vaultFactory = c.vaultFactory;
        contributorBps = c.contributorBps;
        name = c.name;
        symbol = c.symbol;
        meta = c.meta;

        // The Launcher locks the salt, so the Portal records it as the locker.
        uint256 fee = IPortal(hub_).SALT_LOCK_FEE();
        // Exactly the fee: anything extra would stay here, since neither a refund nor the launch can spend it.
        if (msg.value != fee) revert InvalidConfig();
        IPortal(hub_).lockSalt{value: fee}(c.salt, uint8(IPortalTypes.LaunchKind.DIRECT_V2_POOL_TAX));
    }

    function _getHub() internal view override returns (address) {
        return hub;
    }

    /// @inheritdoc LauncherBase
    function _description() internal view override returns (LauncherDescription memory d) {
        d.name = name;
        d.symbol = symbol;
        d.quoteToken = address(0); // native BNB, matching `_buildParams`' p.quoteToken
        d.targetRaise = targetRaise; // native has 18 decimals already
        d.poolTokenRatio = (POOL_TOKEN * 1e18) / TOTAL_SUPPLY;
        d.titleZh = CROWD_TITLE_ZH;
        d.titleEn = CROWD_TITLE_EN;
        d.summaryZh = CROWD_SUMMARY_ZH;
        d.summaryEn = CROWD_SUMMARY_EN;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Contribution
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Add BNB. The call that reaches `targetRaise` launches the token in the same transaction.
    function contribute() external payable {
        if (launching) revert LaunchInProgress();
        if (block.timestamp >= saleDeadline) revert SaleClosed();
        if (msg.value == 0) revert ZeroContribution();
        if (raised + msg.value > targetRaise) revert TargetExceeded();

        raised += msg.value;
        contributions[msg.sender] += msg.value;
        emit Contributed(msg.sender, msg.value);

        if (raised == targetRaise) _launch();
    }

    function refund() external {
        if (launched || raised == targetRaise || block.timestamp < saleDeadline) revert RefundUnavailable();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToRefund();

        contributions[msg.sender] = 0;
        raised -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Refunded(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Launch
    // ─────────────────────────────────────────────────────────────────────────

    function _launch() private {
        IPortalTypes.CreateTaxTokenParams memory p = _buildParams();
        // Reserved half comes back here for contributors.
        Distribution memory dist = Distribution({
            target: DistributionTarget.EXPLICIT,
            strategy: address(this),
            amount: uint128(DISTRIBUTED_TOKEN),
            configData: ""
        });
        IPortalTypes.CreatorBuyParams memory creatorBuy;

        launching = true;
        (address token_, address pool_) = IPortal(hub).launchTaxTokenV2{value: targetRaise}(p, dist, creatorBuy);
        launching = false;

        launched = true;
        token = token_;
        pool = pool_;
        emit Launched(token_, pool_, vaultFactory);
    }

    /// @inheritdoc IStrategy
    function initializeDistribution(address token_, uint256 amount, bytes calldata, bytes32) external override onlyHub {
        if (!launching || distributionInitialized) revert UnauthorizedDistribution();
        if (token_ == address(0) || amount != DISTRIBUTED_TOKEN) revert InvalidConfig();
        distributionInitialized = true;
        token = token_;
        token_.safeTransferFrom(msg.sender, address(this), amount);
        emit FlapDistributionInitialized(token_, amount);
    }

    /// @notice Claim the caller's share of the reserved tokens.
    function claim() external {
        if (!launched) revert NotLaunched();
        uint256 entitled = (contributions[msg.sender] * DISTRIBUTED_TOKEN) / targetRaise;
        uint256 amount = entitled - claimed[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimed[msg.sender] = entitled;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Launch parameters
    // ─────────────────────────────────────────────────────────────────────────

    function _buildParams() private view returns (IPortalTypes.CreateTaxTokenParams memory p) {
        p.name = name;
        p.symbol = symbol;
        p.meta = meta;
        p.totalSupply = TOTAL_SUPPLY;
        p.salt = launchSalt;
        p.quoteToken = address(0);
        p.dexId = 0;
        p.poolQuote = targetRaise;
        p.poolToken = POOL_TOKEN;
        p.buyTaxRate = 300;
        p.sellTaxRate = 500;
        p.taxDuration = 30 days;
        p.antiFarmerDuration = 1 days;
        p.feeConfigs = _feeConfigs();
        p.exemptAddrs = new address[](0);
        (p.extensionID, p.extensionData) = LaunchExtensionHelper.encodeCreator(creator);
    }

    /// @dev Tax split: 80% to the CrowdVault, 20% burned. The vault carries the whole economic story, so
    ///      there is no marketing wallet and no dividend slot.
    function _feeConfigs() private view returns (IPortalTypes.FeeConfig[] memory fees) {
        fees = new IPortalTypes.FeeConfig[](2);
        fees[0] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.VAULT,
            bps: 8000,
            configData: abi.encode(
                IPortalTypes.FeeConfigVault({
                    vaultFactory: vaultFactory, vaultData: abi.encode(address(this), contributorBps)
                })
            )
        });
        fees[1] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 2000, configData: ""});
    }
}
