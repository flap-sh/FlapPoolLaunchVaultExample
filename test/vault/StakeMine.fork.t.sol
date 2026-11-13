// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {IPortalTypes} from "src/flap/IPortal.sol";
import {Distribution, DistributionTarget} from "src/flap/Distribution.sol";
import {ITokenDockRouter} from "src/flap/ILaunchVaultSpec.sol";
import {LaunchVaultAddresses} from "src/flap/LaunchVaultAddresses.sol";
import {StakeMineVault} from "src/vault/StakeMineVault.sol";
import {StakeMineVaultFactory} from "src/vault/StakeMineVaultFactory.sol";
import {ForkBase} from "test/ForkBase.sol";

/// @notice VAULT REFERENCE, not a launch mode: `StakeMineVault` is handed 80% of the supply, docks all of
///         it in the Token Dock, vests 1% to the dev and mines the rest to stakers; the tax revenue is split between
///         the dev and the token's holders.
///
///   `_unpause` only isolates the vault; the beta requires a Launcher for an actual launch. The launch must be
///   shaped exactly as the factory demands (VAULT distribution target, 80% reserve, 20% in the pool); the first test
///   shows what a launch that is not is told.
abstract contract StakeMineFork is ForkBase {
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant RESERVE = SUPPLY * 8000 / 10_000;
    uint256 internal constant POOL_TOKEN = SUPPLY - RESERVE;
    uint256 internal constant POOL_QUOTE = 10 ether; // above the creation floor at a 20% pool share

    StakeMineVaultFactory internal factory;

    function _deploy() internal {
        factory = new StakeMineVaultFactory(wbnb);
    }

    function _params(bytes32 seed, uint256 poolToken) internal returns (IPortalTypes.CreateTaxTokenParams memory p) {
        IPortalTypes.FeeConfig[] memory fees = new IPortalTypes.FeeConfig[](3);
        fees[0] = IPortalTypes.FeeConfig({feeType: IPortalTypes.FeeSlotType.DEFLATION, bps: 1000, configData: ""});
        fees[1] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.VAULT,
            bps: 7500,
            configData: abi.encode(IPortalTypes.FeeConfigVault({vaultFactory: address(factory), vaultData: ""}))
        });
        // The vault pays the holders' share into the token's dividend tracker, so a DIVIDEND slot must pay in the quote.
        fees[2] = IPortalTypes.FeeConfig({
            feeType: IPortalTypes.FeeSlotType.DIVIDEND,
            bps: 1500,
            configData: abi.encode(
                IPortalTypes.FeeConfigDividend({dividendToken: address(0), minimumShareBalance: SUPPLY / 1000})
            )
        });

        p.name = "StakeMine Example";
        p.symbol = "SMINEX";
        p.meta = "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq";
        p.totalSupply = SUPPLY;
        p.salt = _mineSalt(seed);
        p.poolQuote = POOL_QUOTE;
        p.poolToken = poolToken;
        p.buyTaxRate = 300;
        p.sellTaxRate = 500;
        p.taxDuration = 30 days;
        p.antiFarmerDuration = 1 days;
        p.feeConfigs = fees;
    }

    function _toVault() internal pure returns (Distribution memory d) {
        d = Distribution({
            target: DistributionTarget.VAULT, strategy: address(0), amount: uint128(RESERVE), configData: ""
        });
    }

    function _launch(bytes32 seed) internal returns (address token, StakeMineVault vault) {
        _unpause();
        IPortalTypes.CreateTaxTokenParams memory p = _params(seed, POOL_TOKEN);
        Distribution memory d = _toVault();
        IPortalTypes.CreatorBuyParams memory noBuy;
        vm.prank(creator);
        (token,) = portal.launchTaxTokenV2{value: POOL_QUOTE}(p, d, noBuy);
        (address vaultAddr,) = portal.getLaunchVault(token);
        vault = StakeMineVault(payable(vaultAddr));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // The launch shape the factory demands
    // ═════════════════════════════════════════════════════════════════════════

    function test_09_stakemine_aLaunchThatDoesNotHandOverTheReserveIsRefused() public {
        _deploy();
        _unpause();
        IPortalTypes.CreateTaxTokenParams memory p = _params("stakemine-bad-shape", SUPPLY);
        Distribution memory none; // the whole supply goes into the pool and nothing is handed to the vault
        IPortalTypes.CreatorBuyParams memory noBuy;

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(StakeMineVaultFactory.WrongDistributionTarget.selector, DistributionTarget.NONE)
        );
        portal.launchTaxTokenV2{value: POOL_QUOTE}(p, none, noBuy);
    }

    function test_09b_stakemine_aLaunchWithoutADividendSlotIsRefused() public {
        _deploy();
        _unpause();
        IPortalTypes.CreateTaxTokenParams memory p = _params("stakemine-no-dividend", POOL_TOKEN);
        // Drop the DIVIDEND slot: the holders' share would have nowhere to go.
        IPortalTypes.FeeConfig[] memory fees = new IPortalTypes.FeeConfig[](2);
        fees[0] = p.feeConfigs[0];
        fees[1] = p.feeConfigs[1];
        fees[1].bps = 9000;
        p.feeConfigs = fees;
        Distribution memory d = _toVault();
        IPortalTypes.CreatorBuyParams memory noBuy;

        vm.prank(creator);
        vm.expectRevert(StakeMineVaultFactory.MissingDividendSlot.selector);
        portal.launchTaxTokenV2{value: POOL_QUOTE}(p, d, noBuy);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Launch, dock, stake and mine, revenue, dev vesting
    // ═════════════════════════════════════════════════════════════════════════

    // The journey is one story told in four steps; the state they share lives in storage to keep each step small.
    address internal jToken;
    StakeMineVault internal jVault;
    uint256 internal aliceStake;
    uint256 internal bobStake;
    uint256 internal aliceId;
    uint256 internal bobId;

    function test_10_stakemine_fullJourney() public {
        _deploy();
        (jToken, jVault) = _launch("stakemine-journey");
        _stepLaunchAndDock();
        _stepStake();
        _stepMine();
        _stepUnstakeAndDevVest();
    }

    /// @dev The Portal recorded the vault, and the whole reserve sits in the Token Dock, none of it in the vault.
    function _stepLaunchAndDock() internal {
        (, address vaultFactoryAddr) = portal.getLaunchVault(jToken);
        assertEq(vaultFactoryAddr, address(factory), "the vault came from this factory");
        assertEq(jVault.taxToken(), jToken);
        assertEq(jVault.dev(), creator, "the dev is the launch caller");

        ITokenDockRouter router = ITokenDockRouter(LaunchVaultAddresses.tokenDockRouter());
        assertEq(router.balanceOf(jToken, address(jVault)), RESERVE, "the full reserve is docked");
        assertEq(IERC20(jToken).balanceOf(address(jVault)), 0, "the vault holds no loose tokens");
        // Until Flap whitelists the pair, the reserve sits in the OPEN dock; the vault never sees the switch later.
        assertEq(
            router.dockFor(address(jVault), jToken), LaunchVaultAddresses.openTokenDock(), "reserve is in the open dock"
        );
        assertTrue(jVault.distributionInitialized(), "the Portal handed the reserve over");
        assertEq(jVault.miningPool(), RESERVE - jVault.devVestAmount(), "mining pool = reserve - dev vest");
    }

    /// @dev alice stakes in the longest tier, bob in the shortest. Both buy tokens on the real pool first.
    function _stepStake() internal {
        vm.warp(block.timestamp + 601);
        _buyFor(jToken, alice, 5 ether);
        _buyFor(jToken, bob, 5 ether);
        aliceStake = IERC20(jToken).balanceOf(alice);
        bobStake = IERC20(jToken).balanceOf(bob);
        assertGt(aliceStake, 0);
        assertGt(bobStake, 0);

        vm.startPrank(alice);
        IERC20(jToken).approve(address(jVault), aliceStake);
        aliceId = jVault.stake(aliceStake, 2); // 180 days, x2
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(jToken).approve(address(jVault), bobStake);
        bobId = jVault.stake(bobStake, 0); // 30 days, x1
        vm.stopPrank();

        assertEq(jVault.positionOf(alice, aliceId).weight, aliceStake * 2, "the 180-day tier weighs x2");
        assertEq(jVault.positionOf(bob, bobId).weight, bobStake, "the 30-day tier weighs x1");
    }

    /// @dev Mining accrues with time and is split by weight; claiming is never blocked by the lock.
    function _stepMine() internal {
        vm.warp(block.timestamp + 20 days);
        uint256 alicePending = jVault.pendingReward(alice, aliceId);
        uint256 bobPending = jVault.pendingReward(bob, bobId);
        assertGt(alicePending, 0, "alice has mined");
        assertGt(bobPending, 0, "bob has mined");
        // Same time window, so the rewards are in the ratio of the weights.
        assertApproxEqRel(
            alicePending * jVault.positionOf(bob, bobId).weight,
            bobPending * jVault.positionOf(alice, aliceId).weight,
            1e12,
            "rewards follow the weights"
        );

        uint256 aliceBefore = IERC20(jToken).balanceOf(alice);
        vm.prank(alice);
        jVault.claim(aliceId);
        assertGe(IERC20(jToken).balanceOf(alice) - aliceBefore, alicePending, "alice was paid her mining reward");
    }

    /// @dev Bob's 30-day lock has not ended at day 20 so unstaking is refused; after it ends he gets his stake back.
    ///      The dev's 1% vests linearly over 30 days out of the dock.
    function _stepUnstakeAndDevVest() internal {
        vm.prank(bob);
        vm.expectRevert();
        jVault.unstake(bobId);

        vm.warp(block.timestamp + 11 days);
        uint256 bobBefore = IERC20(jToken).balanceOf(bob);
        vm.prank(bob);
        jVault.unstake(bobId);
        assertGe(IERC20(jToken).balanceOf(bob) - bobBefore, bobStake, "bob got his stake back plus his reward");

        uint256 vested = jVault.devVested();
        assertEq(vested, jVault.devVestAmount(), "the 30-day vest is complete by now");
        uint256 devBefore = IERC20(jToken).balanceOf(creator);
        jVault.claimDevVested();
        assertEq(IERC20(jToken).balanceOf(creator) - devBefore, vested, "the dev received the vested tokens");
    }

    function test_11_stakemine_revenueGoesToTheDevThenToHolders() public {
        _deploy();
        (address token, StakeMineVault vault) = _launch("stakemine-revenue");

        // Real trading generates tax; the VAULT slot's share reaches the vault in native BNB.
        uint256 before_ = address(vault).balance;
        _generateTaxAndDispatch(token);
        uint256 revenue = address(vault).balance - before_;
        assertGt(revenue, 0, "the VAULT slot paid the vault");
        vault.sync();

        // 20% of the revenue is credited to the dev (up to the 1.5x cap); the rest waits for the holders.
        uint256 devShare = vault.devClaimable();
        assertGt(devShare, 0, "the dev is credited");
        assertApproxEqAbs(devShare, revenue * 2000 / 10_000, 2, "the dev's share is 20%");
        assertApproxEqAbs(vault.pendingDividend(), revenue - devShare, 2, "the rest waits for the holders");

        uint256 devBefore = creator.balance;
        vault.claimDevQuote();
        assertEq(creator.balance - devBefore, devShare, "the dev received its quote share");

        // The holders' share is pushed into the token's dividend tracker by anyone. Trading has created
        // shareholders by now, so the whole pending amount moves, wrapped into WBNB first.
        uint256 pending = vault.pendingDividend();
        address dividend = ITokenDividendLike(token).dividendContract();
        uint256 dividendBefore = IERC20(wbnb).balanceOf(dividend);
        vault.flushDividends();
        assertEq(vault.pendingDividend(), 0, "nothing left pending");
        assertEq(vault.totalDividendDeposited(), pending, "the whole holder share was deposited");
        assertEq(
            IERC20(wbnb).balanceOf(dividend) - dividendBefore, pending, "the dividend contract received it in WBNB"
        );
    }

    function test_12_stakemine_onlyTheGuardianUpgrades() public {
        _deploy();
        address impl = address(new StakeMineVault());
        vm.expectRevert();
        factory.upgradeVaultImplementation(impl);
        vm.prank(guardian);
        factory.upgradeVaultImplementation(impl);
        assertEq(factory.beaconImplementation(), impl);
    }

    function _buyFor(address token, address who, uint256 bnb) internal {
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = token;
        vm.deal(who, who.balance + bnb);
        vm.prank(who);
        IRouterLikeBuy(v2Router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnb}(
            0, path, who, block.timestamp + 600
        );
    }
}

interface ITokenDividendLike {
    function dividendContract() external view returns (address);
}

interface IRouterLikeBuy {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}
