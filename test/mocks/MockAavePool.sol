// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

contract MockAavePool is IAavePool {
    mapping(address => uint256) public reserveNormalizedIncome;
    mapping(address => uint256) public suppliedAmounts;
    
    function setReserveNormalizedIncome(address asset, uint256 index) external {
        reserveNormalizedIncome[asset] = index;
    }
    
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        suppliedAmounts[asset] += amount;
    }
    
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(suppliedAmounts[asset] >= amount, "Insufficient liquidity");
        suppliedAmounts[asset] -= amount;
        IERC20(asset).transfer(to, amount);
        return amount;
    }
    
    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        return reserveNormalizedIncome[asset];
    }
}
