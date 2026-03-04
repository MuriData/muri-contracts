// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketViews} from "./market/MarketViews.sol";

/// @notice Public entrypoint for the modular FileMarket implementation.
contract FileMarket is MarketViews {
    function initialize(
        address _owner,
        address _nodeStaking,
        address _poiVerifier,
        address _fspVerifier,
        address _keyleakVerifier
    ) external initializer {
        __UUPSUpgradeable_init();
        __MarketStorage_init(_owner, _nodeStaking, _poiVerifier, _fspVerifier, _keyleakVerifier);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
