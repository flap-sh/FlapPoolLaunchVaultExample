// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CrowdFork} from "test/launcher-vault/Crowd.fork.t.sol";
import {ForkAddresses} from "test/ForkAddresses.sol";

/// @notice A launcher paired with a vault on BNB Chain. Needs `BSC_RPC_URL`; skipped without it.
contract CrowdBSCForkTest is CrowdFork {
    function _addrs() internal pure override returns (ForkAddresses.Addrs memory) {
        return ForkAddresses.bsc();
    }
}
