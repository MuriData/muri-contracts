// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketOrders} from "./MarketOrders.sol";

/// @notice Reporter-reward, pull-payment, and slash accounting operations.
/// Admin setters (setReporterRewardBps, setProofFailureSlashMultiplier, setClientCompensationBps)
/// and view helpers (getReporterEarningsInfo, getSlashRedistributionStats) live in
/// MarketAccountingSettings (Extension2) to keep FileMarket under the EIP-170 size limit.
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

    /// @notice Withdraw accumulated pull-payment refunds
    function withdrawRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        require(amount > 0, "no refund");
        pendingRefunds[msg.sender] = 0;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "transfer failed");
        emit RefundWithdrawn(msg.sender, amount);
    }

    /// @notice Allow contract to receive native token from slashed nodes
    receive() external payable {}
}
