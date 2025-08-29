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
    Torito public torito;

    ERC20Mock public usdc;
    MockAavePool public aavePool;
    MockPriceOracle public priceOracle;

    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

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
            address(priceOracle), // BOB oracle address (replace with actual)
            200e16, // 200% collateralization ratio (higher risk)
            150e16, // 150% liquidation threshold
            10e16, // 10% base rate
            5e16, // 5% min rate
            15e16, // 15% max rate
            25e16 // 25% sensitivity
        );
    }

    // ========== BASIC TESTS ==========

    function test_supply() public {
        // Add USDC as supported token
        torito.setSupportedToken(address(usdc), true);
        
        uint256 supplyAmount = 1000e6; // 1000 USDC
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        
        torito.supply(address(usdc), supplyAmount);
        
        vm.stopPrank();
        
        // Check that Torito received the USDC
        assertEq(usdc.balanceOf(address(aavePool)), supplyAmount, "Aave pool should have received USDC");
        assertEq(usdc.balanceOf(user1), 9000e6, "User1 should have 9000 USDC remaining");
        
        // Check supply data
        (address owner2,, address token, Torito.SupplyStatus status) = torito.supplies(user1, address(usdc));
        assertEq(owner2, user1, "Supply owner should be user1");
        assertEq(token, address(usdc), "Supply token should be USDC");
        assertEq(uint8(status), 0, "Supply status should be ACTIVE");
    }

    function test_borrow() public {
        // Add USDC as supported token
        torito.setSupportedToken(address(usdc), true);
        
        // First supply some collateral
        uint256 supplyAmount = 2000e6; // 2000 USDC collateral
        uint256 borrowAmount = 1000e18; // 1000 BOB (in wei)
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        
        torito.borrow(address(usdc), borrowAmount, bytes32("BOB"));
        vm.stopPrank();
        
        // Check borrow data
        (address borrower,, address collateralToken, bytes32 currency,, Torito.BorrowStatus status) = torito.borrows(user1, bytes32("BOB"));
        assertEq(borrower, user1, "Borrower should be user1");
        assertEq(collateralToken, address(usdc), "Collateral token should be USDC");
        assertEq(currency, bytes32("BOB"), "Currency should be BOB");
        assertEq(uint8(status), 0, "Borrow status should be PENDING");
    }

    function test_repayLoan() public {
        // Add USDC as supported token
        torito.setSupportedToken(address(usdc), true);
        
        // Setup: supply and borrow
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1000e18;
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        torito.borrow(address(usdc), borrowAmount, bytes32("BOB"));
        
        // Process the borrow (simulate owner approval)
        vm.stopPrank();
        vm.prank(owner);
        torito.processBorrow(user1, bytes32("BOB"));
        
        // Repay the loan
        vm.startPrank(user1);
        uint256 repayAmount = 500e18; // Repay half
        torito.repayLoan(bytes32("BOB"), repayAmount);
        vm.stopPrank();
        
        // Check borrow data
        (,,,, uint256 totalRepaid, Torito.BorrowStatus status) = torito.borrows(user1, bytes32("BOB"));
        assertEq(totalRepaid, repayAmount, "Total repaid should match");
        assertEq(uint8(status), 1, "Borrow should still be PROCESSED");
    }

    function test_liquidate() public {
        // Add USDC as supported token
        torito.setSupportedToken(address(usdc), true);
        
        // Setup: user1 supplies collateral and borrows
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1500e18; // High borrow relative to collateral
        
        vm.startPrank(user1);
        usdc.approve(address(torito), supplyAmount);
        torito.supply(address(usdc), supplyAmount);
        torito.borrow(address(usdc), borrowAmount, bytes32("BOB"));
        vm.stopPrank();
        
        // Process the borrow
        vm.prank(owner);
        torito.processBorrow(user1, bytes32("BOB"));
        
        // Simulate price drop to trigger liquidation
        // Set BOB price to 1 (92.04% drop) to make debt worth less
        priceOracle.setPrice(bytes32("BOB"), 1e18); // 1 BOB per USD (92.04% drop)
        
        // User2 liquidates user1
        vm.startPrank(user2);
        torito.liquidate(user1, bytes32("BOB"));
        vm.stopPrank();
        
        // Check that liquidation occurred
        (,,,,, Torito.BorrowStatus status) = torito.borrows(user1, bytes32("BOB"));
        assertEq(uint8(status), 4, "Borrow status should be LIQUIDATED");
    }

    // ========== CONVERSION FUNCTION TESTS ==========

    function test_convertCurrencyToUSD() public view {
        // Test BOB to USD conversion
        // Input: 1257 BOB (18 decimals)
        // Price: 12.57 USD/BOB (18 decimals)
        // Expected: 1257 / 12.57 = 100 USD (6 decimals)
        
        uint256 bobAmount = 1257e18; // 12.57 BOB with 18 decimals
        uint256 usdValue = torito.convertCurrencyToUSD(bytes32("BOB"), bobAmount);
        
        // Expected: (1257e18 / 12.57e18) / 1e18 = 100e18, then / 1e12 = 100e6
        assertEq(usdValue, 100e6, "1257 BOB should equal 100 USD");
        
        // Test with 12.57 BOB
        bobAmount = 1257e16; // 12.57 BOB with 16 decimals
        uint256 oneBobUSD = torito.convertCurrencyToUSD(bytes32("BOB"), bobAmount);
        assertEq(oneBobUSD, 1e6, "12.57 BOB should equal 1 USD");
    }

    function test_convertUSDToCurrency() public view {
        // Test USD to BOB conversion
        // Input: 100 USD (6 decimals)
        // Price: 12.57 USD/BOB (18 decimals)
        // Expected: 100 USD * 12.57 = 1257 BOB (18 decimals)
        
        uint256 usdAmount = 100e6; // 100 USD with 6 decimals
        uint256 bobValue = torito.convertUSDToCurrency(bytes32("BOB"), usdAmount);
        
        // Expected: (100e6 * 12.57e18) / 1e18 = 1257e18
        assertEq(bobValue, 1257e18, "100 USD should equal 1257 BOB");
        
        // Test with 1 USD
        usdAmount = 1e6; // 1 USD with 6 decimals
        bobValue = torito.convertUSDToCurrency(bytes32("BOB"), usdAmount);
        assertEq(bobValue, 1257e16, "1 USD should equal 12.57 BOB"); // 12.57 * 1e16 = 1257e16
    }

    function test_conversionRoundTrip() public view {
        // Test round trip: BOB -> USD -> BOB should give same result
        
        uint256 originalBob = 100e18; // 100 BOB
        uint256 usdValue = torito.convertCurrencyToUSD(bytes32("BOB"), originalBob);
        uint256 backToBob = torito.convertUSDToCurrency(bytes32("BOB"), usdValue);
        
        // Should be very close to original (within rounding error)
        assertApproxEqRel(backToBob, originalBob, 1e15, "Round trip conversion should be accurate");
    }
}
