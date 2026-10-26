// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CircleFactory} from "../src/CircleFactory.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {PositionMarket} from "../src/PositionMarket.sol";
import {SwapContributor} from "../src/SwapContributor.sol";
import {ICircleFactory} from "../src/interfaces/ICircleFactory.sol";
import {IV2Router02} from "../src/interfaces/IV2Router02.sol";

/// @notice Deploys the whole protocol.
/// Env: OWNER, TREASURY, V2_ROUTER, optional FEE_BPS (default 50 = 0.5 %) and MARKET_FEE_BPS (default 250).
/// Usage (keystore account, no private key in .env):
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --account deployer --broadcast --verify
contract Deploy is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        address router = vm.envAddress("V2_ROUTER");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(50)));
        uint16 marketFeeBps = uint16(vm.envOr("MARKET_FEE_BPS", uint256(250)));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        // NFT and registry are deployed first with the factory's pre-computed address.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        PositionNFT nft = new PositionNFT(predicted);
        ReputationRegistry reputation = new ReputationRegistry(predicted);
        CircleFactory factory = new CircleFactory(owner, treasury, feeBps, nft, reputation);
        require(address(factory) == predicted, "factory address mismatch");

        PositionMarket market = new PositionMarket(owner, treasury, marketFeeBps, ICircleFactory(address(factory)), nft);
        SwapContributor contributor = new SwapContributor(IV2Router02(router), ICircleFactory(address(factory)));
        vm.stopBroadcast();

        console.log("PositionNFT       ", address(nft));
        console.log("ReputationRegistry", address(reputation));
        console.log("CircleFactory     ", address(factory));
        console.log("PositionMarket    ", address(market));
        console.log("SwapContributor   ", address(contributor));
        console.log("Next: OWNER must call factory.setTokenAllowed(USDC/EURC) and setVaultAllowed(vault)");
    }
}
