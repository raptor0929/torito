// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPriceOracle {
    function getPrice(bytes32 currency) external view returns (uint256);
}

contract PriceOracle is IPriceOracle, Ownable {
    // Price data structure
    struct PriceData {
        uint256 price;           // Price in wei (18 decimals)
        uint256 timestamp;       // Last update timestamp
    }

    // Mapping from currency symbol to price data
    mapping(bytes32 => PriceData) public priceData;

    // Events
    event PriceUpdated(bytes32 indexed currency, uint256 price, uint256 timestamp);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Update price for a currency symbol (maps to currency)
     * @param currency Currency symbol (e.g., "USD", "BOB")
     * @param price Price in wei (18 decimals)
     */
    function updateCurrencyPrice(bytes32 currency, uint256 price) external onlyOwner {
        priceData[currency] = PriceData({
            price: price,
            timestamp: block.timestamp
        });
        
        emit PriceUpdated(currency, price, block.timestamp);
    }

    /**
     * @notice Get price for a token
     * @param currency Currency symbol
     * @return Price in wei (18 decimals)
     */
    function getPrice(bytes32 currency) external view override returns (uint256) {
        return priceData[currency].price;
    }
}
