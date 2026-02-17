// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {NodeStaking} from "../src/NodeStaking.sol";

contract NodeStakingTest is Test {
    NodeStaking public nodeStaking;

    address public node1 = address(0x1);
    address public node2 = address(0x2);
    address public node3 = address(0x3);

    uint256 public constant STAKE_PER_BYTE = 10 ** 14;
    uint64 public constant MIN_CAPACITY = 1;

    event NodeStaked(address indexed node, uint256 stake, uint64 capacity);
    event NodeCapacityIncreased(address indexed node, uint256 additionalStake, uint64 newCapacity);
    event NodeCapacityDecreased(address indexed node, uint256 releasedStake, uint64 newCapacity);
    event NodeUnstaked(address indexed node, uint256 stakeReturned);

    // Implement IMarketProverCheck so NodeStaking's obligation check succeeds.
    // Individual tests can override via vm.mockCall when they need to simulate locked provers.
    function hasUnresolvedProofObligation(address) external pure returns (bool) {
        return false;
    }

    function setUp() public {
        // Set the test contract as the authorized market so tests can call updateNodeUsed
        nodeStaking = new NodeStaking(address(this));

        // Give test addresses some ETH
        vm.deal(node1, 100 ether);
        vm.deal(node2, 100 ether);
        vm.deal(node3, 100 ether);
    }

    // ===== BASIC STAKING TESTS =====

    function test_StakeNode_Success() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.expectEmit(true, false, false, true);
        emit NodeStaked(node1, requiredStake, capacity);

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        (uint256 stake, uint64 nodeCapacity, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, requiredStake);
        assertEq(nodeCapacity, capacity);
        assertEq(used, 0);
    }

    function test_StakeNode_RevertInsufficientStake() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        vm.expectRevert("incorrect stake amount");
        nodeStaking.stakeNode{value: requiredStake - 1}(capacity, 0x1234, 0x5678);
    }

    function test_StakeNode_RevertExcessiveStake() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        vm.expectRevert("incorrect stake amount");
        nodeStaking.stakeNode{value: requiredStake + 1}(capacity, 0x1234, 0x5678);
    }

    function test_StakeNode_RevertCapacityTooLow() public {
        vm.prank(node1);
        vm.expectRevert("capacity too low");
        nodeStaking.stakeNode{value: 0}(0, 0x1234, 0x5678);
    }

    function test_StakeNode_RevertAlreadyStaked() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        vm.prank(node1);
        vm.expectRevert("already staked");
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);
    }

    // ===== CAPACITY INCREASE TESTS =====

    function test_IncreaseCapacity_Success() public {
        // First stake a node
        uint64 initialCapacity = 1000;
        uint256 initialStake = uint256(initialCapacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: initialStake}(initialCapacity, 0x1234, 0x5678);

        // Then increase capacity
        uint64 additionalCapacity = 500;
        uint256 additionalStake = uint256(additionalCapacity) * STAKE_PER_BYTE;

        vm.expectEmit(true, false, false, true);
        emit NodeCapacityIncreased(node1, additionalStake, initialCapacity + additionalCapacity);

        vm.prank(node1);
        nodeStaking.increaseCapacity{value: additionalStake}(additionalCapacity);

        (uint256 stake, uint64 capacity, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, initialStake + additionalStake);
        assertEq(capacity, initialCapacity + additionalCapacity);
        assertEq(used, 0);
    }

    function test_IncreaseCapacity_RevertNotANode() public {
        vm.prank(node1);
        vm.expectRevert("not a node");
        nodeStaking.increaseCapacity{value: 1 ether}(1000);
    }

    function test_IncreaseCapacity_RevertInvalidCapacity() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        vm.prank(node1);
        vm.expectRevert("invalid capacity");
        nodeStaking.increaseCapacity{value: 0}(0);
    }

    // ===== CAPACITY DECREASE TESTS =====

    function test_DecreaseCapacity_Success() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        uint64 reduceCapacity = 300;
        uint256 stakeToRelease = uint256(reduceCapacity) * STAKE_PER_BYTE;
        uint256 initialBalance = node1.balance;

        vm.expectEmit(true, false, false, true);
        emit NodeCapacityDecreased(node1, stakeToRelease, capacity - reduceCapacity);

        vm.prank(node1);
        nodeStaking.decreaseCapacity(reduceCapacity);

        (uint256 stake, uint64 newCapacity, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, requiredStake - stakeToRelease);
        assertEq(newCapacity, capacity - reduceCapacity);
        assertEq(used, 0);
        assertEq(node1.balance, initialBalance + stakeToRelease);
    }

    function test_DecreaseCapacity_RevertCannotReduceBelowUsed() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        // Simulate some usage
        nodeStaking.updateNodeUsed(node1, 600);

        vm.prank(node1);
        vm.expectRevert("cannot reduce below used");
        nodeStaking.decreaseCapacity(500); // Would leave only 500 capacity but 600 is used
    }

    // ===== UNSTAKING TESTS =====

    function test_UnstakeNode_Success() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        uint256 initialBalance = node1.balance;

        vm.expectEmit(true, false, false, true);
        emit NodeUnstaked(node1, requiredStake);

        vm.prank(node1);
        nodeStaking.unstakeNode();

        (uint256 stake, uint64 nodeCapacity, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, 0);
        assertEq(nodeCapacity, 0);
        assertEq(used, 0);
        assertEq(node1.balance, initialBalance + requiredStake);
    }

    function test_UnstakeNode_RevertWhileStoringData() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        // Simulate some data being stored
        nodeStaking.updateNodeUsed(node1, 100);

        vm.prank(node1);
        vm.expectRevert("cannot unstake while storing data");
        nodeStaking.unstakeNode();
    }

    // ===== HELPER FUNCTION TESTS =====

    function test_HasCapacity() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        assertTrue(nodeStaking.hasCapacity(node1, 500));
        assertTrue(nodeStaking.hasCapacity(node1, 1000));
        assertFalse(nodeStaking.hasCapacity(node1, 1001));

        // After some usage
        nodeStaking.updateNodeUsed(node1, 300);
        assertTrue(nodeStaking.hasCapacity(node1, 700));
        assertFalse(nodeStaking.hasCapacity(node1, 701));
    }

    function test_UpdateNodeUsed() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        nodeStaking.updateNodeUsed(node1, 500);

        (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, 500);
    }

    function test_UpdateNodeUsed_RevertExceedsCapacity() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        vm.expectRevert("used exceeds capacity");
        nodeStaking.updateNodeUsed(node1, 1001);
    }

    // ===== FUZZ TESTS =====

    function testFuzz_StakeNode(uint64 capacity) public {
        vm.assume(capacity >= MIN_CAPACITY);
        vm.assume(capacity <= 1000000); // reasonable upper bound

        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;
        vm.assume(requiredStake <= 100 ether); // within our test balance

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        (uint256 stake, uint64 nodeCapacity, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, requiredStake);
        assertEq(nodeCapacity, capacity);
        assertEq(used, 0);
    }

    function testFuzz_CapacityOperations(uint64 initialCapacity, uint64 increaseBy, uint64 decreaseBy) public {
        vm.assume(initialCapacity >= MIN_CAPACITY && initialCapacity <= 10000);
        vm.assume(increaseBy > 0 && increaseBy <= 5000);
        vm.assume(decreaseBy > 0 && decreaseBy <= initialCapacity);

        uint256 initialStake = uint256(initialCapacity) * STAKE_PER_BYTE;
        uint256 additionalStake = uint256(increaseBy) * STAKE_PER_BYTE;

        vm.assume(initialStake + additionalStake <= 50 ether);

        // Initial stake
        vm.prank(node1);
        nodeStaking.stakeNode{value: initialStake}(initialCapacity, 0x1234, 0x5678);

        // Increase capacity
        vm.prank(node1);
        nodeStaking.increaseCapacity{value: additionalStake}(increaseBy);

        // Decrease capacity (if possible)
        if (decreaseBy <= initialCapacity + increaseBy) {
            vm.prank(node1);
            nodeStaking.decreaseCapacity(decreaseBy);

            (uint256 finalStake, uint64 finalCapacity,,,) = nodeStaking.getNodeInfo(node1);
            assertEq(finalCapacity, initialCapacity + increaseBy - decreaseBy);
            assertEq(finalStake, (initialStake + additionalStake) - (uint256(decreaseBy) * STAKE_PER_BYTE));
        }
    }

    // ===== SLASH RETURN AND FUND DESTINATION TESTS =====

    function test_SlashNode_ReturnsTotalSlashed() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        uint256 slashAmount = 100 * STAKE_PER_BYTE;
        (bool forcedOrderExit, uint256 totalSlashed) = nodeStaking.slashNode(node1, slashAmount);

        assertFalse(forcedOrderExit);
        assertEq(totalSlashed, slashAmount);
    }

    function test_SlashNode_ReturnsTotalSlashed_WithAdditionalPenalty() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        // Use all capacity so any slash forces exit
        nodeStaking.updateNodeUsed(node1, capacity);

        uint256 slashAmount = 100 * STAKE_PER_BYTE;
        uint256 expectedAdditional = slashAmount / 2; // 50% additional penalty
        (bool forcedOrderExit, uint256 totalSlashed) = nodeStaking.slashNode(node1, slashAmount);

        assertTrue(forcedOrderExit);
        assertEq(totalSlashed, slashAmount + expectedAdditional);
    }

    function test_SlashNode_SendsFundsToMarket() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity, 0x1234, 0x5678);

        uint256 slashAmount = 100 * STAKE_PER_BYTE;
        uint256 marketBalanceBefore = address(this).balance;

        nodeStaking.slashNode(node1, slashAmount);

        uint256 marketBalanceAfter = address(this).balance;
        assertEq(marketBalanceAfter - marketBalanceBefore, slashAmount, "slashed funds sent to market");
    }

    // ===== CONSTRUCTOR TESTS =====

    function test_Constructor_RevertInvalidMarket() public {
        vm.expectRevert("invalid market");
        new NodeStaking(address(0));
    }

    // ===== PUBLIC KEY VALIDATION =====

    function test_StakeNode_RevertInvalidPublicKeyX() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        vm.expectRevert("public key not in field");
        nodeStaking.stakeNode{value: stake}(capacity, 0, 0x5678);
    }

    function test_StakeNode_RevertInvalidPublicKeyY() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        vm.expectRevert("public key not in field");
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0);
    }

    function test_StakeNode_RevertPublicKeyXExceedsField() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        // BN254 scalar field order
        uint256 R = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
        vm.prank(node1);
        vm.expectRevert("public key not in field");
        nodeStaking.stakeNode{value: stake}(capacity, R, 0x5678);
    }

    function test_StakeNode_RevertPublicKeyYExceedsField() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        uint256 R = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
        vm.prank(node1);
        vm.expectRevert("public key not in field");
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, R);
    }

    function test_StakeNode_RevertPublicKeyMaxUint256() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        vm.expectRevert("public key not in field");
        nodeStaking.stakeNode{value: stake}(capacity, type(uint256).max, type(uint256).max);
    }

    function test_StakeNode_AcceptsMaxValidFieldElement() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        uint256 R = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, R - 1, R - 1);

        (,,, uint256 pkX, uint256 pkY) = nodeStaking.getNodeInfo(node1);
        assertEq(pkX, R - 1);
        assertEq(pkY, R - 1);
    }

    // ===== DECREASE CAPACITY EDGE CASES =====

    function test_DecreaseCapacity_RevertNotANode() public {
        vm.prank(node1);
        vm.expectRevert("not a node");
        nodeStaking.decreaseCapacity(100);
    }

    function test_DecreaseCapacity_RevertZeroReduce() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        vm.prank(node1);
        vm.expectRevert("cannot reduce below used");
        nodeStaking.decreaseCapacity(0);
    }

    // ===== INCREASE CAPACITY EDGE CASES =====

    function test_IncreaseCapacity_RevertIncorrectStakeAmount() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        vm.prank(node1);
        vm.expectRevert("incorrect stake amount");
        nodeStaking.increaseCapacity{value: 1}(500);
    }

    // ===== SLASH NODE EDGE CASES =====

    function test_SlashNode_RevertNotANode() public {
        vm.expectRevert("not a node");
        nodeStaking.slashNode(node1, 100);
    }

    function test_SlashNode_RevertZeroAmount() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        vm.expectRevert("invalid slash amount");
        nodeStaking.slashNode(node1, 0);
    }

    function test_SlashNode_RevertExceedsStake() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        vm.expectRevert("slash exceeds stake");
        nodeStaking.slashNode(node1, stake + 1);
    }

    function test_SlashNode_RevertNotMarket() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        vm.prank(node2);
        vm.expectRevert("not market");
        nodeStaking.slashNode(node1, 100);
    }

    function test_SlashNode_ForcedExit_AdditionalSlashCapped() public {
        // Node stakes small amount, uses all capacity
        // Slash nearly all → additionalSlash (50%) > remaining → capped
        uint64 capacity = 100;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        nodeStaking.updateNodeUsed(node1, capacity);

        // Slash 90% of stake → remaining = 10%, additional = 45% but capped to 10%
        uint256 slashAmount = 90 * STAKE_PER_BYTE;
        (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(node1, slashAmount);

        assertTrue(forcedExit);
        // additionalSlash = slashAmount/2 = 45*SPB, but remaining = 10*SPB → capped to 10*SPB
        // totalSlashed = 90 + 10 = 100*SPB = full stake
        assertEq(totalSlashed, stake, "entire stake slashed when additional is capped");

        (uint256 remainingStake,,,,) = nodeStaking.getNodeInfo(node1);
        assertEq(remainingStake, 0, "node fully drained");
    }

    function test_SlashNode_ExactStakeSlash_NoForcedExit() public {
        // Slash exactly the amount that reduces capacity to used (no forced exit)
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        nodeStaking.updateNodeUsed(node1, 500);

        // Slash enough to bring capacity down to exactly 500 (used)
        // new capacity = (stake - slashAmount) / SPB = 500 → slashAmount = 500 * SPB
        uint256 slashAmount = 500 * STAKE_PER_BYTE;
        (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(node1, slashAmount);

        assertFalse(forcedExit, "no forced exit when capacity == used");
        assertEq(totalSlashed, slashAmount);

        (, uint64 newCap, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(newCap, 500);
        assertEq(used, 500);
    }

    // ===== FORCE REDUCE USED TESTS =====

    function test_ForceReduceUsed_Success() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        nodeStaking.updateNodeUsed(node1, 500);

        nodeStaking.forceReduceUsed(node1, 200);
        (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, 200);
    }

    function test_ForceReduceUsed_RevertNotMarket() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        vm.prank(node2);
        vm.expectRevert("not market");
        nodeStaking.forceReduceUsed(node1, 0);
    }

    function test_ForceReduceUsed_RevertNotANode() public {
        vm.expectRevert("not a node");
        nodeStaking.forceReduceUsed(node1, 0);
    }

    function test_ForceReduceUsed_RevertExceedsCapacity() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        vm.expectRevert("new used exceeds capacity");
        nodeStaking.forceReduceUsed(node1, 1001);
    }

    // ===== GET MAX SLASHABLE TESTS =====

    function test_GetMaxSlashable_NotANode() public view {
        assertEq(nodeStaking.getMaxSlashable(node1), 0);
    }

    function test_GetMaxSlashable_StakeLessThanRequired() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        nodeStaking.updateNodeUsed(node1, capacity); // fully used

        assertEq(nodeStaking.getMaxSlashable(node1), 0, "cannot slash when fully used");
    }

    function test_GetMaxSlashable_Normal() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        nodeStaking.updateNodeUsed(node1, 300);

        uint256 expected = (1000 - 300) * STAKE_PER_BYTE;
        assertEq(nodeStaking.getMaxSlashable(node1), expected);
    }

    // ===== SIMULATE SLASH TESTS =====

    function test_SimulateSlash_NotANode() public view {
        (uint64 newCap, bool willForce) = nodeStaking.simulateSlash(node1, 100);
        assertEq(newCap, 0);
        assertFalse(willForce);
    }

    function test_SimulateSlash_ExceedsStake() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        (uint64 newCap, bool willForce) = nodeStaking.simulateSlash(node1, stake + 1);
        assertEq(newCap, 0);
        assertFalse(willForce);
    }

    function test_SimulateSlash_NoForcedExit() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        uint256 slashAmount = 200 * STAKE_PER_BYTE;
        (uint64 newCap, bool willForce) = nodeStaking.simulateSlash(node1, slashAmount);
        assertEq(newCap, 800);
        assertFalse(willForce);
    }

    function test_SimulateSlash_ForcedExit() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        nodeStaking.updateNodeUsed(node1, 900);

        uint256 slashAmount = 200 * STAKE_PER_BYTE;
        // remaining = 800*SPB, cap = 800, used = 900 → forced exit
        // additional = 100*SPB (50% of 200), remaining -= 100 → 700*SPB, cap = 700
        (uint64 newCap, bool willForce) = nodeStaking.simulateSlash(node1, slashAmount);
        assertEq(newCap, 700);
        assertTrue(willForce);
    }

    function test_SimulateSlash_ForcedExit_AdditionalCapped() public {
        uint64 capacity = 100;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        nodeStaking.updateNodeUsed(node1, capacity);

        uint256 slashAmount = 90 * STAKE_PER_BYTE;
        // remaining = 10*SPB, cap = 10, used = 100 → forced exit
        // additional = 45*SPB (capped to 10*SPB), remaining = 0, cap = 0
        (uint64 newCap, bool willForce) = nodeStaking.simulateSlash(node1, slashAmount);
        assertEq(newCap, 0);
        assertTrue(willForce);
    }

    // ===== NETWORK STATS TESTS =====

    function test_GetNetworkStats() public {
        uint64 cap1 = 1000;
        uint256 stake1 = uint256(cap1) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake1}(cap1, 0x1234, 0x5678);

        uint64 cap2 = 2000;
        uint256 stake2 = uint256(cap2) * STAKE_PER_BYTE;
        vm.prank(node2);
        nodeStaking.stakeNode{value: stake2}(cap2, 0xaaaa, 0xbbbb);

        nodeStaking.updateNodeUsed(node1, 300);
        nodeStaking.updateNodeUsed(node2, 500);

        (uint256 totalNodes, uint256 totalCapStaked, uint256 totalCapUsed) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 2);
        assertEq(totalCapStaked, 3000);
        assertEq(totalCapUsed, 800);
    }

    function test_GetNetworkStats_ExcludesUnstakedNode() public {
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1234, 0x5678);
        vm.prank(node2);
        nodeStaking.stakeNode{value: stake}(cap, 0xaaaa, 0xbbbb);

        // Unstake node2
        vm.prank(node2);
        nodeStaking.unstakeNode();

        (uint256 totalNodes, uint256 totalCapStaked,) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 1, "unstaked node excluded");
        assertEq(totalCapStaked, 1000);
        // nodeList should actually be shorter now (swap-and-pop removal)
        assertEq(nodeStaking.nodeList(0), node1, "remaining node in list");
    }

    // ===== NODE LIST REMOVAL TESTS =====

    function test_UnstakeNode_RemovesFromNodeList() public {
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1234, 0x5678);

        vm.prank(node1);
        nodeStaking.unstakeNode();

        // nodeList should be empty
        (uint256 totalNodes,,) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 0, "nodeList empty after unstake");
    }

    function test_UnstakeNode_SwapAndPop_MiddleNode() public {
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;

        // Stake 3 nodes
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1111, 0x2222);
        vm.prank(node2);
        nodeStaking.stakeNode{value: stake}(cap, 0x3333, 0x4444);
        vm.prank(node3);
        nodeStaking.stakeNode{value: stake}(cap, 0x5555, 0x6666);

        // Unstake the middle node (node2 at index 1)
        vm.prank(node2);
        nodeStaking.unstakeNode();

        // nodeList should now be [node1, node3] (node3 swapped into index 1)
        assertEq(nodeStaking.nodeList(0), node1, "node1 still at index 0");
        assertEq(nodeStaking.nodeList(1), node3, "node3 swapped to index 1");
        assertEq(nodeStaking.nodeIndexInList(node1), 0, "node1 index correct");
        assertEq(nodeStaking.nodeIndexInList(node3), 1, "node3 index correct");

        (uint256 totalNodes,,) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 2, "two nodes remain");
    }

    function test_Restake_AfterUnstake() public {
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1234, 0x5678);

        vm.prank(node1);
        nodeStaking.unstakeNode();

        // Re-stake
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0xaaaa, 0xbbbb);

        assertEq(nodeStaking.nodeList(0), node1, "re-staked node in list");
        assertEq(nodeStaking.nodeIndexInList(node1), 0, "re-staked node index correct");

        (uint256 totalNodes,,) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 1, "one node after re-stake");
    }

    // ===== ONLY-MARKET ACCESS CONTROL =====

    function test_UpdateNodeUsed_RevertNotMarket() public {
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1234, 0x5678);

        vm.prank(node2);
        vm.expectRevert("not market");
        nodeStaking.updateNodeUsed(node1, 0);
    }

    function test_UpdateNodeUsed_RevertNotANode() public {
        vm.expectRevert("not a node");
        nodeStaking.updateNodeUsed(node1, 0);
    }

    // ===== IS VALID NODE =====

    function test_IsValidNode_ReturnsFalse() public view {
        assertFalse(nodeStaking.isValidNode(node1));
    }

    function test_IsValidNode_ReturnsFalseAfterUnstake() public {
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1234, 0x5678);
        assertTrue(nodeStaking.isValidNode(node1));

        vm.prank(node1);
        nodeStaking.unstakeNode();
        assertFalse(nodeStaking.isValidNode(node1));
    }

    // ===== DECREASE CAPACITY TO ZERO — NODE LIST CLEANUP =====

    function test_DecreaseCapacity_ToZero_RemovesFromNodeList() public {
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1234, 0x5678);

        // Decrease capacity all the way to zero
        vm.prank(node1);
        nodeStaking.decreaseCapacity(cap);

        // Node should be fully removed from nodeList and state
        (uint256 s, uint64 c, uint64 u,,) = nodeStaking.getNodeInfo(node1);
        assertEq(s, 0, "stake cleared");
        assertEq(c, 0, "capacity cleared");
        assertEq(u, 0, "used cleared");
        assertFalse(nodeStaking.isValidNode(node1), "no longer valid");

        (uint256 totalNodes, uint256 totalCapStaked, uint256 totalCapUsed) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 0, "nodeList empty");
        assertEq(totalCapStaked, 0);
        assertEq(totalCapUsed, 0);
    }

    function test_DecreaseCapacity_ToZero_ThenRestake_NoDuplicate() public {
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1234, 0x5678);

        // Decrease to zero
        vm.prank(node1);
        nodeStaking.decreaseCapacity(cap);

        // Re-stake the same node
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0xaaaa, 0xbbbb);

        // nodeList should have exactly 1 entry (no duplicate)
        assertEq(nodeStaking.nodeList(0), node1, "re-staked node in list");

        (uint256 totalNodes, uint256 totalCapStaked,) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 1, "exactly one node");
        assertEq(totalCapStaked, cap, "capacity matches single node");
    }

    function test_DecreaseCapacity_ToZero_RefundsDust() public {
        // Stake node with 1000 bytes
        uint64 cap = 1000;
        uint256 stake = uint256(cap) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(cap, 0x1234, 0x5678);

        // Slash an amount that leaves sub-byte dust.
        // Slash 1.5 bytes worth → stake becomes 998.5 * STAKE_PER_BYTE
        // capacity floors to 998, dust = 0.5 * STAKE_PER_BYTE
        uint256 slashAmount = STAKE_PER_BYTE + STAKE_PER_BYTE / 2; // 1.5 * STAKE_PER_BYTE
        nodeStaking.slashNode(node1, slashAmount);

        (uint256 stakeAfterSlash, uint64 capAfterSlash, uint64 usedAfterSlash,,) = nodeStaking.getNodeInfo(node1);
        uint256 expectedDust = stakeAfterSlash - uint256(capAfterSlash) * STAKE_PER_BYTE;
        assertTrue(expectedDust > 0, "precondition: dust must exist");
        assertEq(usedAfterSlash, 0);

        // Decrease all remaining capacity to zero
        uint256 node1BalBefore = node1.balance;
        vm.prank(node1);
        nodeStaking.decreaseCapacity(capAfterSlash);

        // Node should receive capacity*STAKE_PER_BYTE + dust
        uint256 node1BalAfter = node1.balance;
        uint256 expectedRefund = uint256(capAfterSlash) * STAKE_PER_BYTE + expectedDust;
        assertEq(node1BalAfter - node1BalBefore, expectedRefund, "node must receive full refund including dust");

        // Node state must be fully cleaned up
        (uint256 s, uint64 c,,,) = nodeStaking.getNodeInfo(node1);
        assertEq(s, 0, "stake cleared");
        assertEq(c, 0, "capacity cleared");
    }

    // Allow test contract (acting as market) to receive ETH from slashNode
    receive() external payable {}

    // ===== REENTRANCY TESTS =====

    function test_ReentrancyProtection() public {
        // Deploy a malicious contract that tries to reenter
        MaliciousReentrancy malicious = new MaliciousReentrancy(nodeStaking);
        vm.deal(address(malicious), 10 ether);

        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        // First, the malicious contract stakes normally
        malicious.stakeNormally{value: requiredStake}(capacity);

        // The first unstake call will succeed but the reentrancy attempt should fail
        malicious.attackUnstake();

        // Verify the malicious contract was able to detect reentrancy attempt
        assertTrue(malicious.reentrancyDetected());
    }

    // ===== SLASH TO ZERO CAPACITY — RESIDUAL STAKE CLEANUP =====

    /// @notice When slashing leaves capacity == 0 but residual stake > 0 (due to
    /// rounding in stake / STAKE_PER_BYTE), the residual must be burned and the
    /// node cleaned up. Otherwise the node becomes invalid yet cannot unstake,
    /// permanently locking the residual funds.
    function test_SlashNode_ZeroCapacity_BurnsResidualAndCleansUp() public {
        // Stake 2 bytes → stake = 2 * STAKE_PER_BYTE
        uint64 capacity = 2;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        assertTrue(nodeStaking.isValidNode(node1), "node should be valid");

        // Slash just over 1 byte's worth so remaining < STAKE_PER_BYTE → capacity = 0, residual > 0
        uint256 slashAmount = STAKE_PER_BYTE + 1;
        uint256 residual = stake - slashAmount; // STAKE_PER_BYTE - 1
        assertTrue(residual > 0, "should have residual");
        assertTrue(residual < STAKE_PER_BYTE, "residual should not cover 1 byte");

        uint256 burnBalanceBefore = address(0).balance;
        nodeStaking.slashNode(node1, slashAmount);
        uint256 burnBalanceAfter = address(0).balance;

        // Node should be fully cleaned up
        assertFalse(nodeStaking.isValidNode(node1), "node should be invalid");
        (uint256 remainingStake, uint64 cap,,,) = nodeStaking.getNodeInfo(node1);
        assertEq(remainingStake, 0, "stake should be zero after cleanup");
        assertEq(cap, 0, "capacity should be zero");

        // Residual should have been burned
        assertEq(burnBalanceAfter - burnBalanceBefore, residual, "residual burned to address(0)");

        // Node should be removed from nodeList
        (uint256 totalNodes,,) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 0, "node should be removed from nodeList");
    }

    /// @notice When slashing takes the full stake (no residual), the node is
    /// still cleaned up and removed from nodeList.
    function test_SlashNode_ZeroCapacity_NoResidual_CleansUp() public {
        uint64 capacity = 100;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        nodeStaking.updateNodeUsed(node1, capacity);

        // Slash 90% → forced exit → additional 50% capped to remaining → full drain
        uint256 slashAmount = 90 * STAKE_PER_BYTE;
        nodeStaking.slashNode(node1, slashAmount);

        // Node should be fully cleaned up
        assertFalse(nodeStaking.isValidNode(node1), "node should be invalid");
        (uint256 totalNodes,,) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 0, "node removed from nodeList");

        // Node can re-stake without duplicate nodeList entry
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);
        assertTrue(nodeStaking.isValidNode(node1), "node can re-stake");
        (totalNodes,,) = nodeStaking.getNetworkStats();
        assertEq(totalNodes, 1, "exactly one entry in nodeList");
    }

    /// @notice After slash to zero, the node can re-stake without being blocked
    /// by "already staked" since the node entry was deleted.
    function test_SlashNode_ZeroCapacity_CanRestake() public {
        uint64 capacity = 2;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0x1234, 0x5678);

        // Slash to zero capacity with residual
        uint256 slashAmount = STAKE_PER_BYTE + 1;
        nodeStaking.slashNode(node1, slashAmount);

        // Re-stake should succeed (not blocked by "already staked")
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0xAAAA, 0xBBBB);
        assertTrue(nodeStaking.isValidNode(node1), "node should be valid after re-stake");
    }

    // ===== PROOF OBLIGATION LOCK TESTS =====

    /// @notice decreaseCapacity reverts when the market reports an unresolved proof obligation.
    function test_DecreaseCapacity_RevertWhenProverObligated() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0xAAAA, 0xBBBB);

        // Mock the market to return true for node1's obligation check
        vm.mockCall(
            address(this), abi.encodeWithSignature("hasUnresolvedProofObligation(address)", node1), abi.encode(true)
        );

        vm.prank(node1);
        vm.expectRevert("unresolved proof obligation");
        nodeStaking.decreaseCapacity(500);

        // Clear mock — should succeed after obligation resolved
        vm.clearMockedCalls();

        vm.prank(node1);
        nodeStaking.decreaseCapacity(500);
    }

    /// @notice unstakeNode reverts when the market reports an unresolved proof obligation.
    function test_UnstakeNode_RevertWhenProverObligated() public {
        uint64 capacity = 1000;
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(capacity, 0xAAAA, 0xBBBB);

        // Mock the market to return true for node1's obligation check
        vm.mockCall(
            address(this), abi.encodeWithSignature("hasUnresolvedProofObligation(address)", node1), abi.encode(true)
        );

        vm.prank(node1);
        vm.expectRevert("unresolved proof obligation");
        nodeStaking.unstakeNode();

        // Clear mock — should succeed after obligation resolved
        vm.clearMockedCalls();

        vm.prank(node1);
        nodeStaking.unstakeNode();
    }
}

// Malicious contract for testing reentrancy protection
contract MaliciousReentrancy {
    NodeStaking public nodeStaking;
    bool public attacked = false;
    bool public reentrancyDetected = false;

    constructor(NodeStaking _nodeStaking) {
        nodeStaking = _nodeStaking;
    }

    function stakeNormally(uint64 capacity) external payable {
        nodeStaking.stakeNode{value: msg.value}(capacity, 0x1234, 0x5678);
    }

    function attackUnstake() external {
        nodeStaking.unstakeNode();
    }

    // This will be called when we receive ETH from unstaking
    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Try to reenter - this should fail with "reentrant" error
            try nodeStaking.unstakeNode() {
                // If this succeeds, reentrancy protection failed
                reentrancyDetected = false;
            } catch Error(string memory reason) {
                // Check if it failed with the expected reentrancy error
                reentrancyDetected = keccak256(bytes(reason)) == keccak256(bytes("reentrant"));
            }
        }
    }
}
