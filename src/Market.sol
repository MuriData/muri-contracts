// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketAccounting} from "./market/MarketAccounting.sol";

/// @notice Public entrypoint for the modular FileMarket implementation.
/// Challenge and view functions live in FileMarketExtension, reached via fallback delegation.
contract FileMarket is MarketAccounting {
    /// @notice Address of the extension contract (challenges + views), set once in constructor.
    address public immutable extension;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _extension) {
        extension = _extension;
        _disableInitializers();
    }

    function initialize(address _owner, address _nodeStaking) external initializer {
        __UUPSUpgradeable_init();
        __MarketStorage_init(_owner, _nodeStaking);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Delegates unrecognized selectors to the extension contract (challenges + views).
    fallback() external payable {
        address ext = extension;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
