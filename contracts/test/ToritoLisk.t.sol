// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Torito} from "../src/Torito.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IMetaMorpho} from "../src/Torito.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ToritoLiskTest is Test {
    Torito public torito;

    IERC20 public usdt;
    IMetaMorpho public vault;
    PriceOracle public priceOracle;

    address constant USDT_CA = 0x43F2376D5D03553aE72F4A8093bbe9de4336EB08;
    address constant MORPHO_USDT_VAULT_CA = 0x50cB55BE8cF05480a844642cB979820C847782aE;
    address constant WHALE_USDT_CA = 0x00cD58DEEbd7A2F1C55dAec715faF8aed5b27BF8;

    address public owner;
    address public user1;
    address public user2;
    address public whale;

    function setUp() public {
        // Fork mainnet
        uint256 liskForkBlock = 20_891_898;
        vm.createSelectFork(vm.rpcUrl("lisk"), liskForkBlock);

        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        whale = address(WHALE_USDT_CA);

        usdt = IERC20(USDT_CA); // USDT in Lisk
        vault = IMetaMorpho(MORPHO_USDT_VAULT_CA);

        vm.startPrank(owner);
        priceOracle = new PriceOracle();
        priceOracle.updateCurrencyPrice(bytes32("BOB"), 12570000000000000000); // 12.57 per USD
        vm.stopPrank();

        // Deploy Torito
        torito = new Torito(address(vault), owner);

        vm.startPrank(whale);
        usdt.transfer(user1, 10000e6);
        usdt.transfer(user2, 10000e6);
        vm.stopPrank();

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
        // Add USDT as supported token
        torito.setSupportedToken(address(usdt), true);
        
        uint256 supplyAmount = 1000e6; // 1000 USDT

        console.log("user1 balance", usdt.balanceOf(user1));
        
        vm.startPrank(user1);
        usdt.approve(address(torito), supplyAmount);
        
        torito.supply(address(usdt), supplyAmount);
        
        vm.stopPrank();
        
        // // Check that Torito received the USDT
        // assertEq(usdt.balanceOf(address(vault)), supplyAmount, "Vault should have received USDT");
        // assertEq(usdt.balanceOf(user1), 9000e6, "User1 should have 9000 USDT remaining");
        
        // // Check supply data
        // (address owner2,, address token,, Torito.SupplyStatus status) = torito.supplies(user1, address(usdt));
        // assertEq(owner2, user1, "Supply owner should be user1");
        // assertEq(token, address(usdt), "Supply token should be USDT");
        // assertEq(uint8(status), 0, "Supply status should be ACTIVE");
    }

    function test_borrow() public {
        // Add USDT as supported token
        torito.setSupportedToken(address(usdt), true);
        
        // First supply some collateral
        uint256 supplyAmount = 1e5; // 2000 USDT collateral
        uint256 borrowAmount = 1e16; // 1000 BOB (in wei)
        
        vm.startPrank(user1);
        usdt.approve(address(torito), supplyAmount);
        torito.supply(address(usdt), supplyAmount);
        
        torito.borrow(address(usdt), borrowAmount, bytes32("BOB"));
        vm.stopPrank();
        
        // Check borrow data
        (address borrower,, address collateralToken, bytes32 currency,, Torito.BorrowStatus status) = torito.borrows(user1, bytes32("BOB"));
        assertEq(borrower, user1, "Borrower should be user1");
        assertEq(collateralToken, address(usdt), "Collateral token should be USDT");
        assertEq(currency, bytes32("BOB"), "Currency should be BOB");
        assertEq(uint8(status), 0, "Borrow status should be PENDING");
    }

    function test_repayLoan() public {
        // Add USDT as supported token
        torito.setSupportedToken(address(usdt), true);
        
        // Setup: supply and borrow
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1000e18;
        
        vm.startPrank(user1);
        usdt.approve(address(torito), supplyAmount);
        torito.supply(address(usdt), supplyAmount);
        torito.borrow(address(usdt), borrowAmount, bytes32("BOB"));
        
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
        // Add USDT as supported token
        torito.setSupportedToken(address(usdt), true);
        
        // Setup: user1 supplies collateral and borrows
        uint256 supplyAmount = 2000e6;
        uint256 borrowAmount = 1500e18; // High borrow relative to collateral
        
        vm.startPrank(user1);
        usdt.approve(address(torito), supplyAmount);
        torito.supply(address(usdt), supplyAmount);
        torito.borrow(address(usdt), borrowAmount, bytes32("BOB"));
        vm.stopPrank();
        
        // Process the borrow
        vm.prank(owner);
        torito.processBorrow(user1, bytes32("BOB"));
        
        // Simulate price drop to trigger liquidation
        // Set BOB price to 1 (92.04% drop) to make debt worth less
        vm.prank(owner);
        priceOracle.updateCurrencyPrice(bytes32("BOB"), 1e18); // 1 BOB per USD (92.04% drop)
        
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

    // ========== WITHDRAW SUPPLY TESTS ==========

    function test_withdrawSupply() public {
        // Add USDT as supported token
        torito.setSupportedToken(address(usdt), true);
        
        uint256 supplyAmount = 1000e6; // 1000 USDT
        uint256 withdrawAmount = 500e6; // 500 USDT
        
        vm.startPrank(user1);
        usdt.approve(address(torito), supplyAmount);
        torito.supply(address(usdt), supplyAmount);
        
        // Withdraw half of the supply
        torito.withdrawSupply(address(usdt), withdrawAmount);
        vm.stopPrank();
        
        // Check that user received the withdrawn amount
        assertEq(usdt.balanceOf(user1), 9500e6, "User1 should have 9500 USDT (10000 - 1000 + 500)");
        
        // Check supply data - should still have 500 USDT worth of shares
        (address owner2,, address token,, Torito.SupplyStatus status) = torito.supplies(user1, address(usdt));
        assertEq(owner2, user1, "Supply owner should still be user1");
        assertEq(token, address(usdt), "Supply token should still be USDT");
        assertEq(uint8(status), 0, "Supply status should still be ACTIVE");
    }
}
