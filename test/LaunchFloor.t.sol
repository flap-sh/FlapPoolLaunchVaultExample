// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPortal} from "src/flap/IPortal.sol";
import {IPortalLaunchFloor} from "src/common/IPortalLaunchFloor.sol";
import {MintLauncher, MintConfig} from "src/launcher/MintLauncher.sol";
import {MintLauncherFactory} from "src/launcher/MintLauncherFactory.sol";
import {CrowdLauncher, CrowdConfig} from "src/launcher-vault/CrowdLauncher.sol";
import {CrowdLauncherFactory} from "src/launcher-vault/CrowdLauncherFactory.sol";

contract EmptyPortal {}

/// @notice Exercises creation-time floor checks without depending on a live fork's configured BNB price.
contract LaunchFloorTest is Test {
    address internal hub;
    address internal constant VAULT_FACTORY = address(0xBEEF);
    uint256 internal constant PRICE = 700 ether;

    MintLauncherFactory internal mintFactory;
    CrowdLauncherFactory internal crowdFactory;

    function setUp() public {
        hub = address(new EmptyPortal());
        mintFactory = new MintLauncherFactory(hub, address(this));
        crowdFactory = new CrowdLauncherFactory(hub, address(this), VAULT_FACTORY);
    }

    function test_mint_rejectsRaiseBelowPortalCreateFloor() public {
        _mockFloor(2 ether, address(0), false);

        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(MintLauncherFactory.BelowLaunchFloor.selector, 1400 ether, 1500 ether));
        mintFactory.newLauncher(address(this), abi.encode(_mintConfig(2 ether)));
    }

    function test_crowd_rejectsRaiseBelowPortalCreateFloor() public {
        _mockFloor(2 ether, VAULT_FACTORY, false);

        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(CrowdLauncherFactory.BelowLaunchFloor.selector, 1400 ether, 1500 ether));
        crowdFactory.newLauncher(address(this), abi.encode(_crowdConfig(2 ether)));
    }

    function test_mint_acceptsRaiseAbovePortalCreateFloor() public {
        _mockFloor(2.15 ether, address(0), true);
        _mockSaltLock();

        vm.prank(hub);
        address launcher = mintFactory.newLauncher(address(this), abi.encode(_mintConfig(2.15 ether)));
        assertEq(MintLauncher(payable(launcher)).targetRaise(), 2.15 ether);
    }

    function test_crowd_acceptsRaiseAbovePortalCreateFloor() public {
        _mockFloor(2.15 ether, VAULT_FACTORY, true);
        _mockSaltLock();

        vm.prank(hub);
        address launcher = crowdFactory.newLauncher(address(this), abi.encode(_crowdConfig(2.15 ether)));
        assertEq(CrowdLauncher(payable(launcher)).targetRaise(), 2.15 ether);
    }

    function test_mint_rejectsDisabledQuote() public {
        vm.mockCall(
            hub,
            abi.encodeWithSelector(IPortalLaunchFloor.launchQuoteConfig.selector, uint8(0), address(0)),
            abi.encode(false, PRICE)
        );

        vm.prank(hub);
        vm.expectRevert(MintLauncherFactory.QuoteNotEnabled.selector);
        mintFactory.newLauncher(address(this), abi.encode(_mintConfig(10 ether)));
    }

    function test_mint_rejectsRaiseAboveSafetyCap() public {
        uint256 raise = 10_001 ether;

        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(MintLauncherFactory.TargetOutOfRange.selector, raise));
        mintFactory.newLauncher(address(this), abi.encode(_mintConfig(raise)));
    }

    function _mockFloor(uint256 raise, address vaultFactory, bool meets) internal {
        vm.mockCall(
            hub,
            abi.encodeWithSelector(IPortalLaunchFloor.launchQuoteConfig.selector, uint8(0), address(0)),
            abi.encode(true, PRICE)
        );

        IPortalLaunchFloor.GraduationFloorParams memory params = IPortalLaunchFloor.GraduationFloorParams({
            quoteToken: address(0),
            quotePriceUsd: PRICE,
            poolQuote: raise,
            poolToken: 500_000 ether,
            totalSupply: 1_000_000 ether,
            vaultFactory: vaultFactory
        });
        IPortalLaunchFloor.GraduationFloorResultV2 memory result = IPortalLaunchFloor.GraduationFloorResultV2({
            meetsFloor: false,
            floorUsdWad: 3000 ether,
            quoteUsdWad: raise * PRICE / 1 ether,
            multiplierBps: 10_000,
            meetsCreateFloor: meets,
            createFloorUsdWad: 1500 ether
        });
        vm.mockCall(
            hub, abi.encodeWithSelector(IPortalLaunchFloor.graduationFloorV2.selector, params), abi.encode(result)
        );
    }

    function _mockSaltLock() internal {
        vm.mockCall(hub, abi.encodeWithSelector(IPortal.SALT_LOCK_FEE.selector), abi.encode(uint256(0)));
        vm.mockCall(hub, abi.encodeWithSelector(IPortal.lockSalt.selector), "");
    }

    function _mintConfig(uint256 raise) internal pure returns (MintConfig memory c) {
        c.name = "Mint Floor";
        c.symbol = "MFLR";
        c.salt = bytes32(uint256(1));
        c.targetRaise = raise;
        c.saleDuration = 1 days;
    }

    function _crowdConfig(uint256 raise) internal pure returns (CrowdConfig memory c) {
        c.name = "Crowd Floor";
        c.symbol = "CFLR";
        c.salt = bytes32(uint256(2));
        c.targetRaise = raise;
        c.saleDuration = 1 days;
        c.vaultFactory = VAULT_FACTORY;
        c.contributorBps = 6000;
    }
}
