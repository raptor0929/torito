// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMetaMorpho {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}

contract MockMorphoVault is IMetaMorpho {
    mapping(address => uint256) public reserveNormalizedIncome;
    mapping(address => uint256) public suppliedAmounts;
    mapping(address => uint256) public userShares;
    address public token;

    constructor() {
        token = address(0);
    }

    function setToken(address _token) external {
        token = _token;
    }

    function setReserveNormalizedIncome(address asset, uint256 index) external {
        reserveNormalizedIncome[asset] = index;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        // Transfer tokens from the caller (Torito contract) to this vault
        IERC20(token).transferFrom(msg.sender, address(this), assets);
        suppliedAmounts[token] += assets;
        userShares[receiver] += assets; // 1:1 ratio for simplicity
        return assets;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(userShares[owner] >= shares, "Insufficient shares");
        require(suppliedAmounts[token] >= shares, "Insufficient liquidity");
        userShares[owner] -= shares;
        suppliedAmounts[token] -= shares;
        // In tests, we'll handle the token transfer in the test setup
        return shares;
    }

    function previewRedeem(uint256 shares) external view returns (uint256 assets) {
        return shares; // 1:1 ratio for simplicity
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(userShares[owner] >= assets, "Insufficient shares");
        require(suppliedAmounts[token] >= assets, "Insufficient liquidity");
        userShares[owner] -= assets;
        suppliedAmounts[token] -= assets;
        // Transfer tokens to receiver
        IERC20(token).transfer(receiver, assets);
        return assets; // 1:1 ratio for simplicity
    }

    function previewWithdraw(uint256 assets) external view returns (uint256 shares) {
        return assets; // 1:1 ratio for simplicity
    }

    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        return reserveNormalizedIncome[asset];
    }
}
