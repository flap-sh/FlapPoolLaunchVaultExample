// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/proxy/Clones.sol";

import {LauncherHelper, LauncherDescription} from "src/flap/LauncherHelper.sol";
import {MintLauncher, MintConfig} from "src/launcher/MintLauncher.sol";
import {CrowdLauncher, CrowdConfig} from "src/launcher-vault/CrowdLauncher.sol";

/// @dev The two Portal calls a Launcher makes while initializing. The description does not depend on anything else.
contract StubPortal {
    uint256 internal constant FEE = 0.01 ether;

    function SALT_LOCK_FEE() external pure returns (uint256) {
        return FEE;
    }

    function lockSalt(bytes32, uint8) external payable {}
}

/// @notice The display surface on its own, with no chain involved: the JSON `description()` renders, how it escapes
///         user input, and that the rendered string stays inside the Portal's 4 KB read limit. The fork suites assert
///         the same string arrives in `FlapNewLauncherCreated`; this one runs without an RPC.
contract LauncherDescriptionTest is Test {
    /// @dev `PortalPoolLauncher.LAUNCHER_DESCRIPTION_MAX`: a longer string is dropped to "" by the Portal.
    uint256 internal constant PORTAL_DESCRIPTION_LIMIT = 4_096;

    StubPortal internal stub;

    function setUp() public {
        stub = new StubPortal();
    }

    function _mint(string memory name, string memory symbol) internal returns (MintLauncher) {
        MintLauncher impl = new MintLauncher();
        MintLauncher launcher = MintLauncher(payable(Clones.clone(address(impl))));
        MintConfig memory c = MintConfig({
            name: name,
            symbol: symbol,
            meta: "",
            salt: bytes32(uint256(0x1234)),
            targetRaise: 10 ether,
            saleDuration: 1 days
        });
        launcher.initialize{value: stub.SALT_LOCK_FEE()}(address(stub), address(this), c);
        return launcher;
    }

    function _crowd(string memory name, string memory symbol) internal returns (CrowdLauncher) {
        CrowdLauncher impl = new CrowdLauncher();
        CrowdLauncher launcher = CrowdLauncher(payable(Clones.clone(address(impl))));
        CrowdConfig memory c = CrowdConfig({
            name: name,
            symbol: symbol,
            meta: "",
            salt: bytes32(uint256(0x5678)),
            targetRaise: 10 ether,
            saleDuration: 1 days,
            vaultFactory: address(0xBEEF),
            contributorBps: 6000
        });
        launcher.initialize{value: stub.SALT_LOCK_FEE()}(address(stub), address(this), c);
        return launcher;
    }

    /// @dev The exact v1 object every Launcher renders: `v` is a number, everything else a string.
    function test_toJson_isTheDocumentedV1Object() public pure {
        LauncherDescription memory d = LauncherDescription({
            name: "A",
            symbol: "B",
            quoteToken: address(0),
            targetRaise: 3 ether,
            poolTokenRatio: 5e17,
            titleZh: "z",
            titleEn: "e",
            summaryZh: "z",
            summaryEn: "e"
        });
        assertEq(
            LauncherHelper.toJson(d),
            '{"v":1,"name":"A","symbol":"B","quoteToken":"0x0000000000000000000000000000000000000000",'
            '"targetRaise":"3000000000000000000","poolTokenRatio":"500000000000000000",'
            '"titleZh":"z","titleEn":"e","summaryZh":"z","summaryEn":"e"}'
        );
    }

    /// @dev Only `name` and `symbol` come from users, so only they are escaped; the JSON stays parseable.
    function test_toJson_escapesUserInput() public pure {
        LauncherDescription memory d = LauncherDescription({
            name: 'Q"uo\\te',
            symbol: "MN\nT",
            quoteToken: address(0),
            targetRaise: 1 ether,
            poolTokenRatio: 5e17,
            titleZh: "z",
            titleEn: "e",
            summaryZh: "z",
            summaryEn: "e"
        });
        string memory json = LauncherHelper.toJson(d);
        assertEq(vm.parseJsonString(json, ".name"), 'Q"uo\\te', "quotes and backslashes survive the round trip");
        assertEq(vm.parseJsonString(json, ".symbol"), "MN\nT", "newlines survive the round trip");
    }

    function test_mintLauncher_rendersItsOwnValues() public {
        MintLauncher launcher = _mint("Mint Example", "MINTX");
        string memory json = launcher.description();

        assertEq(vm.parseJsonUint(json, ".v"), 1, "v");
        assertEq(vm.parseJsonString(json, ".name"), "Mint Example", "name");
        assertEq(vm.parseJsonString(json, ".symbol"), "MINTX", "symbol");
        assertEq(vm.parseJsonString(json, ".quoteToken"), "0x0000000000000000000000000000000000000000", "native");
        assertEq(vm.parseJsonString(json, ".targetRaise"), "10000000000000000000", "targetRaise");
        assertEq(vm.parseJsonString(json, ".poolTokenRatio"), "500000000000000000", "half the supply seeds the pool");
        assertGt(bytes(vm.parseJsonString(json, ".titleEn")).length, 0, "an English title is present");
        assertGt(bytes(vm.parseJsonString(json, ".summaryZh")).length, 0, "a Chinese summary is present");
    }

    function test_crowdLauncher_rendersItsOwnValues() public {
        CrowdLauncher launcher = _crowd("Crowd Example", "CROWDX");
        string memory json = launcher.description();

        assertEq(vm.parseJsonUint(json, ".v"), 1, "v");
        assertEq(vm.parseJsonString(json, ".name"), "Crowd Example", "name");
        assertEq(vm.parseJsonString(json, ".symbol"), "CROWDX", "symbol");
        assertEq(vm.parseJsonString(json, ".targetRaise"), "10000000000000000000", "targetRaise");
        assertEq(vm.parseJsonString(json, ".poolTokenRatio"), "500000000000000000", "half the supply seeds the pool");
    }

    /// @dev The Portal reads at most 4 KB and silently falls back to "" past it, so the example copy has to leave
    ///      room for the user's `name` and `symbol`. This is the budget a creator has to stay inside.
    function test_renderedDescription_fitsThePortalLimit() public {
        MintLauncher mint = _mint("Mint Example", "MINTX");
        CrowdLauncher crowd = _crowd("Crowd Example", "CROWDX");
        uint256 mintLen = bytes(mint.description()).length;
        uint256 crowdLen = bytes(crowd.description()).length;

        assertLt(mintLen, PORTAL_DESCRIPTION_LIMIT, "mint description fits");
        assertLt(crowdLen, PORTAL_DESCRIPTION_LIMIT, "crowd description fits");
        emit log_named_uint("mint description bytes", mintLen);
        emit log_named_uint("crowd description bytes", crowdLen);
        emit log_named_uint("bytes left for name+symbol (mint)", PORTAL_DESCRIPTION_LIMIT - mintLen);
        emit log_named_uint("bytes left for name+symbol (crowd)", PORTAL_DESCRIPTION_LIMIT - crowdLen);
    }
}
