// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function getLatestRoundData() external view returns (
        uint80 roundId,
        int256 price,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;
    
    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }
    
    function getPrice(address token) external view returns (uint256) {
        return prices[token];
    }
    
    function getLatestRoundData() external view returns (
        uint80 roundId,
        int256 price,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        // Return mock data - not used in current tests but required by interface
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}
