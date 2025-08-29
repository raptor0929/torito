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
        string memory initialPrice = vm.envString("INITIAL_USD_PRICE");
        
        if (bytes(initialPrice).length > 0) {
            uint256 priceInWei = _parsePrice(initialPrice);
            bytes32 usdCurrency = bytes32("USD");
            
            oracle.updateCurrencyPrice(usdCurrency, priceInWei);
            console.log("Initial USD price set to:", vm.toString(priceInWei), "wei");
        }

        vm.stopBroadcast();

        console.log("PriceOracle deployment completed!");
        console.log("Update your .env file with ORACLE_CONTRACT_ADDRESS=", address(oracle));
        console.log("Owner address:", vm.addr(deployerPrivateKey));
    }

    /**
     * @notice Parse price string to wei (18 decimals)
     * @param priceStr Price as string (e.g., "12.58")
     * @return Price in wei
     */
    function _parsePrice(string memory priceStr) internal pure returns (uint256) {
        // Simple price parsing - assumes format like "12.58"
        bytes memory priceBytes = bytes(priceStr);
        
        // Find decimal point
        uint256 decimalIndex = type(uint256).max;
        for (uint256 i = 0; i < priceBytes.length; i++) {
            if (priceBytes[i] == ".") {
                decimalIndex = i;
                break;
            }
        }
        
        if (decimalIndex == type(uint256).max) {
            // No decimal point, treat as whole number
            return _stringToUint(priceStr) * 1e18;
        }
        
        // Split into whole and decimal parts
        string memory wholePart = _substring(priceStr, 0, decimalIndex);
        string memory decimalPart = _substring(priceStr, decimalIndex + 1, priceBytes.length);
        
        uint256 whole = _stringToUint(wholePart);
        uint256 decimal = _stringToUint(decimalPart);
        
        // Calculate decimal places
        uint256 decimalPlaces = priceBytes.length - decimalIndex - 1;
        require(decimalPlaces <= 18, "Too many decimal places");
        
        // Convert to wei
        uint256 multiplier = 10 ** (18 - decimalPlaces);
        return whole * 1e18 + decimal * multiplier;
    }

    /**
     * @notice Convert string to uint256
     */
    function _stringToUint(string memory str) internal pure returns (uint256) {
        bytes memory b = bytes(str);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            require(b[i] >= 0x30 && b[i] <= 0x39, "Invalid character");
            result = result * 10 + (uint256(uint8(b[i])) - 0x30);
        }
        return result;
    }

    /**
     * @notice Extract substring from string
     */
    function _substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        require(startIndex <= endIndex, "Invalid start/end index");
        require(endIndex <= strBytes.length, "End index out of bounds");
        
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }
}
