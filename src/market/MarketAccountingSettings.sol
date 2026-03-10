// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketOnDemandChallenge} from "./MarketOnDemandChallenge.sol";

/// @notice Admin setters and view helpers for accounting parameters.
/// Split from MarketAccounting to keep FileMarket under EIP-170 size limit.
/// Reached via chained fallback: FileMarket → Extension → Extension2.
abstract contract MarketAccountingSettings is MarketOnDemandChallenge {
    /// @notice Set the reporter reward percentage (in basis points)
    /// @param _newBps New reward percentage in basis points (max 5000 = 50%)
    function setReporterRewardBps(uint256 _newBps) external onlyOwner {
        require(_newBps <= MAX_REPORTER_REWARD_BPS, "exceeds max bps");
        uint256 oldBps = reporterRewardBps;
        reporterRewardBps = _newBps;
        emit ReporterRewardBpsUpdated(oldBps, _newBps);
    }

    /// @notice Set the proof failure slash multiplier
    /// @param _newMultiplier New multiplier (1 to MAX_PROOF_FAILURE_SLASH_MULTIPLIER)
    function setProofFailureSlashMultiplier(uint256 _newMultiplier) external onlyOwner {
        require(_newMultiplier >= 1 && _newMultiplier <= MAX_PROOF_FAILURE_SLASH_MULTIPLIER, "invalid multiplier");
        uint256 oldMultiplier = proofFailureSlashMultiplier;
        proofFailureSlashMultiplier = _newMultiplier;
        emit ProofFailureSlashMultiplierUpdated(oldMultiplier, _newMultiplier);
    }

    /// @notice Set the client compensation percentage (in basis points)
    /// @param _newBps New compensation percentage in basis points (max MAX_CLIENT_COMPENSATION_BPS)
    function setClientCompensationBps(uint256 _newBps) external onlyOwner {
        require(_newBps <= MAX_CLIENT_COMPENSATION_BPS, "exceeds max bps");
        uint256 oldBps = clientCompensationBps;
        clientCompensationBps = _newBps;
        emit ClientCompensationBpsUpdated(oldBps, _newBps);
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
        returns (
            uint256 totalReceived,
            uint256 totalBurned,
            uint256 totalRewards,
            uint256 currentBps,
            uint256 totalClientComp
        )
    {
        totalReceived = totalSlashedReceived;
        totalBurned = totalBurnedFromSlash;
        totalRewards = totalReporterRewards;
        currentBps = reporterRewardBps;
        totalClientComp = totalClientCompensation;
    }
}
