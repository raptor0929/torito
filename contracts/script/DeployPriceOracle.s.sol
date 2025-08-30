// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {console} from "forge-std/console.sol";

contract DeployPriceOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the simplified PriceOracle contract
        PriceOracle oracle = new PriceOracle();
        
        console.log("PriceOracle deployed at:", address(oracle));

        // Optional: Set up initial price for USD/BOB if provided
        uint256 initialPrice = vm.envUint("INITIAL_USD_PRICE");
        
        if (initialPrice > 0) {
            uint256 priceInWei = initialPrice;
            bytes32 usdCurrency = bytes32("USD");
            
            oracle.updateCurrencyPrice(usdCurrency, priceInWei);
            console.log("Initial USD price set to:", vm.toString(priceInWei), "wei");
        }

        vm.stopBroadcast();

        console.log("PriceOracle deployment completed!");
        console.log("Update your .env file with ORACLE_CONTRACT_ADDRESS=", address(oracle));
        console.log("Owner address:", vm.addr(deployerPrivateKey));
    }
}
