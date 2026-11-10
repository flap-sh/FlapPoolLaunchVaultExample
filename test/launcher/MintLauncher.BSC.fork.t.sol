// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MintLauncherFork} from "test/launcher/MintLauncher.fork.t.sol";
import {ForkAddresses} from "test/ForkAddresses.sol";

/// @notice A launcher on its own on BNB Chain. Needs `BSC_RPC_URL`; skipped without it.
contract MintLauncherBSCForkTest is MintLauncherFork {
    function _addrs() internal pure override returns (ForkAddresses.Addrs memory) {
        return ForkAddresses.bsc();
    }
}
