// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LibString} from "solady/utils/LibString.sol";

/// @notice Display data of a Launcher, rendered by `LauncherHelper.toJson`.
/// @dev Every field is required: a Launcher only renders this after it is initialized, so it always knows
///      its name, symbol, quote token and target.
struct LauncherDescription {
    string name;
    string symbol;
    address quoteToken; // address(0) = native
    uint256 targetRaise; // 18-decimal fixed point
    uint256 poolTokenRatio; // 1e18 = 100%
    string titleZh;
    string titleEn;
    string summaryZh;
    string summaryEn;
}

/// @title LauncherHelper
/// @notice Builds the v1 JSON description a Launcher returns from `description()`. Display-only.
/// @dev The rendered object is:
///      {"v":1,"name":…,"symbol":…,"quoteToken":"0x…","targetRaise":"…","poolTokenRatio":"…",
///       "titleZh":…,"titleEn":…,"summaryZh":…,"summaryEn":…}
///      `v` is the only JSON number; every other value is a string. Amounts and ratios are 1e18 fixed
///      point in decimal, addresses are lowercase `0x`-prefixed. Consumers ignore unknown keys, so new
///      keys can be appended without bumping `v`; rename/remove/redefine a key requires `v: 2`.
///      All keys are camelCase. A new language appends a capitalised suffix to `title` / `summary`
///      (`titleJa`, `summaryJa`); a consumer falls back to the `…En` variant when its language is missing.
///      Only `name` / `symbol` come from users, so only they go through `LibString.escapeJSON`. Titles
///      and summaries are developer constants; tests enforce that they contain nothing to escape.
library LauncherHelper {
    /// @notice Render `d` as the v1 JSON object described above.
    function toJson(LauncherDescription memory d) internal pure returns (string memory) {
        // Split in two `string.concat` calls to stay clear of stack-too-deep.
        string memory head = string.concat(
            '{"v":1,"name":"',
            LibString.escapeJSON(d.name, false),
            '","symbol":"',
            LibString.escapeJSON(d.symbol, false),
            '","quoteToken":"',
            LibString.toHexString(d.quoteToken),
            '","targetRaise":"',
            LibString.toString(d.targetRaise),
            '","poolTokenRatio":"',
            LibString.toString(d.poolTokenRatio)
        );
        return string.concat(
            head,
            '","titleZh":"',
            d.titleZh,
            '","titleEn":"',
            d.titleEn,
            '","summaryZh":"',
            d.summaryZh,
            '","summaryEn":"',
            d.summaryEn,
            '"}'
        );
    }
}
