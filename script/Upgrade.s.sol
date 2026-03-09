// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FileMarket} from "../src/Market.sol";
import {FileMarketExtension} from "../src/FileMarketExtension.sol";
import {FileMarketExtension2} from "../src/FileMarketExtension2.sol";
import {NodeStaking} from "../src/NodeStaking.sol";

/// @notice Reusable UUPS upgrade script for FileMarket and NodeStaking proxies.
///
/// Required env vars:
///   MARKET_PROXY   — FileMarket proxy address
///   STAKING_PROXY  — NodeStaking proxy address
///
/// Supports any Foundry signer: --private-key, --account (keystore),
/// --ledger, or --trezor. Caller must be the FileMarket owner.
contract UpgradeScript is Script {
    /// @dev ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        address marketProxy = vm.envAddress("MARKET_PROXY");
        address stakingProxy = vm.envAddress("STAKING_PROXY");

        address oldMarketImpl = address(uint160(uint256(vm.load(marketProxy, IMPL_SLOT))));
        address oldStakingImpl = address(uint160(uint256(vm.load(stakingProxy, IMPL_SLOT))));

        console.log("=== UUPS Upgrade ===");
        console.log("FileMarket proxy:", marketProxy);
        console.log("  old impl:", oldMarketImpl);
        console.log("NodeStaking proxy:", stakingProxy);
        console.log("  old impl:", oldStakingImpl);

        vm.startBroadcast();

        // Deploy new extensions and implementations
        FileMarketExtension2 newExtension2 = new FileMarketExtension2();
        FileMarketExtension newExtension = new FileMarketExtension(address(newExtension2));
        FileMarket newMarketImpl = new FileMarket(address(newExtension));
        NodeStaking newStakingImpl = new NodeStaking();

        console.log("  new FileMarketExtension2:", address(newExtension2));
        console.log("  new FileMarketExtension:", address(newExtension));
        console.log("  new FileMarket impl:", address(newMarketImpl));
        console.log("  new NodeStaking impl:", address(newStakingImpl));

        // Upgrade proxies (empty data = pure implementation swap, no reinitializer)
        FileMarket(payable(marketProxy)).upgradeToAndCall(address(newMarketImpl), "");
        NodeStaking(stakingProxy).upgradeToAndCall(address(newStakingImpl), "");

        vm.stopBroadcast();

        // Verify
        address verifyMarket = address(uint160(uint256(vm.load(marketProxy, IMPL_SLOT))));
        address verifyStaking = address(uint160(uint256(vm.load(stakingProxy, IMPL_SLOT))));
        console.log("Verified FileMarket impl:", verifyMarket);
        console.log("Verified NodeStaking impl:", verifyStaking);
        console.log("Upgrade complete!");
    }
}
