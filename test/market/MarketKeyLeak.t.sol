// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketKeyLeakTest is MarketTestBase {
    // Deterministic fixture values from `go run ./cmd/export keyleak` (sk=12345, reporter=0xDEAD)
    uint256 constant KL_PUB_KEY = 0x23711d48e08f5ea81d4c9f514ff8aa889adb5cab4130e70dbfd4925c363c5054;
    address constant KL_REPORTER = address(0xDEAD);

    bytes constant KL_PROOF =
        hex"28c075e3c0f1dab20ec05269b21829dff9252c6ce9aad21fee7fade23676a1f61c9109ba0f3ef6ccb13d1e4316b21e4bc3bf7ae9b22f71d6068f4388d1290c872c3fe5c2c4d414caa750416c2a3d06112a7bca7033780e488c51a729d2f2faf220d42ae63c78246a796cf67291150921f59a2edd999eb0edef7a24c5831ed5250d98d00770a8ef2c60c995289746422bbf801d20c85818cd5cfd24ab1f14ec89238a15c85344141d65ae3f70745dc620d6a18628e42f39714aababeb2126e8a5196a7334084fbde536bc3d6681ea0dd921f8f43b54910bd25eb01414e2657f36048353cc2fea7ef1e0e43c847bc9ae5b7797acf74b0c7198accfb06688b8400b04630dc34e090021a4cd712a6993818ce538fb3c8e853c3282c196af3c279fac154f93e4dee39ec41e53064205f7532bf2786d47f8a5d2bd69b19f183f13ca29029fcf195d2f344f4f36cf18b104f7e58a2a74bdbe7bbc0a1492eb52ab908ccb0b9a4b851d01af801585d8061973347a91e9181b69b7e142fb0e923f15bceccd0179fd140677875064d55f26176ae2f67442fd1157f1f44bf3a7ad0781bdf6931b10a2598385e14796d0a3cb7990992831d2f5f1fd03e74fa92ceb745560a54b0d4ee6807089df57d80cc0958a17d478b5e842e17a7b4c08dbae04f04801018616eca602fb27b4deb6a80dc4e8e516cd7764502e6a48a3ef083a82ff4a04350421891f46eb0f004fd2d78d5b3513bf7061e519e07fa74583af1626d4dadf881f076aae90f2af25138f4108295ffb004a25380c5fc049a71b881b67a159fc255206740ead2530d5253ca53a0ec0f503c5bd74fc84b6d61dff09b9d6196624a65e04ca4b7ee4d6cc2be1f9a74543235e34a84f6db7277834ce0b9219cdaf39724813ba0924a6f6763366ce8befd02e8a5ff3ce51751cc4ee1583e1e17d959d69f8177b4a27216d4aca8d95f715de0a694d51410fdbe8b890d15681709958b293db2858aace658c8d15597bbfe460e91e6a673332ef3299bf7164ca5ea6a528023c0df53c38bc95ae63b50d197704bde0ae7b24776559095130179b21fcaeb7232f";

    function _stakeNodeWithLeakedKey(address node) internal {
        _stakeNode(node, TEST_CAPACITY, KL_PUB_KEY);
    }

    function test_ReportKeyLeak_Success() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        vm.prank(KL_REPORTER);
        marketExt.reportKeyLeak(node1, KL_PROOF);

        // Node should be removed (full-stake slash)
        assertFalse(nodeStaking.isValidNode(node1));
    }

    function test_ReportKeyLeak_SlashesFullStake() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        assertGt(stakeBefore, 0);

        vm.prank(KL_REPORTER);
        marketExt.reportKeyLeak(node1, KL_PROOF);

        // Node should be removed (no longer valid)
        assertFalse(nodeStaking.isValidNode(node1));
    }

    function test_ReportKeyLeak_ReporterGetsReward() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        vm.prank(KL_REPORTER);
        marketExt.reportKeyLeak(node1, KL_PROOF);

        uint256 reward = market.reporterPendingRewards(KL_REPORTER);
        assertGt(reward, 0, "reporter should have pending reward");
    }

    function test_ReportKeyLeak_ForcedExitOnActiveOrders() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        // Place and execute an order so node1 has an active assignment
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        _executeOrder(node1, orderId);

        vm.prank(KL_REPORTER);
        marketExt.reportKeyLeak(node1, KL_PROOF);

        // Node should be fully removed — no active orders
        assertFalse(nodeStaking.isValidNode(node1));
    }

    function test_ReportKeyLeak_RevertDoubleReport() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        vm.prank(KL_REPORTER);
        marketExt.reportKeyLeak(node1, KL_PROOF);

        vm.expectRevert("not a valid node");
        vm.prank(KL_REPORTER);
        marketExt.reportKeyLeak(node1, KL_PROOF);
    }

    function test_ReportKeyLeak_RevertInvalidProof() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        // Corrupt the proof by flipping some bytes
        bytes memory badProof = KL_PROOF;
        badProof[0] = bytes1(uint8(badProof[0]) ^ 0xFF);
        badProof[1] = bytes1(uint8(badProof[1]) ^ 0xFF);

        vm.prank(KL_REPORTER);
        vm.expectRevert();
        marketExt.reportKeyLeak(node1, badProof);
    }

    function test_ReportKeyLeak_RevertNotANode() public {
        vm.deal(KL_REPORTER, 1 ether);

        vm.expectRevert("not a valid node");
        vm.prank(KL_REPORTER);
        marketExt.reportKeyLeak(node1, KL_PROOF);
    }

    function test_ReportKeyLeak_RevertWrongReporter() public {
        _stakeNodeWithLeakedKey(node1);

        // Call from user1 instead of KL_REPORTER — proof was generated for 0xDEAD
        vm.prank(user1);
        vm.expectRevert();
        marketExt.reportKeyLeak(node1, KL_PROOF);
    }
}
