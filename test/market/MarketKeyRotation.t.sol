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
        uint256 fee = uint256(used) * STAKE_PER_CHUNK * 3000 / 10000;
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
        uint256 expectedFee = uint256(1024) * STAKE_PER_CHUNK * 3000 / 10000;

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
        hex"2c956e7cdf76d454f41135ce99880b8f1cfa47c1a3fb8623c5fc548e2fbacdff28803dacdee363811db870313ebe6711ca204cefcda48a974728eb49c827375e021f4ff28a87707d6f3b3eefd6f7f4f986fc4c2a0e6e6ee1c70e9c707630383a09010d38dd6c712a168def1b9cafcefc7cdb685b6e969b04f984a7b2f87e1870283fc8f5c672a50d8ab5399c84e317e9418ac3b7ab3bb36fa29665809e3867601e464f99c6833f3e40f5c153ccf73bc435c0212f665075603f4411bfb949bdaa0580aa03fd33c48faf3d6a67340cbcdd549ed445f90f64990dac20a8670b0d0e087c7d7d12a9c516e1c203b0c8e63691dbc1cbfa9c3e036c7b66d0da2c828e0e1a7731af35ced890d9573e3b8c8b59ef7c5824e4e7cb9bf1ea135798c29ca4250af6b753b91e673eb70767da66bb1664f9c219b882173b91e95f9c85ad890770095c83f10d5c4ad70be8d274c5593c25965ec285502821138b31fbf87ddb2676127f24cc12689cb02bb4233f06aff140d2a206f8c18ace01abc8e4107a19720308213ffa286b9fb7b616527bab050c20f92ddda563d5094e3285fc5bacbd64642e93599e18942530de35aea760e4b0cbcf47f14d34389b21adb896a12b7941d61764915d769199de7b78c8068e3ecce0335d5ce49ca7b9526657864a05760a470111dfc9f3902981bfeb2a4f711f7cfe8fb72cb40efe1913baff0115b2008d030c5f6924afa1a14fbd523c576f352f3431d0ae7551fb56036ad4b88494d5a0f11958c7a63b2399ced62e20ff10432d45ca12b993ea64698324be38b48d47c34805b8bf895b781d98e4e011cf38071dd41fd310d82fe9664a4010d544d2cffb0323a3c8128a45f25985212e278ed09908ca12bdd0c1b4b50270f28cf50683dd58034e4575b9682c5962431d95a224df249d0e85e23753d41f27b1774246931e0822bb0ae2dbd5842ff59b520a07f83b4e7169a1fc51ee84850447e3b01486310403c88599db891c6f2467f1aef0cab8bd80f88ec4ba75875b91b1a8833a0ea48e0b6ac46a27b51a037409070c07daf4149b150b0b5105d992765280056b132dc3";

    function _stakeNodeWithLeakedKey(address node) internal {
        _stakeNode(node, TEST_CAPACITY, KL_PUB_KEY);
    }
}
