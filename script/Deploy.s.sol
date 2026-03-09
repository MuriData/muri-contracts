// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FileMarket} from "../src/Market.sol";
import {FileMarketExtension} from "../src/FileMarketExtension.sol";
import {NodeStaking} from "../src/NodeStaking.sol";

/// @notice Deploys the full MuriData contract suite behind UUPS proxies.
///
/// Two-step deployment resolves circular FileMarket <> NodeStaking reference:
///   1. Deploy NodeStaking impl + proxy (uninitialized)
///   2. Deploy FileMarketExtension (challenges + views)
///   3. Deploy FileMarket impl + proxy (initialized with staking proxy addr)
///   4. Initialize NodeStaking proxy with market proxy addr
///
/// Supports any Foundry signer: --private-key, --account (keystore),
/// --ledger, or --trezor.
contract DeployScript is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        // 1. Deploy NodeStaking implementation + proxy (uninitialized)
        NodeStaking stakingImpl = new NodeStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");

        console.log("NodeStaking Impl:", address(stakingImpl));
        console.log("NodeStaking Proxy:", address(stakingProxy));

        // 2. Deploy FileMarketExtension (challenges + views)
        FileMarketExtension extensionImpl = new FileMarketExtension();
        console.log("FileMarketExtension:", address(extensionImpl));

        // 3. Deploy FileMarket implementation + proxy (initialized with staking proxy addr)
        FileMarket marketImpl = new FileMarket(address(extensionImpl));
        bytes memory marketInitData = abi.encodeCall(
            FileMarket.initialize,
            (deployer, address(stakingProxy))
        );
        ERC1967Proxy marketProxy = new ERC1967Proxy(address(marketImpl), marketInitData);

        console.log("FileMarket Impl:", address(marketImpl));
        console.log("FileMarket Proxy:", address(marketProxy));

        // 4. Initialize NodeStaking proxy with market proxy addr
        NodeStaking(address(stakingProxy)).initialize(address(marketProxy));

        console.log("Deployment complete!");
        console.log("Use FileMarket at:", address(marketProxy));
        console.log("Use NodeStaking at:", address(stakingProxy));

        vm.stopBroadcast();
    }
}
