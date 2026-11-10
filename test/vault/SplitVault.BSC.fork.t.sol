// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SplitVaultFork} from "test/vault/SplitVault.fork.t.sol";
import {ForkAddresses} from "test/ForkAddresses.sol";

/// @notice A vault on its own on BNB Chain. Needs `BSC_RPC_URL`; skipped without it.
contract SplitVaultBSCForkTest is SplitVaultFork {
    function _addrs() internal pure override returns (ForkAddresses.Addrs memory) {
        return ForkAddresses.bsc();
    }
}
