// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceOracle} from "../../src/PriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    mapping(bytes32 => uint256) public prices;

    function setPrice(bytes32 currency, uint256 price) external {
        prices[currency] = price;
    }

    function getPrice(bytes32 currency) external view returns (uint256) {
        return prices[currency];
    }
}
