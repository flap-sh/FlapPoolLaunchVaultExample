// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StakeMineFork} from "test/vault/StakeMine.fork.t.sol";
import {ForkAddresses} from "test/ForkAddresses.sol";

/// @notice The reserve-taking Vault on BNB Testnet. Needs `BSC_TESTNET_RPC_URL`; skipped without it.
contract StakeMineBSCTestForkTest is StakeMineFork {
    function _addrs() internal pure override returns (ForkAddresses.Addrs memory) {
        return ForkAddresses.bscTest();
    }
}
