// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {DirectLaunchVaultBase} from "src/flap/DirectLaunchVaultBase.sol";
import {ITokenDock} from "src/flap/ILaunchVaultSpec.sol";
import {IStrategy} from "src/flap/IStrategy.sol";
import {IDividend} from "src/flap/IDividend.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "src/flap/IVaultSchemas.sol";

/// @dev The one `FlapDirectTaxToken` getter this vault needs (the token's dividend tracker).
interface ITaxTokenDividend {
    function dividendContract() external view returns (address);
}

/// @dev Minimal WETH9 surface, used to turn native revenue into the dividend asset.
interface IWETH9 {
    function deposit() external payable;
}

/// @title StakeMineVault
/// @notice Reference Pool Launch vault that custodies its token reserve in the Token Dock.
///         "Example A: stake to mine" from the Pool Launch integration guide.
/// @author The Flap Team
///
/// @dev  ── WHAT IT DOES ──────────────────────────────────────────────────────
///
/// The launch hands this vault 80% of the supply (`Distribution.target == VAULT`; the factory enforces
/// it). In `initializeDistribution` the vault deposits ALL of it into the Token Dock via
/// `TokenDockRouter`, so terminals see a labeled reserve instead of one giant unknown holder. It then
/// splits the reserve:
///
///   - 1%  of supply  → dev vesting, linear over `devVestDuration` (pull via `claimDevVested`).
///   - 79% of supply  → a mining pool, emitted linearly over `miningDuration` to stakers, pro-rata to
///                      stake weight (`amount * tier multiplier`). A longer lock earns a higher weight.
///
/// Quote revenue (the VAULT fee slot's share of the tax) is split on arrival:
///
///   - 20% to the dev until the dev has received `devQuoteCap` (1.5x the quote seeded into the pool),
///     pulled with `claimDevQuote`;
///   - the rest to the token's dividend contract for holders (pushed by the permissionless
///     `flushDividends`). After the cap, 100% goes to holders.
///
/// ── TOKEN DOCK USAGE ───────────────────────────────────────────────────────
///
/// Only the RESERVE lives in the dock. Users' staked tokens stay in the vault (they are not a
/// reserve). Every dock call goes through `_getTokenDockRouter()` and the address is never cached:
/// the router moves this vault's balance from the open dock to the verified dock on its own once
/// the Portal whitelists `(vault, token)`, and the vault never sees the switch. Withdrawals are
/// never gated, so stakers and the dev can always be paid.
///
/// ── REVENUE ACCOUNTING ─────────────────────────────────────────────────────
///
/// `receive()` / `sync()` only recognize the balance delta and split it in storage. No external call,
/// no loop, no revert, so it fits the forwarded gas of the tax dispatch. The slow part (wrapping
/// native, depositing into the dividend contract) is `flushDividends()`, which anyone may call.
/// Every quote outflow decrements the baseline through `_spendBaseline`, after the transfer.
///
/// ── KNOWN TRADE-OFFS (for dev reference) ───────────────────────────────────
///
/// - The Portal excludes this vault from the token's dividends, so staked tokens earn no dividends
///   while staked. The mining reward is what they earn instead.
/// - Mining only emits while someone is staked: while `totalWeight == 0` the end of the window is
///   pushed out, so no part of the pool is lost to an empty period.
/// - `rewardRate = miningPool / miningDuration` rounds down; the dust stays in the dock.
contract StakeMineVault is DirectLaunchVaultBase, Initializable, ReentrancyGuardUpgradeable, IStrategy {
    using SafeTransferLib for address;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice One lock option for stakers. `multiplierBps` of 10000 means weight x1.
    struct Tier {
        uint32 lockDuration;
        uint16 multiplierBps;
    }

    /// @notice A staker's position. `amount == 0` means closed.
    struct Position {
        uint128 amount;
        uint128 weight;
        uint64 unlockAt;
        uint256 rewardDebt;
    }

    /// @notice Everything `initialize` needs, grouped to keep stack depth in check.
    struct InitParams {
        address taxToken;
        address quoteToken; // normalized by the factory: WETH for a native launch
        address weth;
        address dev;
        uint256 reserveAmount; // the whole reserve the Portal will hand over
        uint256 devVestAmount; // part of the reserve that vests to the dev
        uint256 devQuoteCap; // total quote the dev may recoup from revenue
        uint32 devVestDuration;
        uint32 miningDuration;
        Tier[] tiers;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constants and storage
    // ─────────────────────────────────────────────────────────────────────────

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAGNITUDE = 2 ** 128;

    /// @notice Share of every revenue lump that goes to the dev while the cap is not reached.
    uint256 public constant DEV_QUOTE_BPS = 2000;

    address public taxToken;
    /// @notice Launch quote, normalized by the factory: a native launch is passed as WETH.
    address public quoteToken;
    address public weth;
    address public dev;

    // ── revenue ──
    /// @notice Recognized-and-not-yet-spent revenue baseline (balance-delta anchor).
    uint256 public accountedQuote;
    uint256 public devQuoteCap;
    /// @notice Lifetime quote credited to the dev (claimed or not).
    uint256 public devPaid;
    /// @notice Credited to the dev and not yet pulled.
    uint256 public devClaimable;
    /// @notice Holder share waiting for `flushDividends`.
    uint256 public pendingDividend;
    uint256 public totalDividendDeposited;

    // ── dev vesting ──
    uint256 public devVestAmount;
    uint256 public devVestStart;
    uint32 public devVestDuration;
    uint256 public devReleased;

    // ── mining ──
    bool public distributionInitialized;
    uint256 public reserveAmount;
    uint256 public miningPool;
    uint32 public miningDuration;
    uint256 public rewardRate; // tokens per second
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public accPerWeight; // scaled by MAGNITUDE
    uint256 public totalWeight;
    uint256 public totalStaked;
    uint256 public totalMined; // lifetime mining rewards paid out

    Tier[] internal _tiers;
    mapping(address => Position[]) internal _positions;

    /// @dev Reserves 50 slots for this contract's own state: 27 used above + 23 spare.
    uint256[23] private __gap;

    // ─────────────────────────────────────────────────────────────────────────
    // Errors and events
    // ─────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error WrongToken(address token);
    error AlreadyInitialized();
    error NotStarted();
    error WrongReserveAmount(uint256 got, uint256 expected);
    error ReceivedLessThanSent(uint256 received, uint256 sent);
    error InvalidTier(uint8 tier);
    error NoSuchPosition(uint256 id);
    error StakeLocked(uint256 unlockAt);
    error NothingToClaim();
    error DividendDepositFailed();

    event FlapStakeMineStaked(address user, uint256 id, uint256 amount, uint8 tier, uint256 weight);
    event FlapStakeMineUnstaked(address user, uint256 id, uint256 amount, uint256 reward);
    event FlapStakeMineClaimed(address user, uint256 id, uint256 reward);
    event FlapStakeMineReserveDocked(uint256 devVest, uint256 miningPool, uint256 rewardRate, uint256 periodFinish);
    event FlapStakeMineRevenue(uint256 amount, uint256 devShare, uint256 holderShare);
    event FlapStakeMineDividendFlushed(address dividend, uint256 amount);
    event FlapStakeMineDevQuoteClaimed(address dev, uint256 amount);
    event FlapStakeMineDevVestedClaimed(address dev, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Called once by the factory inside `newVault`. The Hub is resolved by `_getHub()`.
    function initialize(InitParams calldata c) external initializer {
        __ReentrancyGuard_init();
        if (c.taxToken == address(0) || c.quoteToken == address(0) || c.weth == address(0) || c.dev == address(0)) {
            revert ZeroAddress();
        }
        if (c.devVestAmount >= c.reserveAmount) revert WrongReserveAmount(c.devVestAmount, c.reserveAmount);

        taxToken = c.taxToken;
        quoteToken = c.quoteToken;
        weth = c.weth;
        dev = c.dev;
        reserveAmount = c.reserveAmount;
        devVestAmount = c.devVestAmount;
        devQuoteCap = c.devQuoteCap;
        devVestDuration = c.devVestDuration;
        devVestStart = block.timestamp;
        miningDuration = c.miningDuration;
        for (uint256 i = 0; i < c.tiers.length; ++i) {
            _tiers.push(c.tiers[i]);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reserve: Hub hands it over, vault docks it
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IStrategy
    /// @dev Hub-only, once. Pulls exactly `reserveAmount`, deposits ALL of it into the Token Dock, and
    ///      starts the mining window. `configData` and `salt` are unused.
    function initializeDistribution(address token, uint256 amount, bytes calldata, bytes32)
        external
        override
        onlyHub
        nonReentrant
    {
        if (token != taxToken) revert WrongToken(token);
        if (distributionInitialized) revert AlreadyInitialized();
        if (amount != reserveAmount) revert WrongReserveAmount(amount, reserveAmount);
        distributionInitialized = true;

        uint256 before = IERC20(token).balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert ReceivedLessThanSent(received, amount);

        // Dock the whole reserve. Look the router up now; never cache it.
        address router = _getTokenDockRouter();
        token.safeApprove(router, amount);
        ITokenDock(router).deposit(token, amount);

        uint256 pool = amount - devVestAmount;
        miningPool = pool;
        rewardRate = pool / miningDuration;
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + miningDuration;

        emit FlapDistributionInitialized(token, amount);
        emit FlapStakeMineReserveDocked(devVestAmount, pool, rewardRate, periodFinish);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Staking and mining
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Stake `amount` of the launch token for lock tier `tier`. FoT-safe: credits what arrives.
    function stake(uint256 amount, uint8 tier) external nonReentrant returns (uint256 id) {
        if (amount == 0) revert ZeroAmount();
        if (!distributionInitialized) revert NotStarted();
        if (tier >= _tiers.length) revert InvalidTier(tier);
        _updatePool();

        uint256 before = IERC20(taxToken).balanceOf(address(this));
        taxToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(taxToken).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        Tier memory t = _tiers[tier];
        // Bounded: received <= totalSupply <= 1e33 (< 2^110) and multiplierBps is capped by the factory.
        uint256 weight = received * t.multiplierBps / BPS;
        if (weight == 0) revert ZeroAmount();

        id = _positions[msg.sender].length;
        _positions[msg.sender].push(
            Position({
                amount: uint128(received),
                weight: uint128(weight),
                unlockAt: uint64(block.timestamp + t.lockDuration),
                rewardDebt: FixedPointMathLib.fullMulDivUp(weight, accPerWeight, MAGNITUDE)
            })
        );
        totalWeight += weight;
        totalStaked += received;

        emit FlapStakeMineStaked(msg.sender, id, received, tier, weight);
    }

    /// @notice Claim the mining reward of position `id`. Never blocked by the lock.
    function claim(uint256 id) external nonReentrant returns (uint256 reward) {
        Position storage p = _position(msg.sender, id);
        _updatePool();
        reward = _pending(p);
        if (reward == 0) revert NothingToClaim();
        p.rewardDebt = FixedPointMathLib.fullMulDivUp(p.weight, accPerWeight, MAGNITUDE);
        _payMining(msg.sender, reward);
        emit FlapStakeMineClaimed(msg.sender, id, reward);
    }

    /// @notice Close position `id` after its lock: pays any pending reward and returns the stake.
    function unstake(uint256 id) external nonReentrant returns (uint256 reward) {
        Position storage p = _position(msg.sender, id);
        if (block.timestamp < p.unlockAt) revert StakeLocked(p.unlockAt);
        _updatePool();

        reward = _pending(p);
        uint256 amount = p.amount;
        totalWeight -= p.weight;
        totalStaked -= amount;
        delete _positions[msg.sender][id];

        if (reward != 0) _payMining(msg.sender, reward);
        taxToken.safeTransfer(msg.sender, amount);
        emit FlapStakeMineUnstaked(msg.sender, id, amount, reward);
    }

    /// @notice Mining reward position `id` of `user` could claim right now.
    function pendingReward(address user, uint256 id) external view returns (uint256) {
        if (id >= _positions[user].length) return 0;
        Position storage p = _positions[user][id];
        if (p.amount == 0) return 0;
        uint256 accrued = FixedPointMathLib.fullMulDiv(p.weight, _accNow(), MAGNITUDE);
        return accrued > p.rewardDebt ? accrued - p.rewardDebt : 0;
    }

    function positionsLength(address user) external view returns (uint256) {
        return _positions[user].length;
    }

    function positionOf(address user, uint256 id) external view returns (Position memory) {
        return _positions[user][id];
    }

    function tiers() external view returns (Tier[] memory) {
        return _tiers;
    }

    /// @dev Pay mining rewards out of the dock reserve. Router address looked up on every call.
    function _payMining(address to, uint256 amount) internal {
        totalMined += amount;
        ITokenDock(_getTokenDockRouter()).withdraw(taxToken, amount, to);
    }

    function _position(address user, uint256 id) internal view returns (Position storage p) {
        if (id >= _positions[user].length) revert NoSuchPosition(id);
        p = _positions[user][id];
        if (p.amount == 0) revert NoSuchPosition(id);
    }

    function _pending(Position storage p) internal view returns (uint256) {
        uint256 accrued = FixedPointMathLib.fullMulDiv(p.weight, accPerWeight, MAGNITUDE);
        return accrued > p.rewardDebt ? accrued - p.rewardDebt : 0;
    }

    /// @dev Accumulator projected to `block.timestamp`, without writing.
    function _accNow() internal view returns (uint256 acc) {
        acc = accPerWeight;
        uint256 last = lastUpdate;
        uint256 end = periodFinish;
        if (last == 0 || block.timestamp <= last || last >= end || totalWeight == 0) return acc;
        uint256 upto = block.timestamp < end ? block.timestamp : end;
        acc += FixedPointMathLib.fullMulDiv(rewardRate * (upto - last), MAGNITUDE, totalWeight);
    }

    /// @dev Materialize the accumulator. While nobody is mining, the unfinished window is pushed out by
    ///      the idle time so that no part of the pool is lost. Must run before any weight change.
    function _updatePool() internal {
        uint256 last = lastUpdate;
        if (last == 0 || block.timestamp <= last) return;
        if (totalWeight == 0 && last < periodFinish) {
            periodFinish += block.timestamp - last;
        } else {
            accPerWeight = _accNow();
        }
        lastUpdate = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Quote revenue
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Wake entry: native revenue, and the zero-value ping sent for an ERC-20 quote. Storage
    ///         writes only; never reverts on a normal delta.
    receive() external payable {
        _syncRevenue();
    }

    /// @notice Permissionless poke for revenue that arrived without a wake (donations, direct transfers).
    function sync() external {
        _syncRevenue();
    }

    function _syncRevenue() internal {
        uint256 balance = _quoteBalance();
        uint256 accounted = accountedQuote;
        if (balance <= accounted) return;
        uint256 revenue = balance - accounted;
        accountedQuote = balance;

        uint256 room = devQuoteCap - devPaid; // devPaid never exceeds devQuoteCap
        uint256 devShare = revenue * DEV_QUOTE_BPS / BPS;
        if (devShare > room) devShare = room;
        if (devShare != 0) {
            devPaid += devShare;
            devClaimable += devShare;
        }
        uint256 holderShare = revenue - devShare;
        pendingDividend += holderShare;
        emit FlapStakeMineRevenue(revenue, devShare, holderShare);
    }

    /// @notice Push the holder share into the token's dividend contract. Permissionless; a no-op while
    ///         the token has no dividend shareholders (the amount stays pending).
    function flushDividends() external nonReentrant {
        _syncRevenue();
        uint256 amount = pendingDividend;
        if (amount == 0) return;

        address dividend = ITaxTokenDividend(taxToken).dividendContract();
        if (dividend == address(0) || IDividend(dividend).totalShares() == 0) return;

        pendingDividend = 0;
        totalDividendDeposited += amount;
        // The dividend asset is the quote ERC-20; a native launch's quote is WETH, so wrap first.
        if (_isNative()) IWETH9(weth).deposit{value: amount}();
        quoteToken.safeApproveWithRetry(dividend, amount);
        if (!IDividend(dividend).deposit(amount)) revert DividendDepositFailed();
        _spendBaseline(amount);

        emit FlapStakeMineDividendFlushed(dividend, amount);
    }

    /// @notice Pay the dev its credited quote. Permissionless; always pays `dev`.
    function claimDevQuote() external nonReentrant {
        uint256 amount = devClaimable;
        if (amount == 0) revert NothingToClaim();
        devClaimable = 0;
        if (_isNative()) {
            dev.safeTransferETH(amount);
        } else {
            quoteToken.safeTransfer(dev, amount);
        }
        _spendBaseline(amount);
        emit FlapStakeMineDevQuoteClaimed(dev, amount);
    }

    function _quoteBalance() internal view returns (uint256) {
        return _isNative() ? address(this).balance : IERC20(quoteToken).balanceOf(address(this));
    }

    function _isNative() internal view returns (bool) {
        return quoteToken == weth;
    }

    function _spendBaseline(uint256 amount) internal {
        uint256 accounted = accountedQuote;
        accountedQuote = amount >= accounted ? 0 : accounted - amount;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dev vesting
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Tokens vested to the dev so far (released or not).
    function devVested() public view returns (uint256) {
        if (!distributionInitialized) return 0;
        uint256 elapsed = block.timestamp - devVestStart;
        if (elapsed >= devVestDuration) return devVestAmount;
        return devVestAmount * elapsed / devVestDuration;
    }

    /// @notice Pay the dev its vested, unreleased tokens out of the dock. Permissionless; always pays `dev`.
    function claimDevVested() external nonReentrant {
        uint256 amount = devVested() - devReleased;
        if (amount == 0) revert NothingToClaim();
        devReleased += amount;
        ITokenDock(_getTokenDockRouter()).withdraw(taxToken, amount, dev);
        emit FlapStakeMineDevVestedClaimed(dev, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Discovery
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The vault-side spec revision this implementation conforms to.
    function vaultSpecVersion() public pure returns (string memory) {
        return "pl-v1";
    }

    /// @notice Release version; bump on every beacon upgrade.
    function version() public pure returns (string memory) {
        return "v1.0.0";

        // v1.0.0 - initial stake-to-mine vault with Token Dock custody
    }

    /// @inheritdoc DirectLaunchVaultBase
    function description() public view override returns (string memory) {
        return string.concat(
            "StakeMineVault. Quote revenue: ",
            Strings.toString(DEV_QUOTE_BPS / 100),
            "% to the dev until ",
            Strings.toString(devPaid),
            " / ",
            Strings.toString(devQuoteCap),
            " is paid (1.5x the pool seed), the rest to holders as dividends; 100% to holders after the cap. ",
            "Reserve (held in the Token Dock): ",
            Strings.toString(devVestAmount),
            " tokens vest to the dev linearly (",
            Strings.toString(devReleased),
            " released); ",
            Strings.toString(miningPool),
            " tokens are mined by stakers by lock weight until ",
            Strings.toString(periodFinish),
            " (",
            Strings.toString(totalMined),
            " paid). Staked tokens earn no dividends while staked."
        );
    }

    /// @inheritdoc DirectLaunchVaultBase
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "StakeMineVault";
        schema.description = "Stake the launch token for a lock tier to mine the reserved supply from the Token Dock. "
            "Quote revenue recoups the dev up to a cap, then goes to holders as dividends.";
        schema.methods = new VaultMethodSchema[](7);

        schema.methods[0].name = "stake";
        schema.methods[0].description = "Stake tokens for a lock tier (see tiers()).";
        schema.methods[0].inputs = new FieldDescriptor[](2);
        schema.methods[0].inputs[0] = FieldDescriptor("amount", "uint256", "Amount to stake", 18);
        schema.methods[0].inputs[1] = FieldDescriptor("tier", "uint8", "Lock tier index", 0);
        schema.methods[0].approvals = new ApproveAction[](1);
        schema.methods[0].approvals[0] = ApproveAction("taxToken", "amount");
        schema.methods[0].isWriteMethod = true;

        schema.methods[1].name = "claim";
        schema.methods[1].description = "Claim mined tokens of a position.";
        schema.methods[1].inputs = new FieldDescriptor[](1);
        schema.methods[1].inputs[0] = FieldDescriptor("id", "uint256", "Position id", 0);
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "unstake";
        schema.methods[2].description = "Withdraw a position after its lock; pays pending mined tokens.";
        schema.methods[2].inputs = new FieldDescriptor[](1);
        schema.methods[2].inputs[0] = FieldDescriptor("id", "uint256", "Position id", 0);
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "pendingReward";
        schema.methods[3].description = "Mined tokens a position can claim now.";
        schema.methods[3].inputs = new FieldDescriptor[](2);
        schema.methods[3].inputs[0] = FieldDescriptor("user", "address", "Staker", 0);
        schema.methods[3].inputs[1] = FieldDescriptor("id", "uint256", "Position id", 0);
        schema.methods[3].outputs = new FieldDescriptor[](1);
        schema.methods[3].outputs[0] = FieldDescriptor("amount", "uint256", "Pending mined tokens", 18);
        schema.methods[3].isWriteMethod = false;

        schema.methods[4].name = "flushDividends";
        schema.methods[4].description = "Push the holders' share of quote revenue into the dividend contract.";
        schema.methods[4].isWriteMethod = true;

        schema.methods[5].name = "claimDevQuote";
        schema.methods[5].description = "Pay the dev its credited quote revenue.";
        schema.methods[5].isWriteMethod = true;

        schema.methods[6].name = "claimDevVested";
        schema.methods[6].description = "Pay the dev its vested reserve tokens out of the Token Dock.";
        schema.methods[6].isWriteMethod = true;
    }
}
