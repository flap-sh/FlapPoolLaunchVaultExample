// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CrowdFork} from "test/launcher-vault/Crowd.fork.t.sol";
import {ForkAddresses} from "test/ForkAddresses.sol";

/// @notice A launcher paired with a vault on BNB Testnet. Needs `BSC_TESTNET_RPC_URL`; skipped without it.
contract CrowdBSCTestForkTest is CrowdFork {
    function _addrs() internal pure override returns (ForkAddresses.Addrs memory) {
        return ForkAddresses.bscTest();
    }
}
