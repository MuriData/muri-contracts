// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {NodeStaking} from "../../src/NodeStaking.sol";

/// @notice Minimal V2 mock for upgrade testing. Appends storage after inherited __gap.
contract NodeStakingV2 is NodeStaking {
    uint256 public v2StakingParam;

    function initializeV2(uint256 _param) external reinitializer(2) {
        v2StakingParam = _param;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
