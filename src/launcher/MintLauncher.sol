// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {IPortalTypes, IPortal} from "src/flap/IPortal.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {LauncherBase} from "src/flap/LauncherBase.sol";
import {Distribution, DistributionTarget} from "src/flap/Distribution.sol";
import {IStrategy} from "src/flap/IStrategy.sol";
import {LaunchExtensionHelper} from "src/flap/LaunchExtensionHelper.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LauncherDescription} from "src/flap/LauncherHelper.sol";

// Display copy for `description()`. Chinese constants must be `unicode` literals.
string constant MINT_TITLE_ZH = unicode"募资发射";
string constant MINT_TITLE_EN = "Contribution round";
string constant MINT_SUMMARY_ZH =
    unicode"持续募集 BNB 直至达到目标。募集的 BNB 与 50% 的代币供应一起注入流动性池，另外 50% 由贡献者按出资比例领取。未达到目标时，出资可以退回。";
string constant MINT_SUMMARY_EN =
    "BNB is collected until the target is met. The raise and 50% of the supply then seed the pool; the other 50% is claimed by contributors in proportion to their share. If the target is missed, contributions are refunded.";

/// @notice Payload the creator passes to `Portal.newLauncher(factory, abi.encode(MintConfig))`.
/// @param name         Token name.
/// @param symbol       Token symbol.
/// @param meta         Metadata URI, passed to the token unchanged.
/// @param salt         CREATE2 launch salt. Mine it so the predicted token address ends in `0x7777`;
///                     the Portal's `lockSalt` rejects any other salt.
/// @param targetRaise  BNB that must be raised before the launch runs. The whole amount becomes `poolQuote`.
/// @param saleDuration Length of the contribution window in seconds, counted from creation.
struct MintConfig {
    string name;
    string symbol;
    string meta;
    bytes32 salt;
    uint256 targetRaise;
    uint256 saleDuration;
}

