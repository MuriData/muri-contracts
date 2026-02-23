// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketKeyRotationTest is MarketTestBase {
    uint256 constant OLD_KEY = 0x1234;
    uint256 constant NEW_KEY = 0x5678;
    uint256 constant ANOTHER_KEY = 0x9abc;

    function test_RotateKey_Success() public {
        _stakeDefaultNode(node1, OLD_KEY);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Calculate fee: used=1024, fee = 1024 * 10^14 * 3000 / 10000
        (,, uint64 used,) = nodeStaking.getNodeInfo(node1);
        uint256 fee = uint256(used) * STAKE_PER_BYTE * 3000 / 10000;
        assertGt(fee, 0);

        uint256 burnBalBefore = address(0).balance;

        vm.prank(node1);
        market.rotateNodeKey{value: fee}(NEW_KEY);

        // Verify new key is active
        (,,, uint256 pubKey) = nodeStaking.getNodeInfo(node1);
        assertEq(pubKey, NEW_KEY);

        // Verify old key is freed
        assertEq(nodeStaking.publicKeyOwner(OLD_KEY), address(0));
        assertEq(nodeStaking.publicKeyOwner(NEW_KEY), node1);

        // Verify fee was burned
        assertEq(address(0).balance, burnBalBefore + fee);
    }

    function test_RotateKey_FreeWhenIdle() public {
        _stakeDefaultNode(node1, OLD_KEY);

        // No orders, so used=0, fee=0
        vm.prank(node1);
        market.rotateNodeKey{value: 0}(NEW_KEY);

        (,,, uint256 pubKey) = nodeStaking.getNodeInfo(node1);
        assertEq(pubKey, NEW_KEY);
    }

    function test_RotateKey_RevertsUnderActiveChallenge() public {
        // Bootstrap a challenge — node1 will have active challenge count > 0
        _bootstrapSingleSlotChallenge();

        vm.prank(node1);
        vm.expectRevert("active prover cannot rotate key");
        market.rotateNodeKey{value: 1 ether}(NEW_KEY);
    }

    function test_RotateKey_RevertsInvalidKey() public {
        _stakeDefaultNode(node1, OLD_KEY);

        // Zero key
        vm.prank(node1);
        vm.expectRevert("public key not in field");
        market.rotateNodeKey{value: 0}(0);

        // Out of field (>= SNARK_SCALAR_FIELD)
        uint256 outOfField = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
        vm.prank(node1);
        vm.expectRevert("public key not in field");
        market.rotateNodeKey{value: 0}(outOfField);

        // Already registered key
        _stakeDefaultNode(node2, ANOTHER_KEY);
        vm.prank(node1);
        vm.expectRevert("public key already registered");
        market.rotateNodeKey{value: 0}(ANOTHER_KEY);

        // Same key
        vm.prank(node1);
        vm.expectRevert("same key");
        market.rotateNodeKey{value: 0}(OLD_KEY);
    }

    function test_RotateKey_FeePricing() public {
        _stakeDefaultNode(node1, OLD_KEY);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Expected fee: 1024 bytes * 10^14 * 3000 / 10000 = 1024 * 3 * 10^12
        uint256 expectedFee = uint256(1024) * STAKE_PER_BYTE * 3000 / 10000;

        // Underpayment reverts
        vm.prank(node1);
        vm.expectRevert("insufficient rotation fee");
        market.rotateNodeKey{value: expectedFee - 1}(NEW_KEY);

        // Overpayment: excess goes to pendingRefunds
        uint256 overpay = 0.1 ether;
        vm.prank(node1);
        market.rotateNodeKey{value: expectedFee + overpay}(NEW_KEY);

        assertEq(market.pendingRefunds(node1), overpay);
    }

    function test_RotateKey_ClearsCompromisedFlag() public {
        _stakeDefaultNode(node1, OLD_KEY);

        // Set keyCompromised via storage slot (simulating a key leak report scenario
        // where the node re-staked after being slashed)
        vm.store(
            address(market),
            keccak256(abi.encode(node1, uint256(26))), // keyCompromised mapping at slot 22
            bytes32(uint256(1))
        );
        assertTrue(market.keyCompromised(node1));

        vm.prank(node1);
        market.rotateNodeKey{value: 0}(NEW_KEY);

        assertFalse(market.keyCompromised(node1));
    }

    function test_ResetCompromisedStatus_Success() public {
        _stakeDefaultNode(node1, OLD_KEY);

        // Set keyCompromised flag
        vm.store(address(market), keccak256(abi.encode(node1, uint256(26))), bytes32(uint256(1)));
        assertTrue(market.keyCompromised(node1));

        vm.prank(node1);
        market.resetCompromisedStatus();

        assertFalse(market.keyCompromised(node1));
    }

    function test_ResetCompromisedStatus_RevertsIfNotCompromised() public {
        _stakeDefaultNode(node1, OLD_KEY);

        vm.prank(node1);
        vm.expectRevert("not compromised");
        market.resetCompromisedStatus();
    }

    // --- Self-report key compromise tests ---

    function test_SelfReport_Success() public {
        _stakeDefaultNode(node1, OLD_KEY);

        uint256 blockBefore = block.number;
        vm.prank(node1);
        market.selfReportCompromised();

        assertEq(market.compromiseReportedBlock(node1), blockBefore);
    }

    function test_SelfReport_BlocksSubmitProof() public {
        // Bootstrap a challenge so node1 has an active challenge slot
        _bootstrapSingleSlotChallenge();

        // Self-report
        vm.prank(node1);
        market.selfReportCompromised();

        // Attempt to submit proof — should revert
        uint256[8] memory dummyProof;
        vm.prank(node1);
        vm.expectRevert("key compromise self-reported");
        market.submitProof(0, dummyProof, bytes32(uint256(1)));
    }

    function test_SelfReport_ReportKeyLeakDuringWindow() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        // Self-report
        vm.prank(node1);
        market.selfReportCompromised();

        // Still within the 50-block window — reportKeyLeak should succeed
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS); // exactly at the boundary
        vm.prank(KL_REPORTER);
        market.reportKeyLeak(node1, KL_PROOF);

        assertTrue(market.keyCompromised(node1));
    }

    function test_SelfReport_ReportKeyLeakBlockedAfterWindow() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        // Self-report
        vm.prank(node1);
        market.selfReportCompromised();

        // Advance past the 50-block window
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // reportKeyLeak should now revert
        vm.prank(KL_REPORTER);
        vm.expectRevert("key compromise self-reported");
        market.reportKeyLeak(node1, KL_PROOF);
    }

    function test_SelfReport_ClearedByRotation() public {
        _stakeDefaultNode(node1, OLD_KEY);

        // Self-report
        vm.prank(node1);
        market.selfReportCompromised();
        assertGt(market.compromiseReportedBlock(node1), 0);

        // Rotate key — should clear self-report state
        vm.prank(node1);
        market.rotateNodeKey{value: 0}(NEW_KEY);

        assertEq(market.compromiseReportedBlock(node1), 0);
    }

    function test_SelfReport_RevertsIfAlreadyReported() public {
        _stakeDefaultNode(node1, OLD_KEY);

        vm.prank(node1);
        market.selfReportCompromised();

        vm.prank(node1);
        vm.expectRevert("already self-reported");
        market.selfReportCompromised();
    }

    // Key leak constants (shared with MarketKeyLeak.t.sol)
    uint256 constant KL_PUB_KEY = 0x259115f2259ea0923f1e3a18a4122a606d88ea1c25f49f8766df1aba7864efd1;
    address constant KL_REPORTER = address(0xDEAD);
    bytes constant KL_PROOF =
        hex"1cdaaeacd7cb7adc2cf7d11407946bb7e87ba738c66e8bdcdef7ff60cdab9750127c120e1887f97b948be27c879ee0e1925a491f840de93d4166c10c754744dc0637647fa50cff59fd5eafad4c53ff5a0d50ee1520daabb5a5ba80987fdae72a21d5e873ea17f63d36802824164d908be94bcce9d61568f04dd294c6fb4d31ec01e8cd1584953fa229fc7c8ce3ca781edfc04d340dd8723dc79d5dd8dfdc71910c73f1ae373fdb3bc4618f1c7bd91cd523abc2279803acfc037d0bd1037ef3e91fab59a5959f80bbce53ba3235927fe893d77bd3763f5975f38b81927e4de0431cc5418a4768bcde9eda10c375ec7c8f19bb657d666c7668e94c7ef3e661f3110bf125e7c68f02e3e7de7cd531feded8bbf9b8d0a0ab213f39b08fccf03f485b21897b1fe6b243eebca332428e3a7adac41049bdc00f5f89fa9ee7b8219574be2ae15e0f835baa903c2f32c13d405fd551a3d6838b0b746b6ca82f23c170da412ce8efddda433d6f29654dd23d140a1bf227bbf2c8fe32367e62d4fd2395f5620358b5328ece81d5cbd2a7e1138126598aed9f6fda8d9d73c70887a9c45457de1ee31d74666e7fe7a18f3808c6f27b0d8fcdcdc259263e684309c746d888e5ee168e9d257718c16b6c50da875938a9ef9056859a482c8372f02e4df318551d4b0ee718bd24f9ded532fddf888b09fa7775eddb2964f73cc0414c3aec0cb2abb12a257077b2f5fc287801ef81347b0313b53e416abd3850874b8b0c5333774a430a1846ae0331f822785f9b6d6a7a88414eed35b0a80665ba6ea5375124a48b12029239a0ae18d3f5dd6d5135d94cd2db9fe8bbe8af2e98492ffdc610a983dc1e0e77abdeca71e011f49634ed44f350401eda3f37d9f57d5b0c4318806b5d39d50c72b8a542d6b652ea2c2855e3a987a5f81f6291a46585b9ec359b98bcc8ef4727d520c8d5a9fa9c1f54e5f3e0cf5552421a2182ffdde8294572457f9a559a27066277c06c566e54d723fd2ee91b86b413809c406a8434b85048f9eefa9bd77c195b672e856d59475ca8a62cc57f15477374492e187e0e6f41420fb3ce4c233c";

    function _stakeNodeWithLeakedKey(address node) internal {
        _stakeNode(node, TEST_CAPACITY, KL_PUB_KEY);
    }
}
