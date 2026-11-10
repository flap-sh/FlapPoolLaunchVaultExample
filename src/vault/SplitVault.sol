// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";
import {DirectLaunchVaultBase} from "src/flap/DirectLaunchVaultBase.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "src/flap/IVaultSchemas.sol";

/// @title SplitVault
/// @notice Minimal FeeSlotType.VAULT implementation: splits whatever quote value it receives across a
///         fixed list of recipients by bps, tracked per-recipient so a failed transfer to one recipient
///         never blocks the others' claims.
/// @dev Deployed per launch as a solady `UpgradeableBeacon` beacon proxy by SplitVaultFactory (see that
///      contract), so one beacon upgrade retargets the split logic of every already-launched token.
///      Adapted from the production FlapTaxVaults/src/SplitVault.sol (native-BNB push-on-receive,
///      auto-dispatch to recipients) to this repo's pull model: recipients pull their accumulated share
///      via `claim` rather than having it forwarded automatically.
///
///      Revenue-currency detection follows the same `isWeth` semantics TaxProcessorBase itself uses:
///      `quoteToken == weth` means THIS launch is a native-BNB launch (Portal's `QuoteTokenNotAllowed`
///      check makes it impossible to configure a real ERC20-WETH launch — see PortalLaunchSwap.sol's
///      `quoteToken == WETH_ADDRESS` reject), so `quoteToken`/`weth` alone are sufficient to decide
///      which currency to expect; there is no need for two independent accounting buckets. A single
///      balance-delta baseline (`accountedQuote`, mirroring FlapVaultExample's
///      `VaultBaseV3`/`FreeCoinV3Beacon` reference design) covers both cases:
///        - Native BNB (`quoteToken == weth`): `receive()` (any inbound value, including
///          TaxProcessorBase._dispatchOneWalletETH's `call{value: amount}("")`) triggers recognition.
///        - ERC20 (`quoteToken` is the real token): a plain `safeTransfer` triggers no callback here, so
///          recognition happens on the next wake — either the zero-value "ping" TaxProcessorBase's
///          `_dispatchOneWalletERC20` sends to every contract recipient after its transfer, or an
///          explicit call to `sync()` (e.g. a donation/direct transfer that arrived without a ping).
contract SplitVault is DirectLaunchVaultBase, Initializable {
    using SafeTransferLib for address;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    struct Recipient {
        address recipient;
        uint16 bps;
    }

    uint256 internal constant TOTAL_BPS = 10000;

    address public taxToken;
    address public quoteToken;
    /// @notice The chain's canonical WETH address, passed through from SplitVaultFactory at deploy
    ///         time (same immutable-at-construction pattern as TaxProcessorBaseStorage.weth) — needed
    ///         because this contract has no other way to learn "is `quoteToken` actually native BNB".
    address public weth;
    Recipient[] public recipients;
    mapping(address => uint256) public claimable;
    mapping(address => uint256) public claimed;

    /// @notice Recognized-and-not-yet-claimed revenue baseline (balance-delta accounting anchor, see
    ///         this contract's top-of-file natspec). Only recognized revenue is claimable.
    uint256 public accountedQuote;

    error NoRecipients();
    error TooManyRecipients();
    error ZeroRecipient();
    error DuplicateRecipient();
    error InvalidBpsSum();
    error NothingToClaim();

    event FlapSplitVaultReceived(uint256 amount);
    event FlapSplitVaultClaimed(address recipient, uint256 amount);

    /// @notice Wake entry point. Invoked by native BNB transfers (including
    ///         TaxProcessorBase._dispatchOneWalletETH) AND by _dispatchOneWalletERC20's zero-value
    ///         ERC20 ping. Lightweight by design so it comfortably fits the ping's forwarded gas.
    receive() external payable {
        _syncRevenue();
    }

    /// @notice Public poke: recognize any revenue that arrived without a wake (donations, direct ERC20
    ///         transfers that landed before a ping). Safe to call at any time — a zero-delta sync is a
    ///         silent no-op.
    function sync() external {
        _syncRevenue();
    }

    function initialize(address taxToken_, address quoteToken_, address weth_, Recipient[] calldata recipients_)
        external
        initializer
    {
        if (recipients_.length == 0) revert NoRecipients();
        if (recipients_.length > 10) revert TooManyRecipients();

        uint256 totalBps;
        for (uint256 i = 0; i < recipients_.length; i++) {
            if (recipients_[i].recipient == address(0)) revert ZeroRecipient();
            for (uint256 j = 0; j < i; j++) {
                if (recipients_[i].recipient == recipients_[j].recipient) revert DuplicateRecipient();
            }
            totalBps += recipients_[i].bps;
            recipients.push(recipients_[i]);
        }
        if (totalBps != TOTAL_BPS) revert InvalidBpsSum();

        taxToken = taxToken_;
        quoteToken = quoteToken_;
        weth = weth_;
    }

    /// @notice Release version of this vault implementation.
    /// @dev Per-launch vaults are solady `UpgradeableBeacon` beacon proxies, so reading `version()` on
    ///      a live vault tells you which release its beacon currently points at. Bump this on every
    ///      implementation change pushed through `UpgradeableBeacon.upgradeTo` and append a changelog
    ///      line below (mirrors `Dividend.version` / `TaxProcessorBase.version`).
    function version() public pure virtual returns (string memory) {
        return "v1.0.0";

        // v1.0.0 - initial beacon-upgradeable split vault
    }

    /// @dev Balance-delta recognition: read the current quote balance; `balance <= accountedQuote` is a
    ///      silent no-op (idempotency — the ping may fire more than once, or with nothing new to
    ///      report); otherwise advance the baseline and credit the delta to every recipient by bps.
    function _syncRevenue() internal {
        uint256 balance = _quoteBalance();
        if (balance <= accountedQuote) return;
        uint256 newRevenue = balance - accountedQuote;
        accountedQuote = balance;
        _credit(newRevenue);
    }

    /// @dev Current balance in this vault's revenue currency — native if `quoteToken == weth` (see
    ///      top-of-file natspec for why that equality alone is a reliable native/ERC20 signal),
    ///      otherwise the ERC20 balance of `quoteToken` itself.
    function _quoteBalance() internal view returns (uint256) {
        return _isNative() ? address(this).balance : IERC20(quoteToken).balanceOf(address(this));
    }

    /// @dev `quoteToken` is always the ALREADY-NORMALIZED launch quote (see IDirectLaunchVaultFactory.newVault's
    ///      natspec) — a genuine ERC20-WETH launch is unreachable (PortalLaunchSwap rejects
    ///      `quoteToken == WETH_ADDRESS` as an input token), so this equality is unambiguous.
    function _isNative() internal view returns (bool) {
        return quoteToken == weth;
    }

    function _credit(uint256 amount) internal {
        uint256 distributed;
        uint256 n = recipients.length;
        for (uint256 i = 0; i < n - 1; i++) {
            uint256 share = (amount * recipients[i].bps) / TOTAL_BPS;
            claimable[recipients[i].recipient] += share;
            distributed += share;
        }
        // Remainder (rounding dust) goes to the last recipient.
        claimable[recipients[n - 1].recipient] += amount - distributed;

        emit FlapSplitVaultReceived(amount);
    }

    /// @notice Claim the caller's full claimable balance in this vault's revenue currency.
    /// @dev Effects (clearing claimable/claimed) are fully settled BEFORE the external transfer runs
    ///      (checks-effects-interactions) — a malicious recipient contract reentering from `receive()`
    ///      during the native-BNB payout observes a zeroed claimable balance and reverts with
    ///      `NothingToClaim`, so double-claiming is not possible (the single-bucket model preserves
    ///      the same guarantee as the previous two-bucket design).
    function claim() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender] = 0;
        claimed[msg.sender] += amount;

        if (_isNative()) {
            msg.sender.safeTransferETH(amount);
        } else {
            quoteToken.safeTransfer(msg.sender, amount);
        }

        // Lower the revenue baseline AFTER the payout. A notify-before-debit token lets
        // the recipient reenter `sync()` during the transfer; with the anchor still including
        // `amount` at hook time, `balance <= accountedQuote` holds and the reentrant sync is a no-op
        // instead of booking the in-flight payout as fresh revenue. (The native path already debits
        // before `receive()`, so it was never affected.)
        accountedQuote -= amount;

        emit FlapSplitVaultClaimed(msg.sender, amount);
    }

    function recipientsLength() external view returns (uint256) {
        return recipients.length;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IDirectLaunchVault
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc DirectLaunchVaultBase
    function description() public view override returns (string memory) {
        uint256 n = recipients.length;
        string memory list;
        for (uint256 i = 0; i < n; ++i) {
            list = string.concat(
                list,
                i == 0 ? "" : "; ",
                Strings.toHexString(recipients[i].recipient),
                "=",
                Strings.toString(recipients[i].bps),
                "bps"
            );
        }
        return string.concat(
            "SplitVault: 100% of this vault's quote revenue is split across ",
            Strings.toString(n),
            " recipients, no fee: ",
            list,
            "; each recipient pulls its share via claim()."
        );
    }

    /// @inheritdoc DirectLaunchVaultBase
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "SplitVault";
        schema.description = "Split the launch's quote revenue across a fixed recipient list by bps; "
            "each recipient pulls its accumulated share via claim().";
        schema.methods = new VaultMethodSchema[](4);

        // claimable(address) -> uint256
        schema.methods[0].name = "claimable";
        schema.methods[0].description = "Quote claimable by a recipient right now.";
        schema.methods[0].inputs = new FieldDescriptor[](1);
        schema.methods[0].inputs[0] = FieldDescriptor("recipient", "address", "Recipient address", 0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable quote", 18);
        schema.methods[0].isWriteMethod = false;

        // claimed(address) -> uint256
        schema.methods[1].name = "claimed";
        schema.methods[1].description = "Lifetime quote claimed by a recipient.";
        schema.methods[1].inputs = new FieldDescriptor[](1);
        schema.methods[1].inputs[0] = FieldDescriptor("recipient", "address", "Recipient address", 0);
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("amount", "uint256", "Lifetime claimed quote", 18);
        schema.methods[1].isWriteMethod = false;

        // recipients(uint256) -> (address, uint16)
        schema.methods[2].name = "recipients";
        schema.methods[2].description = "A configured recipient and its bps share.";
        schema.methods[2].inputs = new FieldDescriptor[](1);
        schema.methods[2].inputs[0] = FieldDescriptor("index", "uint256", "Recipient index", 0);
        schema.methods[2].outputs = new FieldDescriptor[](2);
        schema.methods[2].outputs[0] = FieldDescriptor("recipient", "address", "Recipient address", 0);
        schema.methods[2].outputs[1] = FieldDescriptor("bps", "uint16", "Share in bps", 0);
        schema.methods[2].isWriteMethod = false;

        // claim()
        schema.methods[3].name = "claim";
        schema.methods[3].description = "Claim the caller's accumulated quote share.";
        schema.methods[3].isWriteMethod = true;
    }
}
