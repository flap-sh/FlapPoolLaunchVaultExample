// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IAntiScamModule {
    function isScamWord(string calldata name, string calldata symbol)
        external
        view
        returns (bool nameScam, bool symbolScam);
}

/// @notice Check token names and symbols before a Launcher starts collecting funds.
/// @dev The Portal checks them again only at launch, after the raise. The list can change without notice,
///      so a Launcher must keep a refund path if a formerly valid name or symbol becomes blocked.
///      The module addresses cannot be read from the Portal ABI; keep the table in `module()` in sync manually.
library NameSymbolCheck {
    error BlacklistedNameOrSymbol(string value);
    error AntiScamModuleUnknown(uint256 chainId);

    function module() internal view returns (address) {
        if (block.chainid == 56) return 0xfFb69d59f62454f3B8322Bc1a9FCE6E171a5264f;
        if (block.chainid == 97) return 0x5CfbE713d070e87F67D1bc84312B7eB8Fe4F2B5E;
        revert AntiScamModuleUnknown(block.chainid);
    }

    function check(string memory name, string memory symbol) internal view {
        (bool nameScam, bool symbolScam) = IAntiScamModule(module()).isScamWord(name, symbol);
        if (nameScam) revert BlacklistedNameOrSymbol(name);
        if (symbolScam) revert BlacklistedNameOrSymbol(symbol);
    }
}
