// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketOrders} from "./MarketOrders.sol";

/// @notice Reporter-reward, pull-payment, and slash accounting operations.
abstract contract MarketAccounting is MarketOrders {
    /// @notice Claim accumulated reporter rewards
    function claimReporterRewards() external nonReentrant {
        uint256 amount = reporterPendingRewards[msg.sender];
        require(amount > 0, "no reporter rewards");

        reporterPendingRewards[msg.sender] = 0;
        reporterWithdrawn[msg.sender] += amount;

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "transfer failed");

        emit ReporterRewardsClaimed(msg.sender, amount);
    }

    /// @notice Set the reporter reward percentage (in basis points)
    /// @param _newBps New reward percentage in basis points (max 5000 = 50%)
    function setReporterRewardBps(uint256 _newBps) external onlyOwner {
        require(_newBps <= MAX_REPORTER_REWARD_BPS, "exceeds max bps");
        uint256 oldBps = reporterRewardBps;
        reporterRewardBps = _newBps;
        emit ReporterRewardBpsUpdated(oldBps, _newBps);
    }

    /// @notice Get reporter earnings info
    function getReporterEarningsInfo(address _reporter)
        external
        view
        returns (uint256 earned, uint256 withdrawn, uint256 pending)
    {
        earned = reporterEarnings[_reporter];
        withdrawn = reporterWithdrawn[_reporter];
        pending = reporterPendingRewards[_reporter];
    }

    /// @notice Get slash redistribution statistics
    function getSlashRedistributionStats()
        external
        view
        returns (uint256 totalReceived, uint256 totalBurned, uint256 totalRewards, uint256 currentBps)
    {
        totalReceived = totalSlashedReceived;
        totalBurned = totalBurnedFromSlash;
        totalRewards = totalReporterRewards;
        currentBps = reporterRewardBps;
    }

    /// @notice Withdraw accumulated pull-payment refunds
    function withdrawRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        require(amount > 0, "no refund");
        pendingRefunds[msg.sender] = 0;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "transfer failed");
        emit RefundWithdrawn(msg.sender, amount);
    }

    /// @notice Allow contract to receive ETH from slashed nodes
    receive() external payable {}
}
