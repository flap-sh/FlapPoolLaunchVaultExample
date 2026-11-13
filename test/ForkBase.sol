// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ClonesUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/ClonesUpgradeable.sol";

import {IPortal} from "src/flap/IPortal.sol";
import {ILauncherDescription} from "src/flap/ILauncher.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";
import {ForkAddresses} from "test/ForkAddresses.sol";

interface IProxyAdminLike {
    function owner() external view returns (address);
}

interface IVersioned {
    function version() external view returns (string memory);
}

interface IRouterLike {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ITaxTokenLike {
    function taxProcessor() external view returns (address);
}

interface ITaxProcessorLike {
    function dispatch() external;
    function feeQuoteBalance() external view returns (uint256);
    function marketQuoteBalance() external view returns (uint256);
    function pendingDividendQuoteTokenBalance() external view returns (uint256);
    function lpQuoteBalance() external view returns (uint256);
}

/// @notice What every fork test shares: the live Portal of the chosen chain, funded test accounts, a paused gate to
///         start from, and the helpers to open a factory, mine a salt, trade and dispatch tax.
///
///   The Portal is the deployed one, so nothing about it is mocked: the Hub and Guardian checks in the factories
///   resolve to the real addresses on their own. A concrete test picks an example and a chain; see the files
///   next to this one. Vault reference tests lift the pause to isolate the Vault implementation.
abstract contract ForkBase is Test {
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    IPortal internal portal;
    address internal portalAddr;
    address internal portalImpl;
    bool internal enforcesLauncherGate;
    address internal proxyAdminAddr;
    address internal guardian;
    address internal tokenImpl;
    address internal wbnb;
    address internal v2Router;

    address internal admin;
    // Plain test accounts. `makeAddr` hashes a label to an address that can collide with a live mainnet account:
    // one of them carried EIP-7702 delegation code and forwarded a refund away. These carry no code on BNB Chain.
    address internal creator = address(uint160(0xC0DE0001));
    address internal alice = address(uint160(0xC0DE0002));
    address internal bob = address(uint160(0xC0DE0003));
    address internal trader = address(uint160(0xC0DE0004));

    uint256 internal saltCounter;

    /// @dev The chain this test runs on. Implemented by one thin subclass per chain.
    function _addrs() internal pure virtual returns (ForkAddresses.Addrs memory);

    function setUp() public {
        ForkAddresses.Addrs memory a = _addrs();
        string memory rpcUrl = vm.envOr(a.rpcEnv, string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        require(block.chainid == a.chainId, "the RPC is not the chain this test expects");

        portalAddr = a.portal;
        portalImpl = a.portalImpl;
        enforcesLauncherGate = a.enforcesLauncherGate;
        portal = IPortal(a.portal);
        proxyAdminAddr = a.proxyAdmin;
        guardian = a.guardian;
        tokenImpl = a.tokenImpl;
        wbnb = a.wbnb;
        v2Router = a.v2Router;

        // The factories resolve the Hub and the Guardian from LaunchVaultAddresses at run time. If this table and
        // that registry ever disagree, the tests would be exercising the wrong thing, so fail here instead.
        assertEq(a.portal, LaunchVaultAddresses.hub(), "ForkAddresses.portal != LaunchVaultAddresses.hub()");
        assertEq(
            a.guardian, LaunchVaultAddresses.guardian(), "ForkAddresses.guardian != LaunchVaultAddresses.guardian()"
        );

        admin = IProxyAdminLike(proxyAdminAddr).owner();
        _requirePortalVersion();
        vm.deal(creator, 10 ether);
        vm.deal(alice, 30 ether);
        vm.deal(bob, 30 ether);
        vm.deal(trader, 1000 ether);
        require(
            creator.code.length + alice.code.length + bob.code.length + trader.code.length == 0,
            "test accounts have code"
        );

        // Start every test from the same gate whatever the live state is: creation paused. BNB Chain is paused
        // already, BNB Testnet is open. A paused Portal is what makes "Flap opens the factory" meaningful.
        vm.prank(admin);
        portal.setCreationPaused(true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════════

    function _paused() internal view returns (bool) {
        return portal.featureFlags() & 1 != 0;
    }

    /// @dev The oldest Portal release these tests are written against. `v1.1.2` emits the 4-argument
    ///      `FlapNewLauncherCreated`, serves `description()` without reverting, and judges a recorded Launcher by its
    ///      own factory alone. On an older Portal the description assertions and the gate tests would fail for
    ///      reasons that look like test bugs, so fail here with the reason stated instead. Pin the
    ///      implementation too: the Portal changed on 2026-11-11 without a version bump.
    function _requirePortalVersion() internal view {
        uint256 v = _parseVersion(IVersioned(portalAddr).version());
        require(v >= 1_001_002, "the live Portal predates v1.1.2: description() and the Launcher gate differ");
        address actualImpl = address(uint160(uint256(vm.load(portalAddr, EIP1967_IMPLEMENTATION_SLOT))));
        require(
            actualImpl == portalImpl,
            "the live Portal implementation changed: re-run the suite, then update ForkAddresses.portalImpl"
        );
    }

    function _requireLauncherGate() internal {
        if (!enforcesLauncherGate) vm.skip(true);
    }

    /// @dev "v1.2.3" -> 1_002_003, big enough to order releases and cheap enough to keep in a test base.
    function _parseVersion(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 major;
        uint256 minor;
        uint256 patch;
        uint256 part;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == "v") continue;
            if (b[i] == ".") {
                ++part;
                continue;
            }
            if (b[i] < "0" || b[i] > "9") break;
            if (part == 0) major = major * 10 + (uint8(b[i]) - 48);
            else if (part == 1) minor = minor * 10 + (uint8(b[i]) - 48);
            else if (part == 2) patch = patch * 10 + (uint8(b[i]) - 48);
        }
        return major * 1_000_000 + minor * 1_000 + patch;
    }

    /// @dev A salt whose predicted token address ends in 0x7777, which the Portal requires of every launch. The hash
    ///      is taken in scratch space: `abi.encode` here would grow memory on every candidate and run out of gas.
    function _mineSalt(bytes32 seed) internal returns (bytes32 salt) {
        uint256 start = ++saltCounter << 128;
        for (uint256 i = start;; ++i) {
            assembly ("memory-safe") {
                mstore(0x00, seed)
                mstore(0x20, i)
                salt := keccak256(0x00, 0x40)
            }
            if (uint16(uint160(ClonesUpgradeable.predictDeterministicAddress(tokenImpl, salt, portalAddr))) == 0x7777) {
                return salt;
            }
        }
    }

    function _buy(address token, uint256 bnb) internal {
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = token;
        IRouterLike(v2Router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnb}(
            0, path, trader, block.timestamp + 600
        );
    }

    function _sell(address token, uint256 amount) internal {
        IERC20(token).approve(v2Router, amount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wbnb;
        IRouterLike(v2Router)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, path, trader, block.timestamp + 600);
    }

    function _taxLiquidated(address proc) internal view returns (bool) {
        ITaxProcessorLike t = ITaxProcessorLike(proc);
        return t.feeQuoteBalance() > 0 || t.marketQuoteBalance() > 0 || t.pendingDividendQuoteTokenBalance() > 0
            || t.lpQuoteBalance() > 0;
    }

    /// @dev Trade until the token's tax has been liquidated into its processor, then dispatch it to the fee slots.
    function _generateTaxAndDispatch(address token) internal {
        vm.warp(block.timestamp + 601); // past the anti-farmer / sniper window
        address proc = ITaxTokenLike(token).taxProcessor();
        vm.startPrank(trader);
        _buy(token, 40 ether);
        for (uint256 i; i < 80; ++i) {
            if (_taxLiquidated(proc)) break;
            uint256 sellAmt = IERC20(token).balanceOf(trader) * 30 / 100;
            if (sellAmt == 0) break;
            uint256 before_ = trader.balance;
            _sell(token, sellAmt);
            uint256 proceeds = trader.balance - before_;
            if (proceeds > 0) _buy(token, proceeds * 90 / 100);
        }
        vm.stopPrank();
        assertTrue(_taxLiquidated(proc), "tax never liquidated within the round budget");
        ITaxProcessorLike(proc).dispatch();
    }

    function _openLauncherFactory(address factory) internal {
        vm.prank(admin);
        portal.setLauncherFactoryMultiplier(factory, 10_000, true);
    }

    function _openVaultFactory(address factory) internal {
        vm.prank(admin);
        portal.setVaultFactoryMultiplier(factory, 10_000, true);
    }

    function _unpause() internal {
        vm.prank(admin);
        portal.setCreationPaused(false);
    }

    function _newLauncher(address factory, bytes memory data) internal returns (address launcher) {
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.prank(creator);
        launcher = portal.newLauncher{value: fee}(factory, data);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Event helpers
    // ═════════════════════════════════════════════════════════════════════════

    bytes32 internal constant LAUNCHED_TOPIC = keccak256("FlapDirectLaunched(address,uint8,address,bytes32,bytes)");
    /// @dev `FlapNewLauncherCreated` with the trailing `string description` the Portal adds since `v1.1.2`.
    bytes32 internal constant LAUNCHER_CREATED_TOPIC =
        keccak256("FlapNewLauncherCreated(address,address,address,string)");

    /// @dev The creator the Portal recorded in `FlapDirectLaunched` for `token`.
    function _launchedCreator(Vm.Log[] memory logs, address token) internal view returns (address creator_) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != portalAddr || logs[i].topics.length == 0 || logs[i].topics[0] != LAUNCHED_TOPIC) {
                continue;
            }
            address t;
            (t,, creator_,,) = abi.decode(logs[i].data, (address, uint8, address, bytes32, bytes));
            if (t == token) return creator_;
        }
        revert("FlapDirectLaunched not found for the token");
    }

