// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {IPortalTypes} from "src/flap/IPortal.sol";
import {Distribution} from "src/flap/Distribution.sol";
import {CrowdLauncher, CrowdConfig} from "src/launcher-vault/CrowdLauncher.sol";
import {CrowdLauncherFactory} from "src/launcher-vault/CrowdLauncherFactory.sol";
import {CrowdVault} from "src/launcher-vault/CrowdVault.sol";
import {CrowdVaultFactory} from "src/launcher-vault/CrowdVaultFactory.sol";
import {ForkBase} from "test/ForkBase.sol";

/// @notice MODE: a Launcher paired with a Vault. `CrowdLauncher` raises BNB from many contributors and launches; the
///         paired `CrowdVault` then shares the token's tax revenue between the contributors and the creator.
///
///   What Flap does for you: open the Launcher factory. Since Portal `v1.1.2` a recorded Launcher is covered by its
///   own factory alone, so the paired Vault factory does NOT have to be enabled for the launch to go through — its
///   enabled flag only sets the liquidity-floor multiplier. The first two tests pin both directions: the Launcher
///   factory alone is enough, and a disabled one blocks the launch even with the Vault side open. Then the real flow,
///   with the launch, trading, tax and every claim on a live Portal.
abstract contract CrowdFork is ForkBase {
    /// @dev `PortalErrorsLib.CreationPaused()`, the Portal's revert for a launch it does not let through.
    bytes4 private constant CREATION_PAUSED = bytes4(keccak256("CreationPaused()"));

    CrowdVaultFactory internal crowdVaultFactory;
    CrowdLauncherFactory internal crowdLauncherFactory;

    function _deployCrowdPair() internal {
        uint256 nonce = vm.getNonce(address(this));
        address predictedLauncherFactory = vm.computeCreateAddress(address(this), nonce + 1);
        crowdVaultFactory = new CrowdVaultFactory(predictedLauncherFactory);
        crowdLauncherFactory = new CrowdLauncherFactory(address(crowdVaultFactory));
        assertEq(address(crowdLauncherFactory), predictedLauncherFactory, "address prediction held");
    }

    function _crowdConfig(bytes32 seed) internal returns (CrowdConfig memory c) {
        c.name = "Crowd Example";
        c.symbol = "CROWDX";
        c.meta = "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq";
        c.salt = _mineSalt(seed);
        c.targetRaise = 10 ether;
        c.saleDuration = 1 days;
        c.vaultFactory = address(crowdVaultFactory);
        c.contributorBps = 6000;
    }

    /// @dev Portal `v1.1.2` and later: a recorded Launcher is judged by its own LauncherFactory alone. The launch
    ///      carries a VAULT slot, but that slot's VaultFactory does not have to be enabled, so opening only the
    ///      Launcher side is enough.
    function test_05_crowd_launcherFactoryAloneCoversTheLaunch() public {
        _deployCrowdPair();
        _openLauncherFactory(address(crowdLauncherFactory));

        CrowdLauncher launcher = CrowdLauncher(
            payable(_newLauncher(address(crowdLauncherFactory), abi.encode(_crowdConfig("crowd-one-side"))))
        );
        vm.prank(alice);
        launcher.contribute{value: 3 ether}();

        vm.prank(bob);
        launcher.contribute{value: 7 ether}();
        assertTrue(launcher.launched(), "the LauncherFactory's enabled flag alone covers the launch");
        assertTrue(launcher.token() != address(0), "the token exists");
    }

    /// @dev The other direction: with the Vault side open, a recorded Launcher whose own factory is disabled stays
    ///      blocked, and enabling it again lets the very same Launcher complete.
    function test_05b_crowd_disabledLauncherFactoryStaysBlocked() public {
        _requireLauncherGate();
        _deployCrowdPair();
        _openLauncherFactory(address(crowdLauncherFactory));
        _openVaultFactory(address(crowdVaultFactory));

        CrowdLauncher launcher = CrowdLauncher(
            payable(_newLauncher(address(crowdLauncherFactory), abi.encode(_crowdConfig("crowd-launcher-off"))))
        );
        vm.prank(alice);
        launcher.contribute{value: 3 ether}();

        // Launcher side closed -> a recorded Launcher whose factory is off is blocked, whatever the Vault says.
        vm.prank(admin);
        portal.setLauncherFactoryMultiplier(address(crowdLauncherFactory), 10_000, false);

        vm.prank(bob);
        vm.expectRevert(CREATION_PAUSED);
        launcher.contribute{value: 7 ether}();
        assertFalse(launcher.launched(), "still unlaunched while the LauncherFactory is off");

        // Turning it back on lets the same Launcher finish.
        vm.prank(admin);
        portal.setLauncherFactoryMultiplier(address(crowdLauncherFactory), 10_000, true);
        vm.prank(bob);
        launcher.contribute{value: 7 ether}();
        assertTrue(launcher.launched(), "launch succeeds once the LauncherFactory is enabled");
    }

    function test_06_crowd_fullJourney_launchTradingAndEveryClaim() public {
        _deployCrowdPair();
        _openLauncherFactory(address(crowdLauncherFactory));
        _openVaultFactory(address(crowdVaultFactory));

        CrowdConfig memory c = _crowdConfig("crowd-journey");
        vm.recordLogs();
        CrowdLauncher launcher = CrowdLauncher(payable(_newLauncher(address(crowdLauncherFactory), abi.encode(c))));
        Vm.Log[] memory creation = vm.getRecordedLogs();
        assertEq(
            portal.getLauncher(address(launcher)).launcherFactory,
            address(crowdLauncherFactory),
            "Portal recorded the Launcher"
        );

        // Display-only surface: the v1 JSON the Launcher renders, mirrored into the creation event.
        _assertLauncherDescription(address(launcher), c.name, c.symbol, c.targetRaise, creation);

        vm.prank(alice);
        launcher.contribute{value: 3 ether}();
        vm.recordLogs();
        vm.prank(bob);
        launcher.contribute{value: 7 ether}();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(launcher.launched(), "launched");
        address token = launcher.token();

        // The Portal recorded which Vault belongs to the token, and the Vault serves this very Launcher.
        (address vaultAddr, address vaultFactoryAddr) = portal.getLaunchVault(token);
        assertEq(vaultFactoryAddr, address(crowdVaultFactory), "the vault came from the paired factory");
        CrowdVault vault = CrowdVault(payable(vaultAddr));
        assertEq(vault.launcher(), address(launcher), "the vault serves this launcher");
        assertEq(vault.creator(), creator, "the vault pays the creator it was created for");

        // FlapDirectLaunched shows the user who started the sale, not the Launcher contract. (The vault creation
        // event is not asserted here: the deployed Portal predates it. The contract repo's own fork test covers it.)
        assertEq(_launchedCreator(logs, token), creator, "FlapDirectLaunched shows the user");

        // Token claims.
        vm.prank(alice);
        launcher.claim();
        vm.prank(bob);
        launcher.claim();
        uint256 reserved = launcher.TOTAL_SUPPLY() - launcher.POOL_TOKEN();
        assertEq(IERC20(token).balanceOf(alice), reserved * 3 / 10, "alice 30% of the reserve");
        assertEq(IERC20(token).balanceOf(bob), reserved * 7 / 10, "bob 70% of the reserve");

        // Real trading generates tax; the VAULT slot's share reaches the Vault in native BNB.
        uint256 vaultBefore = vaultAddr.balance;
        _generateTaxAndDispatch(token);
        uint256 revenue = vaultAddr.balance - vaultBefore;
        assertGt(revenue, 0, "the VAULT slot paid the Vault");

        // Everyone pulls their own share: contributors 60% pro rata (30/70), the creator the other 40%.
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        uint256 creatorBefore = creator.balance;
        vm.prank(alice);
        vault.claim();
        vm.prank(bob);
        vault.claim();
        vm.prank(creator);
        vault.claim();

        uint256 pool = revenue * 6000 / 10_000;
        assertEq(alice.balance - aliceBefore, pool * 3 / 10, "alice's revenue share");
        assertEq(bob.balance - bobBefore, pool * 7 / 10, "bob's revenue share");
        assertEq(creator.balance - creatorBefore, revenue - pool, "the creator's revenue share");
        assertApproxEqAbs(vaultAddr.balance, 0, 2, "the vault is paid out");
    }

    function test_07a_crowd_pausedPortalBlocksAStrangerBeforeTheVaultFactory() public {
        _requireLauncherGate();
        _deployCrowdPair();
        _openVaultFactory(address(crowdVaultFactory));
        IPortalTypes.CreateTaxTokenParams memory p = _strangerParams();

        vm.expectRevert(CREATION_PAUSED);
        this.launchStranger(p);
    }

    function test_07b_crowd_theVaultFactoryRefusesAStrangerLauncher() public {
        _deployCrowdPair();
        _unpause();
        IPortalTypes.CreateTaxTokenParams memory p = _strangerParams();

        vm.expectRevert(abi.encodeWithSelector(CrowdVaultFactory.NotFromLauncherFactory.selector, creator));
        this.launchStranger(p);
    }

    /// @dev Mine the salt before setting an expected revert or entering the external launch helper.
    function _strangerParams() internal returns (IPortalTypes.CreateTaxTokenParams memory p) {
        // A launch that names the Crowd vault factory from a caller the Portal never recorded as its Launcher.
        IPortalTypes.FeeConfig[] memory fees = new IPortalTypes.FeeConfig[](2);
        fees[0] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.VAULT,
            bps: 8000,
            configData: abi.encode(
                IPortalTypes.FeeConfigVault({
                    vaultFactory: address(crowdVaultFactory), vaultData: abi.encode(creator, uint16(6000))
                })
            )
        });
        fees[1] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 2000, configData: ""});

        p.name = "Stranger";
        p.symbol = "STR";
        p.meta = "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq";
        p.totalSupply = 1_000_000 ether;
        p.salt = _mineSalt("crowd-stranger");
        p.poolQuote = 10 ether;
        p.poolToken = 1_000_000 ether;
        p.buyTaxRate = 300;
        p.sellTaxRate = 500;
        p.taxDuration = 30 days;
        p.antiFarmerDuration = 1 days;
        p.feeConfigs = fees;
    }

    /// @dev Keep the Portal call separate so the expected revert belongs to the launch.
    function launchStranger(IPortalTypes.CreateTaxTokenParams calldata p) external {
        require(msg.sender == address(this), "test helper only");
        Distribution memory d;
        IPortalTypes.CreatorBuyParams memory noBuy;

        vm.prank(creator);
        portal.launchTaxTokenV2{value: 10 ether}(p, d, noBuy);
    }
}
