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
        nodeStaking.stakeNode{value: requiredStake}(capacity);

        (uint256 stake, uint64 nodeCapacity, uint64 used) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, requiredStake);
        assertEq(nodeCapacity, capacity);
        assertEq(used, 0);
    }

    function test_StakeNode_RevertInsufficientStake() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        vm.expectRevert("incorrect stake amount");
        nodeStaking.stakeNode{value: requiredStake - 1}(capacity);
    }

    function test_StakeNode_RevertExcessiveStake() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        vm.expectRevert("incorrect stake amount");
        nodeStaking.stakeNode{value: requiredStake + 1}(capacity);
    }

    function test_StakeNode_RevertCapacityTooLow() public {
        vm.prank(node1);
        vm.expectRevert("capacity too low");
        nodeStaking.stakeNode{value: 0}(0);
    }

    function test_StakeNode_RevertAlreadyStaked() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity);

        vm.prank(node1);
        vm.expectRevert("already staked");
        nodeStaking.stakeNode{value: requiredStake}(capacity);
    }

    // ===== CAPACITY INCREASE TESTS =====

    function test_IncreaseCapacity_Success() public {
        // First stake a node
        uint64 initialCapacity = 1000;
        uint256 initialStake = uint256(initialCapacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: initialStake}(initialCapacity);

        // Then increase capacity
        uint64 additionalCapacity = 500;
        uint256 additionalStake = uint256(additionalCapacity) * STAKE_PER_BYTE;

        vm.expectEmit(true, false, false, true);
        emit NodeCapacityIncreased(node1, additionalStake, initialCapacity + additionalCapacity);

        vm.prank(node1);
        nodeStaking.increaseCapacity{value: additionalStake}(additionalCapacity);

        (uint256 stake, uint64 capacity, uint64 used) = nodeStaking.getNodeInfo(node1);
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
        nodeStaking.stakeNode{value: requiredStake}(capacity);

        vm.prank(node1);
        vm.expectRevert("invalid capacity");
        nodeStaking.increaseCapacity{value: 0}(0);
    }

    // ===== CAPACITY DECREASE TESTS =====

    function test_DecreaseCapacity_Success() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity);

        uint64 reduceCapacity = 300;
        uint256 stakeToRelease = uint256(reduceCapacity) * STAKE_PER_BYTE;
        uint256 initialBalance = node1.balance;

        vm.expectEmit(true, false, false, true);
        emit NodeCapacityDecreased(node1, stakeToRelease, capacity - reduceCapacity);

        vm.prank(node1);
        nodeStaking.decreaseCapacity(reduceCapacity);

        (uint256 stake, uint64 newCapacity, uint64 used) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, requiredStake - stakeToRelease);
        assertEq(newCapacity, capacity - reduceCapacity);
        assertEq(used, 0);
        assertEq(node1.balance, initialBalance + stakeToRelease);
    }

    function test_DecreaseCapacity_RevertCannotReduceBelowUsed() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity);

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
        nodeStaking.stakeNode{value: requiredStake}(capacity);

        uint256 initialBalance = node1.balance;

        vm.expectEmit(true, false, false, true);
        emit NodeUnstaked(node1, requiredStake);

        vm.prank(node1);
        nodeStaking.unstakeNode();

        (uint256 stake, uint64 nodeCapacity, uint64 used) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, 0);
        assertEq(nodeCapacity, 0);
        assertEq(used, 0);
        assertEq(node1.balance, initialBalance + requiredStake);
    }

    function test_UnstakeNode_RevertWhileStoringData() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity);

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
        nodeStaking.stakeNode{value: requiredStake}(capacity);

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
        nodeStaking.stakeNode{value: requiredStake}(capacity);

        nodeStaking.updateNodeUsed(node1, 500);

        (,, uint64 used) = nodeStaking.getNodeInfo(node1);
        assertEq(used, 500);
    }

    function test_UpdateNodeUsed_RevertExceedsCapacity() public {
        uint64 capacity = 1000;
        uint256 requiredStake = uint256(capacity) * STAKE_PER_BYTE;

        vm.prank(node1);
        nodeStaking.stakeNode{value: requiredStake}(capacity);

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
        nodeStaking.stakeNode{value: requiredStake}(capacity);

        (uint256 stake, uint64 nodeCapacity, uint64 used) = nodeStaking.getNodeInfo(node1);
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
        nodeStaking.stakeNode{value: initialStake}(initialCapacity);

        // Increase capacity
        vm.prank(node1);
        nodeStaking.increaseCapacity{value: additionalStake}(increaseBy);

        // Decrease capacity (if possible)
        if (decreaseBy <= initialCapacity + increaseBy) {
            vm.prank(node1);
            nodeStaking.decreaseCapacity(decreaseBy);

            (uint256 finalStake, uint64 finalCapacity,) = nodeStaking.getNodeInfo(node1);
            assertEq(finalCapacity, initialCapacity + increaseBy - decreaseBy);
            assertEq(finalStake, (initialStake + additionalStake) - (uint256(decreaseBy) * STAKE_PER_BYTE));
        }
    }

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
        nodeStaking.stakeNode{value: msg.value}(capacity);
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
