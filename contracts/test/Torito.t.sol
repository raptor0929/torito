// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Torito} from "../src/Torito.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

contract ToritoTest is Test {
    Torito public toritoImplementation;
    TransparentUpgradeableProxy public toritoProxy;
    ProxyAdmin public proxyAdmin;
    Torito public torito;

    ERC20Mock public usdc;
    MockAavePool public aavePool;
    MockPriceOracle public priceOracle;

    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    // Currency rates - now per currency
    uint256 public usdExchangeRate = 1e18; // 1:1 USD rate
    uint256 public usdInterestRate = 5e16; // 5% annual interest rate
    uint256 public bobExchangeRate = 76923076923076923; // 1:13 BOB rate (1/13 * 1e18)
    uint256 public bobInterestRate = 8e16; // 8% annual interest rate

    event SupplyCreated(uint256 indexed supplyId, address indexed user, address token, uint256 amount);
    event BorrowCreated(uint256 indexed borrowId, address indexed user, uint256 amount, string currency);
    event LoanRepaid(uint256 indexed borrowId, uint256 amount);
    event ExchangeRateUpdated(uint256 newRate);
    event InterestRateUpdated(uint256 newRate);

    function setUp() public {
        // Deploy mock contracts
        usdc = new ERC20Mock();
        aavePool = new MockAavePool();
        priceOracle = new MockPriceOracle();

        // Deploy Torito
        torito = new Torito(address(aavePool), owner);

        // Setup mock tokens
        usdc.mint(user1, 10000e6);
        usdc.mint(user2, 10000e6);

        // Setup price oracle
        priceOracle.setPrice(bytes32("BOB"), 12570000000000000000); // 12.57 per USD

        // Setup Aave pool
        aavePool.setReserveNormalizedIncome(address(usdc), 1e27);

        torito.addSupportedCurrency(
            bytes32("BOB"),
            76923076923076923, // Exchange rate (1:13)
            address(priceOracle), // BOB oracle address (replace with actual)
            200e16, // 200% collateralization ratio (higher risk)
            150e16, // 150% liquidation threshold
            10e16, // 10% base rate
            5e16, // 5% min rate
            15e16, // 15% max rate
            25e16 // 25% sensitivity
        );
    }

    // ========== SUPPLY TESTS ==========
    
    function test_supply() public {
        uint256 supplyAmount = 1000e6; // 1000 USDC
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        
        uint256 supplyId = torito.supply(address(usdc), supplyAmount);
        
        vm.stopPrank();
        
        assertEq(supplyId, 1, "Supply ID should be 1");
        assertEq(usdc.balanceOf(address(torito)), supplyAmount, "Torito should have received USDC");
        assertEq(usdc.balanceOf(user1), 9000e6, "User1 should have 9000 USDC remaining");
    }
    
    function test_supply_multiple() public {
        uint256 supplyAmount = 500e6; // 500 USDC each
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount * 2);
        
        uint256 supplyId1 = torito.supply(address(usdc), supplyAmount);
        uint256 supplyId2 = torito.supply(address(usdc), supplyAmount);
        
        vm.stopPrank();
        
        assertEq(supplyId1, 1, "First supply ID should be 1");
        assertEq(supplyId2, 2, "Second supply ID should be 2");
        assertEq(usdc.balanceOf(address(torito)), supplyAmount * 2, "Torito should have received total USDC");
    }
    
    function test_supply_insufficient_balance() public {
        uint256 supplyAmount = 20000e6; // More than user has
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        
        vm.expectRevert();
        torito.supply(address(usdc), supplyAmount);
        
        vm.stopPrank();
    }
    
    function test_supply_insufficient_allowance() public {
        uint256 supplyAmount = 1000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount - 1); // Less than needed
        
        vm.expectRevert();
        torito.supply(address(usdc), supplyAmount);
        
        vm.stopPrank();
    }

    // ========== BORROW TESTS ==========
    
    function test_borrow() public {
        // First supply some collateral
        uint256 supplyAmount = 2000e6; // 2000 USDC collateral
        uint256 borrowAmount = 1000e18; // 1000 BOB (in wei)
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        uint256 supplyId = torito.supply(address(usdc), supplyAmount);
        
        uint256 borrowId = torito.borrow(bytes32("BOB"), borrowAmount);
        vm.stopPrank();
        
        assertEq(borrowId, 1, "Borrow ID should be 1");
        
        // Check borrow data
        (address borrower, uint256 amount, bytes32 currency, uint256 borrowIndex, bool isActive) = torito.borrows(borrowId);
        assertEq(borrower, user1, "Borrower should be user1");
        assertEq(amount, borrowAmount, "Borrow amount should match");
        assertEq(currency, bytes32("BOB"), "Currency should be BOB");
        assertTrue(isActive, "Borrow should be active");
    }
    
    function test_borrow_insufficient_collateral() public {
        uint256 supplyAmount = 100e6; // 100 USDC collateral (too little)
        uint256 borrowAmount = 1000e18; // 1000 BOB (too much)
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        
        vm.expectRevert();
        torito.borrow(bytes32("BOB"), borrowAmount);
        
        vm.stopPrank();
    }
    
    function test_borrow_unsupported_currency() public {
        uint256 supplyAmount = 2000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        
        vm.expectRevert();
        torito.borrow(bytes32("EUR"), 1000e18); // EUR not supported
        
        vm.stopPrank();
    }
    
    function test_borrow_multiple() public {
        uint256 supplyAmount = 3000e6;
        uint256 borrowAmount = 500e18;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        
        uint256 borrowId1 = torito.borrow(bytes32("BOB"), borrowAmount);
        uint256 borrowId2 = torito.borrow(bytes32("BOB"), borrowAmount);
        
        vm.stopPrank();
        
        assertEq(borrowId1, 1, "First borrow ID should be 1");
        assertEq(borrowId2, 2, "Second borrow ID should be 2");
    }

    // ========== REPAY LOAN TESTS ==========
    
    function test_repayLoan() public {
        // Setup: supply and borrow
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1000e18;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        uint256 borrowId = torito.borrow(bytes32("BOB"), borrowAmount);
        
        // Repay the loan
        uint256 repayAmount = 500e18; // Repay half
        torito.repayLoan(borrowId, repayAmount);
        vm.stopPrank();
        
        // Check borrow data
        (address borrower, uint256 amount, bytes32 currency, uint256 borrowIndex, bool isActive) = torito.borrows(borrowId);
        assertEq(amount, borrowAmount - repayAmount, "Remaining amount should be reduced");
        assertTrue(isActive, "Borrow should still be active");
    }
    
    function test_repayLoan_full() public {
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1000e18;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        uint256 borrowId = torito.borrow(bytes32("BOB"), borrowAmount);
        
        // Repay full amount
        torito.repayLoan(borrowId, borrowAmount);
        vm.stopPrank();
        
        // Check borrow data
        (address borrower, uint256 amount, bytes32 currency, uint256 borrowIndex, bool isActive) = torito.borrows(borrowId);
        assertEq(amount, 0, "Amount should be 0 after full repayment");
        assertFalse(isActive, "Borrow should be inactive after full repayment");
    }
    
    function test_repayLoan_insufficient_amount() public {
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1000e18;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        uint256 borrowId = torito.borrow(bytes32("BOB"), borrowAmount);
        
        // Try to repay more than borrowed
        vm.expectRevert();
        torito.repayLoan(borrowId, borrowAmount + 100e18);
        
        vm.stopPrank();
    }
    
    function test_repayLoan_inactive_borrow() public {
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1000e18;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        uint256 borrowId = torito.borrow(bytes32("BOB"), borrowAmount);
        
        // Repay full amount first
        torito.repayLoan(borrowId, borrowAmount);
        
        // Try to repay again
        vm.expectRevert();
        torito.repayLoan(borrowId, 100e18);
        
        vm.stopPrank();
    }

    // ========== LIQUIDATE TESTS ==========
    
    function test_liquidate() public {
        // Setup: user1 supplies collateral and borrows
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1500e18; // High borrow relative to collateral
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        uint256 supplyId = torito.supply(address(usdc), supplyAmount);
        uint256 borrowId = torito.borrow(bytes32("BOB"), borrowAmount);
        vm.stopPrank();
        
        // Simulate price drop to trigger liquidation
        // Set USDC price to 0.5 (50% drop) to make collateral worth less
        priceOracle.setPrice(address(usdc), 0.5e18);
        
        // User2 liquidates user1
        vm.startPrank(user2);
        torito.liquidate(borrowId, user1);
        vm.stopPrank();
        
        // Check that liquidation occurred
        // Note: You might need to adjust this based on your actual liquidation logic
        // and what state changes occur during liquidation
    }
    
    function test_liquidate_not_liquidatable() public {
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 500e18; // Low borrow, should not be liquidatable
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        uint256 borrowId = torito.borrow(bytes32("BOB"), borrowAmount);
        vm.stopPrank();
        
        // Try to liquidate when not liquidatable
        vm.startPrank(user2);
        vm.expectRevert();
        torito.liquidate(borrowId, user1);
        vm.stopPrank();
    }
    
    function test_liquidate_inactive_borrow() public {
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1000e18;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        uint256 borrowId = torito.borrow(bytes32("BOB"), borrowAmount);
        
        // Repay full amount first
        torito.repayLoan(borrowId, borrowAmount);
        vm.stopPrank();
        
        // Try to liquidate inactive borrow
        vm.startPrank(user2);
        vm.expectRevert();
        torito.liquidate(borrowId, user1);
        vm.stopPrank();
    }

    // ========== HELPER TESTS ==========
    
    function test_getUserTotalSupply() public {
        uint256 supplyAmount = 1000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        vm.stopPrank();
        
        uint256 totalSupply = torito.getUserTotalSupply(user1);
        assertEq(totalSupply, supplyAmount, "Total supply should match");
    }
    
    function test_getUserTotalBorrow() public {
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1000e18;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        torito.borrow(bytes32("BOB"), borrowAmount);
        vm.stopPrank();
        
        uint256 totalBorrow = torito.getUserTotalBorrow(user1);
        assertEq(totalBorrow, borrowAmount, "Total borrow should match");
    }
    
    function test_getDynamicBorrowRate() public {
        uint256 rate = torito.getDynamicBorrowRate(bytes32("BOB"));
        assertGt(rate, 0, "Dynamic rate should be greater than 0");
        
        // Test with different oracle prices
        priceOracle.setPrice(address(usdc), 0.8e18); // USDC down 20%
        uint256 rateDown = torito.getDynamicBorrowRate(bytes32("BOB"));
        assertGt(rateDown, rate, "Rate should be higher when USDC is down");
        
        priceOracle.setPrice(address(usdc), 1.2e18); // USDC up 20%
        uint256 rateUp = torito.getDynamicBorrowRate(bytes32("BOB"));
        assertLt(rateUp, rate, "Rate should be lower when USDC is up");
    }
}
