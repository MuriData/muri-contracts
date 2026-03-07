// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketViews} from "./market/MarketViews.sol";

/// @notice Extension contract for FileMarket — holds challenge and view functions.
/// Reached via DELEGATECALL from the main FileMarket fallback, so it operates on proxy storage.
/// Not independently upgradeable — upgrades deploy a new extension and a new FileMarket impl.
contract FileMarketExtension is MarketViews {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("not upgradeable");
    }
}
