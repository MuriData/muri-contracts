// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketDashboard} from "./market/MarketDashboard.sol";

/// @notice Second extension contract — holds heavy dashboard view functions.
/// Reached via chained DELEGATECALL: FileMarket → Extension → Extension2.
contract FileMarketExtension2 is MarketDashboard {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("not upgradeable");
    }
}
