// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketDashboard} from "./market/MarketDashboard.sol";
import {MarketAccountingSettings} from "./market/MarketAccountingSettings.sol";

/// @notice Second extension contract — holds dashboard views, on-demand challenges,
/// key leak reporting, and accounting admin setters.
/// Reached via chained DELEGATECALL: FileMarket → Extension → Extension2.
contract FileMarketExtension2 is MarketAccountingSettings, MarketDashboard {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("not upgradeable");
    }
}
