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

    function setChallengeStartBlock(uint256 _block) external onlyOwner {
        challengeStartBlock = _block;
    }

    /// @notice Set the number of orders each challenge slot handles.
    /// Lower = more slots = faster detection = more gas. Higher = fewer slots = less gas.
    /// @param _ordersPerSlot Orders per slot (1–200). Set to 0 to restore default (20).
    function setOrdersPerSlot(uint256 _ordersPerSlot) external onlyOwner {
        require(_ordersPerSlot <= MAX_ORDERS_PER_SLOT, "exceeds max");
        if (_ordersPerSlot > 0) {
            require(_ordersPerSlot >= MIN_ORDERS_PER_SLOT, "below min");
        }
        uint256 old = ordersPerSlot;
        ordersPerSlot = _ordersPerSlot;
        emit OrdersPerSlotUpdated(old, _ordersPerSlot);
    }

    /// @notice Set the maximum number of challenge slots.
    /// @param _maxSlots Maximum slots (2–200). Set to 0 to restore default (50).
    function setMaxChallengeSlots(uint256 _maxSlots) external onlyOwner {
        require(_maxSlots <= ABSOLUTE_MAX_CHALLENGE_SLOTS, "exceeds absolute max");
        if (_maxSlots > 0) {
            require(_maxSlots >= MIN_CHALLENGE_SLOTS, "below min");
        }
        uint256 old = maxChallengeSlots;
        maxChallengeSlots = _maxSlots;
        emit MaxChallengeSlotsUpdated(old, _maxSlots);
    }

    function currentPeriod() public view returns (uint256) {
        return (block.timestamp - genesisTs) / PERIOD;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesisTs) / EPOCH;
    }
}
