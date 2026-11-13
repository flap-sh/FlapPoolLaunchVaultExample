// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {MintLauncher, MintConfig} from "src/launcher/MintLauncher.sol";
import {MintLauncherFactory} from "src/launcher/MintLauncherFactory.sol";
import {NameSymbolCheck} from "src/common/NameSymbolCheck.sol";
import {ForkBase} from "test/ForkBase.sol";

/// @notice MODE: a Launcher on its own, no Vault. `MintLauncher` raises a fixed amount of BNB; the contribution that
///         meets the target launches the token and the contributors split half of the supply.
///
///   What Flap does for you: open the LauncherFactory (`setLauncherFactoryMultiplier`). What the test then runs, on a
///   live Portal: `Portal.newLauncher` -> contributions -> the launch -> trading and tax -> claims.
abstract contract MintLauncherFork is ForkBase {
    function _expectCreateRevert(address factory, bytes memory data, bytes memory reason) internal {
        uint256 fee = portal.SALT_LOCK_FEE();
        vm.startPrank(creator);
        vm.expectRevert(reason);
        portal.newLauncher{value: fee}(factory, data);
        vm.stopPrank();
    }

    function _mintConfig(bytes32 seed) internal returns (MintConfig memory c) {
        c.name = "Mint Example";
        c.symbol = "MINTX";
        c.meta = "bafkreig4y5nwb4izyilbbmiydumvkld446d4k7j4ohg3x3q2lfel3fo4yq";
        c.salt = _mineSalt(seed);
        c.targetRaise = 10 ether;
        c.saleDuration = 1 days;
    }

    function test_01_mint_anUnopenedFactoryCannotCreateLaunchers() public {
        _requireLauncherGate();
        MintLauncherFactory factory = new MintLauncherFactory();
        bytes memory data = abi.encode(_mintConfig("mint-unopened"));
        uint256 fee = portal.SALT_LOCK_FEE();

        // Before Flap opens the factory the Portal refuses to call it.
        vm.prank(creator);
        vm.expectRevert();
        portal.newLauncher{value: fee}(address(factory), data);

        (bool enabled,) = portal.launcherFactoryMultiplier(address(factory));
        assertFalse(enabled, "a new factory starts closed");
    }

    function test_02_mint_fullJourney() public {
        MintLauncherFactory factory = new MintLauncherFactory();
        _openLauncherFactory(address(factory));
        // The live Portal is paused; an opened Launcher factory is what lets its launches through.
        assertTrue(_paused(), "the live Portal is paused, which is the case this test is about");

        MintConfig memory c = _mintConfig("mint-journey");
        vm.recordLogs();
        address launcherAddr = _newLauncher(address(factory), abi.encode(c));
        Vm.Log[] memory creation = vm.getRecordedLogs();
        MintLauncher launcher = MintLauncher(payable(launcherAddr));

        // The Portal recorded launcher -> factory.
        assertEq(portal.getLauncher(launcherAddr).launcherFactory, address(factory), "Portal recorded the Launcher");
        assertEq(launcher.creator(), creator, "creator is the wallet that called the Portal");
        assertFalse(launcher.launched());

        // Display-only surface: the v1 JSON the Launcher renders, mirrored into the creation event.
        _assertLauncherDescription(launcherAddr, c.name, c.symbol, c.targetRaise, creation);

        vm.recordLogs();
        vm.prank(alice);
        launcher.contribute{value: 4 ether}();
        assertFalse(launcher.launched(), "target not met yet");
        vm.prank(bob);
        launcher.contribute{value: 6 ether}();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(launcher.launched(), "the contribution that met the target launched the token");
        address token = launcher.token();
        assertTrue(token.code.length > 0, "token deployed");
        assertEq(uint16(uint160(token)), 0x7777, "vanity suffix");

        // FlapDirectLaunched names the real creator, not the Launcher.
        assertEq(_launchedCreator(logs, token), creator, "creator extension shows the user, not the Launcher");

        // Claims: contributors split the reserved half pro rata.
        vm.prank(alice);
        launcher.claim();
        vm.prank(bob);
        launcher.claim();
        uint256 reserved = launcher.TOTAL_SUPPLY() - launcher.POOL_TOKEN();
        assertEq(IERC20(token).balanceOf(alice), reserved * 4 / 10, "alice 40%");
        assertEq(IERC20(token).balanceOf(bob), reserved * 6 / 10, "bob 60%");

        // Trading works on the real pool, and tax flows without reverting.
        _generateTaxAndDispatch(token);
    }

    function test_03_mint_refundWhenTheTargetIsMissed() public {
        MintLauncherFactory factory = new MintLauncherFactory();
        _openLauncherFactory(address(factory));
        MintLauncher launcher =
            MintLauncher(payable(_newLauncher(address(factory), abi.encode(_mintConfig("mint-refund")))));

        vm.prank(alice);
        launcher.contribute{value: 3 ether}();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        launcher.refund();
        assertEq(alice.balance, 30 ether, "alice got everything back");
        assertFalse(launcher.launched());
    }

    function test_04_mint_aLauncherLaunchesOnlyOnce() public {
        MintLauncherFactory factory = new MintLauncherFactory();
        _openLauncherFactory(address(factory));
        MintLauncher launcher =
            MintLauncher(payable(_newLauncher(address(factory), abi.encode(_mintConfig("mint-once")))));
        vm.prank(alice);
        launcher.contribute{value: 10 ether}();
        assertTrue(launcher.launched());

        vm.prank(bob);
        vm.expectRevert();
        launcher.contribute{value: 1 ether}();
    }

    function test_04b_mint_rejectsMalformedAndOutOfRangeConfig() public {
        MintLauncherFactory factory = new MintLauncherFactory();
        _openLauncherFactory(address(factory));
        MintConfig memory c = _mintConfig("mint-invalid");
        bytes memory extra = bytes.concat(abi.encode(c), hex"00");
        _expectCreateRevert(address(factory), extra, abi.encodeWithSelector(MintLauncherFactory.InvalidData.selector));

        c.symbol = "";
        _expectCreateRevert(
            address(factory), abi.encode(c), abi.encodeWithSelector(MintLauncherFactory.EmptyField.selector)
        );

        c.symbol = "MINTX";
        c.targetRaise = 0.5 ether;
        _expectCreateRevert(
            address(factory),
            abi.encode(c),
            abi.encodeWithSelector(MintLauncherFactory.TargetOutOfRange.selector, c.targetRaise)
        );

        c.targetRaise = 10 ether;
        c.saleDuration = 31 days;
        _expectCreateRevert(
            address(factory),
            abi.encode(c),
            abi.encodeWithSelector(MintLauncherFactory.SaleDurationOutOfRange.selector, c.saleDuration)
        );
    }

    function test_04c_mint_rejectsBlacklistedSymbol() public {
        MintLauncherFactory factory = new MintLauncherFactory();
        _openLauncherFactory(address(factory));
        MintConfig memory c = _mintConfig("mint-blacklist");
        c.symbol = "USDT";
        _expectCreateRevert(
            address(factory),
            abi.encode(c),
            abi.encodeWithSelector(NameSymbolCheck.BlacklistedNameOrSymbol.selector, "USDT")
        );
    }
}
