// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";
import {DirectLaunchVaultBase} from "src/flap/DirectLaunchVaultBase.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "src/flap/IVaultSchemas.sol";

/// @dev Bounds on the contributors' share of the vault's revenue. Shared by the vault and its factory.
uint16 constant CROWD_MIN_CONTRIBUTOR_BPS = 1000;
uint16 constant CROWD_MAX_CONTRIBUTOR_BPS = 9000;

/// @notice The slice of `CrowdLauncher` the vault reads.
interface ICrowdLauncher {
    function creator() external view returns (address);
    function targetRaise() external view returns (uint256);
    function raised() external view returns (uint256);
    function contributions(address account) external view returns (uint256);
}

/// @title CrowdVault
/// @notice Revenue-sharing vault for a crowd-funded launch. The launch's VAULT slot pays native BNB here;
///         `contributorBps` of it goes to the contributors in proportion to what each put into the
///         Launcher, and the rest goes to the creator.
///
///         Money flow:
///           tax dispatch ──► receive() ──► totalRevenue grows (balance-delta accounting)
///           claim():  contributor share = totalRevenue × contributorBps ÷ 10000 × contribution ÷ targetRaise
///                     creator share     = totalRevenue − contributors' pool
///                     paid = entitled − claimed
///
///         Contributions are read from the Launcher. They cannot change after the launch: the Launcher
///         only launches once `raised == targetRaise`, and from then on it accepts no contribution and
///         allows no refund. So the split is fixed from the first wei of revenue.
///
/// @dev Native BNB only. Deployed per launch as a beacon proxy by `CrowdVaultFactory`.
contract CrowdVault is DirectLaunchVaultBase, Initializable {
    using SafeTransferLib for address;
    using Strings for uint256;

    uint16 public constant TOTAL_BPS = 10_000;

    address public taxToken;
    /// @notice The Launcher whose contributions define the split.
    address public launcher;
    /// @notice The end user who created the Launcher; receives the non-contributor share.
    address public creator;
    uint256 public targetRaise;
    uint16 public contributorBps;

    /// @notice Revenue recognized so far (everything this vault ever received).
    uint256 public totalRevenue;
    /// @notice Total paid out.
    uint256 public totalPaid;
    mapping(address account => uint256 amount) public claimed;

    error ZeroAddress();
    error InvalidContributorBps(uint256 bps);
    error LauncherNotFunded(uint256 raised, uint256 target);
    error NothingToClaim();

    event RevenueRecognized(uint256 amount, uint256 totalRevenue);
    event Claimed(address indexed account, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Called once by the factory in `newVault`, in the same transaction that deploys the proxy.
    function initialize(address taxToken_, address launcher_, uint16 contributorBps_) external initializer {
        if (taxToken_ == address(0) || launcher_ == address(0)) revert ZeroAddress();
        if (contributorBps_ < CROWD_MIN_CONTRIBUTOR_BPS || contributorBps_ > CROWD_MAX_CONTRIBUTOR_BPS) {
            revert InvalidContributorBps(contributorBps_);
        }
        ICrowdLauncher l = ICrowdLauncher(launcher_);
        uint256 target = l.targetRaise();
        uint256 raised = l.raised();
        if (target == 0 || raised != target) revert LauncherNotFunded(raised, target);

        taxToken = taxToken_;
        launcher = launcher_;
        creator = l.creator();
        targetRaise = target;
        contributorBps = contributorBps_;
        if (creator == address(0)) revert ZeroAddress();
    }

    receive() external payable {
        _sync();
    }

    /// @notice Recognize revenue that arrived without a wake (for example a direct transfer).
    function sync() external {
        _sync();
    }

    function version() external pure returns (string memory) {
        return "v1.0.0";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Accounting
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Revenue = balance + paid. A payout lowers the balance and raises `totalPaid` by the same amount,
    ///      so paying out never looks like new revenue, even if a recipient re-enters `sync()`.
    function _sync() internal {
        uint256 seen = address(this).balance + totalPaid;
        if (seen <= totalRevenue) return;
        emit RevenueRecognized(seen - totalRevenue, seen);
        totalRevenue = seen;
    }

    function _revenueNow() internal view returns (uint256 rev) {
        rev = totalRevenue;
        uint256 seen = address(this).balance + totalPaid;
        if (seen > rev) rev = seen;
    }

    /// @notice Total this account is entitled to from all revenue so far.
    function entitled(address account) public view returns (uint256 amount) {
        uint256 rev = _revenueNow();
        uint256 pool = rev * contributorBps / TOTAL_BPS;
        amount = pool * ICrowdLauncher(launcher).contributions(account) / targetRaise;
        if (account == creator) amount += rev - pool;
    }

    /// @notice What `account` can claim right now.
    function claimable(address account) public view returns (uint256) {
        uint256 e = entitled(account);
        uint256 c = claimed[account];
        return e > c ? e - c : 0;
    }

    /// @notice Pay the caller everything claimable.
    function claim() external {
        _sync();
        uint256 amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim();

        claimed[msg.sender] += amount;
        totalPaid += amount;
        msg.sender.safeTransferETH(amount);
        emit Claimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IDirectLaunchVault
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc DirectLaunchVaultBase
    function description() public view override returns (string memory) {
        return string.concat(
            "CrowdVault: native BNB revenue is shared ",
            uint256(contributorBps).toString(),
            "/10000 among the contributors of launcher ",
            Strings.toHexString(launcher),
            " in proportion to their contribution, and the rest goes to the creator ",
            Strings.toHexString(creator),
            ". Recognized revenue: ",
            totalRevenue.toString(),
            " wei. Each party pulls its share with claim()."
        );
    }

    /// @inheritdoc DirectLaunchVaultBase
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "CrowdVault";
        schema.description = "Revenue share for a crowd-funded launch: contributors split a fixed share pro rata, the creator "
            "gets the rest. Everyone pulls their own share with claim().";
        schema.methods = new VaultMethodSchema[](3);

        schema.methods[0].name = "claimable";
        schema.methods[0].description = "BNB the account can claim right now.";
        schema.methods[0].inputs = new FieldDescriptor[](1);
        schema.methods[0].inputs[0] = FieldDescriptor("account", "address", "Contributor or creator", 0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable BNB", 18);

        schema.methods[1].name = "totalRevenue";
        schema.methods[1].description = "Revenue recognized by the vault so far.";
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("amount", "uint256", "Total BNB received", 18);

        schema.methods[2].name = "claim";
        schema.methods[2].description = "Claim the caller's share.";
        schema.methods[2].isWriteMethod = true;
    }
}