    /// @dev The `description` the Portal folded into `FlapNewLauncherCreated` for `launcher`.
    function _launcherDescriptionFromLogs(Vm.Log[] memory logs, address launcher)
        internal
        view
        returns (string memory)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != portalAddr || logs[i].topics.length == 0
                    || logs[i].topics[0] != LAUNCHER_CREATED_TOPIC
            ) {
                continue;
            }
            (address emitted,,, string memory description) =
                abi.decode(logs[i].data, (address, address, address, string));
            if (emitted == launcher) return description;
        }
        revert("FlapNewLauncherCreated not found for the launcher");
    }

    /// @dev Display surface of a Launcher: the v1 JSON it renders, and the fact that the Portal folded the very
    ///      same string into `FlapNewLauncherCreated` when it was created.
    function _assertLauncherDescription(
        address launcher,
        string memory name,
        string memory symbol,
        uint256 targetRaise,
        Vm.Log[] memory creationLogs
    ) internal view {
        string memory d = ILauncherDescription(launcher).description();
        assertEq(_launcherDescriptionFromLogs(creationLogs, launcher), d, "the event carries the Launcher's own JSON");
        _assertContains(d, '{"v":1,"name":"', "v1 JSON");
        _assertContains(d, name, "name");
        _assertContains(d, symbol, "symbol");
        _assertContains(d, '"quoteToken":"0x0000000000000000000000000000000000000000"', "native quote");
        _assertContains(d, string.concat('"targetRaise":"', vm.toString(targetRaise), '"'), "targetRaise");
        _assertContains(d, '"poolTokenRatio":"500000000000000000"', "half the supply seeds the pool");
    }

    /// @dev Fails with `label` unless `needle` appears in `haystack`.
    function _assertContains(string memory haystack, string memory needle, string memory label) internal pure {
        require(_contains(haystack, needle), label);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool matched = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
