// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketViews} from "./market/MarketViews.sol";

/// @notice Extension contract for FileMarket — holds challenge and view functions.
/// Reached via DELEGATECALL from the main FileMarket fallback, so it operates on proxy storage.
/// Unrecognized selectors are forwarded to extension2 (dashboard views) via a second fallback.
contract FileMarketExtension is MarketViews {
    /// @notice Address of the second extension (dashboard views), set once in constructor.
    address public immutable extension2;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _extension2) {
        extension2 = _extension2;
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("not upgradeable");
    }

    /// @notice Delegates unrecognized selectors to extension2 (dashboard views).
    fallback() external payable {
        address ext2 = extension2;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), ext2, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
