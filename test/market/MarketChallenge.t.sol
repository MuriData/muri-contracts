// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketChallengeTest is MarketTestBase {
    function test_TriggerHeartbeat_BootstrapsRandomness() public {
        assertEq(market.currentRandomness(), 0);

        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        assertTrue(market.challengeInitialized());
        assertGt(market.currentRandomness(), 0);
        assertEq(market.lastChallengeStep(), market.currentStep());
    }

    function test_TriggerHeartbeat_SelectsChallengeFromAssignedOrders() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        _stakeDefaultNode(node2, 0xAAAA, 0xBBBB);

        (uint256 order1,) = _placeDefaultOrder(user1, 1);
        (uint256 order2,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(order1);

        vm.prank(node2);
        market.executeOrder(order2);

        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        (, uint256 challengeStep, address primaryProver, address[] memory secondaries, uint256[] memory orders,, bool active)
        = market.getCurrentChallengeInfo();

        assertGt(challengeStep, 0);
        assertTrue(primaryProver != address(0));
        assertTrue(orders.length > 0);
        assertTrue(active);
        assertTrue(secondaries.length <= orders.length);
    }

    function test_RevertWhen_TriggerHeartbeat_ChallengeStillActive() public {
        _bootstrapSingleOrderChallenge();

        vm.expectRevert("challenge still active");
        market.triggerHeartbeat();
    }

    function test_RevertWhen_SlashSecondaryFailures_CalledEarly() public {
        _bootstrapSingleOrderChallenge();

        vm.expectRevert("challenge period not expired");
        market.slashSecondaryFailures();
    }

    function test_RevertWhen_ReportPrimaryFailure_ChallengeNotExpired() public {
        _stakeDefaultNode(node2, 0xABCD, 0xEF01);
        _bootstrapSingleOrderChallenge();

        vm.prank(node2);
        vm.expectRevert("challenge period not expired");
        market.reportPrimaryFailure();
    }

    function test_ReportPrimaryFailure_AdvancesHeartbeatAndRewardsReporter() public {
        _stakeDefaultNode(node2, 0xABCD, 0xEF01);
        (, address primary) = _bootstrapSingleOrderChallenge();

        vm.warp(block.timestamp + (2 * STEP) + 1);
        uint256 lastStepBefore = market.lastChallengeStep();

        vm.prank(node2);
        market.reportPrimaryFailure();

        assertTrue(primary != address(0));
        assertGt(market.lastChallengeStep(), lastStepBefore);
        assertGt(market.reporterPendingRewards(node2), 0);
    }

    function test_SubmitProof_RevertWhenNoActiveChallenge() public {
        uint256[8] memory proof;

        vm.prank(node1);
        vm.expectRevert("no active challenge");
        market.submitProof(proof, bytes32(uint256(1)));
    }

    function test_CancelOrder_RevertDuringActiveChallenge() public {
        (uint256 orderId,) = _bootstrapSingleOrderChallenge();

        vm.prank(user1);
        vm.expectRevert("order under active challenge");
        market.cancelOrder(orderId);
    }
}
