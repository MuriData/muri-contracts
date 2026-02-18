// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketStorage} from "./MarketStorage.sol";

/// @notice Ownership and shared time-index helpers for FileMarket modules.
abstract contract MarketAdmin is MarketStorage {
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "invalid owner");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function setSlashAuthority(address _authority, bool _allowed) external onlyOwner {
        slashAuthorities[_authority] = _allowed;
        emit SlashAuthorityUpdated(_authority, _allowed);
    }

    function currentPeriod() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / PERIOD;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / EPOCH;
    }

    function currentStep() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / STEP;
    }
}