/// @title MintLauncher
/// @notice Reference Launcher: a target-based contribution round that ends in a single Flap launch.
///
///         Contributors send BNB until `targetRaise` is reached. The contribution that reaches it launches
///         the token in the same transaction: the whole raise is the pool's quote side, half of the supply
///         is the pool's token side, and the other half comes back to this contract for contributors to
///         claim in proportion to what they put in. If the target is missed, contributors take their BNB back.
///
///         Mechanism (what a Launcher author has to get right, in order):
///           1. `initialize` runs once, right after the factory deploys the proxy. It locks the launch
///              salt FROM THIS CONTRACT, because the Portal requires `locker == launcher` at launch time.
///           2. `contribute()` adds BNB. Each call is capped so `raised <= targetRaise`; the call that makes
///              `raised == targetRaise` runs `_launch()` itself. There is no separate launch call, so the
///              contract always holds the full raise at that moment.
///           3. `_launch()` calls `Portal.launchTaxTokenV2` with `poolQuote = targetRaise` and
///              `poolToken = TOTAL_SUPPLY / 2`. The remaining half is routed back through
///              `Distribution{EXPLICIT, strategy = this}`.
///           4. During that same call the Portal invokes `initializeDistribution`, and this contract pulls the
///              half it was approved for. The Portal reverts the launch if the allowance is not fully used.
///           5. After launch, `claim()` pays `contribution * DISTRIBUTED / targetRaise`.
///           6. If the deadline passes below target, `refund()` returns each contribution. Refunds are blocked
///              once the target is reached or the launch has happened.
///
///         The Portal side is fixed by the platform: the caller must be this Launcher (so the factory must be
///         enabled), the Launcher launches once, and a Launcher whose factory is later disabled loses its
///         discount and its pause bypass. Everything inside the round (pricing, caps, claim rules) is free to
///         change.
///
/// @dev Deployed by `MintLauncherFactory` as an ERC1967 beacon proxy, so the implementation can be upgraded
///      by the Guardian without changing this contract's address, its salt lock, or any state below.
contract MintLauncher is LauncherBase, Initializable, IStrategy {
    using SafeTransferLib for address;

    /// @notice Supply the Portal mints: 1,000,000 tokens.
    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;
    /// @notice Pool side of the supply: 50%.
    uint256 public constant POOL_TOKEN = TOTAL_SUPPLY / 2;
    /// @dev The other 50%, sent back here for contributors.
    uint256 internal constant DISTRIBUTED_TOKEN = TOTAL_SUPPLY - POOL_TOKEN;

    address public hub;
    address public creator;
    bytes32 public launchSalt;
    /// @notice BNB needed to launch; also the exact `poolQuote`.
    uint256 public targetRaise;
    /// @notice End of the contribution window.
    uint256 public saleDeadline;

    string public name;
    string public symbol;
    string public meta;

    /// @notice BNB raised so far, never above `targetRaise`.
    uint256 public raised;
    mapping(address account => uint256 amount) public contributions;

    /// @notice Set once the Portal launch succeeded.
    bool public launched;
    /// @dev True only while the Portal call is running. It authorizes the distribution callback and
    ///      blocks `contribute()` from re-entering.
    bool internal launching;
    bool internal distributionInitialized;

    address public token;
    address public pool;
    /// @notice Tokens each contributor has already claimed.
    mapping(address account => uint256 amount) public claimed;

    event Contributed(address indexed account, uint256 amount);
    event Launched(address indexed token, address indexed pool, uint256 poolQuote, uint256 poolToken);
    event Claimed(address indexed account, uint256 amount);
    event Refunded(address indexed account, uint256 amount);

    error InvalidConfig();
    error SaleClosed();
    error ZeroContribution();
    error TargetExceeded();
    error LaunchInProgress();
    error UnauthorizedDistribution();
    error DistributionNotInitialized();
    error NothingToClaim();
    error RefundUnavailable();
    error NothingToRefund();
    error EthTransferFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Called once by the factory in the transaction that deploys the proxy.
    /// @dev `msg.value` is the salt-lock fee the factory forwarded from the Portal call. The Launcher pays it
    ///      to the Portal itself so the Portal records this proxy as the salt's locker.
    function initialize(address hub_, address creator_, MintConfig calldata c) external payable initializer {
        if (hub_ == address(0) || creator_ == address(0)) revert InvalidConfig();
        if (c.salt == bytes32(0) || c.targetRaise == 0 || c.saleDuration == 0) revert InvalidConfig();

        hub = hub_;
        creator = creator_;
        launchSalt = c.salt;
        targetRaise = c.targetRaise;
        saleDeadline = block.timestamp + c.saleDuration;
        name = c.name;
        symbol = c.symbol;
        meta = c.meta;

        uint256 fee = IPortal(hub_).SALT_LOCK_FEE();
        // Exactly the fee: anything extra would stay here, since neither a refund nor the launch can spend it.
        if (msg.value != fee) revert InvalidConfig();
        IPortal(hub_).lockSalt{value: fee}(c.salt, uint8(IPortalTypes.LaunchKind.DIRECT_V2_POOL_TAX));
    }

    /// @inheritdoc LauncherBase
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
        d.titleZh = MINT_TITLE_ZH;
        d.titleEn = MINT_TITLE_EN;
        d.summaryZh = MINT_SUMMARY_ZH;
        d.summaryEn = MINT_SUMMARY_EN;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Contribution round
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Add BNB to the raise. The call that reaches `targetRaise` also launches.
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

    /// @notice Take back a contribution after a failed round (deadline passed, target not reached).
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
    // Launch and distribution
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Runs inside the contribution that reaches the target.
    function _launch() private {
        IPortalTypes.CreateTaxTokenParams memory p = _buildParams();
        Distribution memory dist = Distribution({
            target: DistributionTarget.EXPLICIT,
            strategy: address(this), // the Portal calls initializeDistribution on us
            amount: uint128(DISTRIBUTED_TOKEN),
            configData: ""
        });
        IPortalTypes.CreatorBuyParams memory creatorBuy;

        // `LauncherBase._launchOnHub` takes calldata parameters, and these are built in memory, so the same
        // Portal entry point is called directly.
        launching = true;
        (address token_, address pool_) = IPortal(hub).launchTaxTokenV2{value: targetRaise}(p, dist, creatorBuy);
        launching = false;

        launched = true;
        token = token_;
        pool = pool_;
        emit Launched(token_, pool_, targetRaise, POOL_TOKEN);
    }

    /// @inheritdoc IStrategy
    /// @dev Portal callback inside `_launch()`. The Portal has approved `amount`; this must pull all of it.
    function initializeDistribution(address token_, uint256 amount, bytes calldata, bytes32) external override onlyHub {
        if (!launching || distributionInitialized) revert UnauthorizedDistribution();
        if (token_ == address(0) || amount != DISTRIBUTED_TOKEN) revert InvalidConfig();

        distributionInitialized = true;
        token = token_;

        token_.safeTransferFrom(msg.sender, address(this), amount);
        emit FlapDistributionInitialized(token_, amount);
    }

    /// @notice Claim the caller's share of the distributed half.
    function claim() external {
        if (!launched) revert DistributionNotInitialized();

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

    /// @dev Fixed launch shape: `targetRaise` BNB as the quote side, 50% of supply as the token side,
    ///      3% buy / 5% sell tax, and a simple fee split.
    function _buildParams() private view returns (IPortalTypes.CreateTaxTokenParams memory p) {
        p.name = name;
        p.symbol = symbol;
        p.meta = meta;
        p.totalSupply = TOTAL_SUPPLY;
        p.salt = launchSalt;
        p.quoteToken = address(0); // native BNB
        p.dexId = 0;
        p.poolQuote = targetRaise;
        p.poolToken = POOL_TOKEN;
        p.buyTaxRate = 300;
        p.sellTaxRate = 500;
        p.taxDuration = 30 days;
        p.antiFarmerDuration = 1 days;
        p.feeConfigs = _feeConfigs();
        p.antiSniperMode = 0;
        p.exemptWindow = 0;
        p.exemptAddrs = new address[](0);
        p.creatorBuyQuote = 0;
        // Show the end user, not this contract, as the creator on the launch event. The Portal accepts the
        // creator extension from a recorded Launcher; vault, salt and payment still use this contract.
        (p.extensionID, p.extensionData) = LaunchExtensionHelper.encodeCreator(creator);
        p.commissionReceiver = address(0);
    }

    /// @dev Tax split, bps summing to 10_000: 10% burn, 15% liquidity, 75% dividends to holders.
    function _feeConfigs() private pure returns (IPortalTypes.FeeConfig[] memory fees) {
        fees = new IPortalTypes.FeeConfig[](3);
        fees[0] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 1000, configData: ""});
        fees[1] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.LP_BPS, bps: 1500, configData: ""});
        fees[2] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.DIVIDEND,
            bps: 7500,
            configData: abi.encode(
                IPortalTypes.FeeConfigDividend({
                    dividendToken: address(0), // quote token
                    minimumShareBalance: TOTAL_SUPPLY / 1000 // 0.1% of supply (the allowed cap)
                })
            )
        });
    }
}
