// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FileMarket} from "../../src/Market.sol";

/// @notice Minimal V2 mock for upgrade testing. Appends storage after inherited __gap.
contract FileMarketV2 is FileMarket {
    uint256 public v2ExampleParam;

    constructor(address _ext) FileMarket(_ext) {}

    function initializeV2(uint256 _param) external reinitializer(2) {
        v2ExampleParam = _param;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
