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
    
    ERC20Mock public usdt;
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
        usdt = new ERC20Mock();
        usdc = new ERC20Mock();
        aavePool = new MockAavePool();
        priceOracle = new MockPriceOracle();
        
        // Deploy implementation
        toritoImplementation = new Torito();
        
        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            Torito.initialize.selector,
            address(aavePool),
            owner
        );
        
        // Deploy transparent proxy
        toritoProxy = new TransparentUpgradeableProxy(
            address(toritoImplementation),
            owner,
            initData
        );
        
        // Cast proxy to Torito interface
        torito = Torito(address(toritoProxy));
        
        // Setup mock tokens
        usdt.mint(user1, 10000e6);
        usdc.mint(user1, 10000e6);
        usdt.mint(user2, 10000e6);
        usdc.mint(user2, 10000e6);
        
        // Setup price oracle
        priceOracle.setPrice(address(usdt), 1e18); // $1 per USDT
        priceOracle.setPrice(address(usdc), 1e18); // $1 per USDC
        
        // Setup Aave pool
        aavePool.setReserveNormalizedIncome(address(usdt), 1e27);
        aavePool.setReserveNormalizedIncome(address(usdc), 1e27);
        
        // Setup supported currencies with their own oracles and risk parameters
        torito.setSupportedCurrency(
            bytes32("USD"), 
            usdExchangeRate, 
            usdInterestRate,
            address(priceOracle), // USD oracle
            150e16,               // 150% collateralization ratio
            120e16                // 120% liquidation threshold
        );
        torito.setSupportedCurrency(
            bytes32("BOB"), 
            bobExchangeRate, 
            bobInterestRate,
            address(priceOracle), // BOB oracle
            200e16,               // 200% collateralization ratio (higher risk)
            150e16                // 150% liquidation threshold
        );
    }

    // Deployment Tests
    function test_Deployment() public {
        assertEq(torito.owner(), owner);
        assertEq(address(torito.aavePool()), address(aavePool));
    }

    function test_InitializationRevert() public {
        Torito newImplementation = new Torito();
        
        // Should revert if trying to initialize again
        bytes memory initData = abi.encodeWithSelector(
            Torito.initialize.selector,
            address(aavePool),
            owner
        );
        
        vm.expectRevert();
        new TransparentUpgradeableProxy(
            address(newImplementation),
            owner,
            initData
        );
    }

    // Admin Function Tests
    function test_SetSupportedToken() public {
        torito.setSupportedToken(address(usdt), true);
        assertTrue(torito.supportedTokens(address(usdt)));
        
        torito.setSupportedToken(address(usdt), false);
        assertFalse(torito.supportedTokens(address(usdt)));
    }

    function test_SetSupportedCurrency() public {
        torito.setSupportedCurrency(
            bytes32("EUR"), 
            1e18, 
            6e16,
            address(priceOracle),
            180e16,  // 180% collateralization ratio
            140e16   // 140% liquidation threshold
        );
        Torito.FiatCurrency memory currency = torito.getCurrencyInfo(bytes32("EUR"));
        assertEq(currency.currency, bytes32("EUR"));
        assertEq(currency.currencyExchangeRate, 1e18);
        assertEq(currency.interestRate, 6e16);
        assertEq(currency.oracle, address(priceOracle));
        assertEq(currency.collateralizationRatio, 180e16);
        assertEq(currency.liquidationThreshold, 140e16);
    }

    function test_UpdateTokenOracle() public {
        torito.updateTokenOracle(bytes32("USD"), address(priceOracle));
        assertEq(torito.getCurrencyInfo(bytes32("USD")).oracle, address(priceOracle));
    }

    function test_UpdateCurrencyExchangeRate() public {
        uint256 newRate = 2e18; // 2:1 rate
        vm.expectEmit(true, false, false, true);
        emit ExchangeRateUpdated(newRate);
        torito.updateCurrencyExchangeRate(bytes32("USD"), newRate);
        assertEq(torito.getCurrencyExchangeRate(bytes32("USD")), newRate);
    }

    function test_UpdateCurrencyInterestRate() public {
        uint256 newRate = 10e16; // 10% rate
        vm.expectEmit(true, false, false, true);
        emit InterestRateUpdated(newRate);
        torito.updateCurrencyInterestRate(bytes32("USD"), newRate);
        assertEq(torito.getCurrencyInterestRate(bytes32("USD")), newRate);
    }

    function test_SetCollateralizationRatio() public {
        uint256 newRatio = 200e16; // 200%
        torito.updateCurrencyCollateralizationRatio(bytes32("USD"), newRatio);
        assertEq(torito.getCurrencyCollateralizationRatio(bytes32("USD")), newRatio);
    }

    function test_SetCollateralizationRatioRevert() public {
        // Should revert if ratio is less than 100%
        vm.expectRevert("Ratio must be at least 100%");
        torito.updateCurrencyCollateralizationRatio(bytes32("USD"), 50e16);
    }

    function test_SetLiquidationThreshold() public {
        uint256 newThreshold = 130e16; // 130%
        torito.updateCurrencyLiquidationThreshold(bytes32("USD"), newThreshold);
        assertEq(torito.getCurrencyLiquidationThreshold(bytes32("USD")), newThreshold);
    }

    function test_SetLiquidationThresholdRevert() public {
        // Should revert if threshold is less than 100%
        vm.expectRevert("Threshold must be at least 100%");
        torito.updateCurrencyLiquidationThreshold(bytes32("USD"), 50e16);
        
        // Should revert if threshold is greater than collateral ratio
        vm.expectRevert("Threshold must be <= collateral ratio");
        torito.updateCurrencyLiquidationThreshold(bytes32("USD"), 200e16);
    }

    // Supply Tests
    function test_Supply() public {
        // Setup
        torito.setSupportedToken(address(usdt), true);
        uint256 supplyAmount = 1000e6;
        
        vm.startPrank(user1);
        usdt.approve(address(torito), supplyAmount);
        
        vm.expectEmit(true, true, false, true);
        emit Torito.SupplyUpdated(user1, address(usdt), supplyAmount, supplyAmount);
        torito.supply(address(usdt), supplyAmount);
        vm.stopPrank();
        
        // Verify supply was created
        Torito.Supply memory supply = torito.getSupply(user1, address(usdt));
        assertEq(supply.owner, user1);
        assertEq(supply.amount, supplyAmount);
        assertEq(supply.token, address(usdt));
        assertEq(uint256(supply.status), uint256(Torito.SupplyStatus.ACTIVE));
    }

    function test_SupplyRevertUnsupportedToken() public {
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        
        vm.expectRevert("Token not supported");
        torito.supply(address(usdt), 1000e6);
        vm.stopPrank();
    }

    function test_SupplyRevertZeroAmount() public {
        torito.setSupportedToken(address(usdt), true);
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        
        vm.expectRevert("Amount must be > 0");
        torito.supply(address(usdt), 0);
        vm.stopPrank();
    }

    // Borrow Tests
    function test_Borrow() public {
        // Setup supply first
        torito.setSupportedToken(address(usdt), true);
        
        uint256 supplyAmount = 1000e6;
        uint256 borrowAmount = 500; // $500 USD
        
        vm.startPrank(user1);
        usdt.approve(address(torito), supplyAmount);
        torito.supply(address(usdt), supplyAmount);
        
        vm.expectEmit(true, true, false, true);
        emit Torito.BorrowUpdated(user1, bytes32("USD"), borrowAmount, borrowAmount);
        torito.borrow(address(usdt), borrowAmount, bytes32("USD"));
        vm.stopPrank();
        
        // Verify borrow was created
        Torito.Borrow memory borrow = torito.getBorrow(user1, bytes32("USD"));
        assertEq(borrow.owner, user1);
        assertEq(borrow.borrowedAmount, borrowAmount);
        assertEq(borrow.collateralToken, address(usdt));
        assertEq(borrow.fiatCurrency, bytes32("USD"));
        assertEq(uint256(borrow.status), uint256(Torito.BorrowStatus.ACTIVE));
    }

    function test_BorrowRevertUnsupportedCurrency() public {
        // Setup supply first
        torito.setSupportedToken(address(usdt), true);
        torito.updateTokenOracle(bytes32("USD"), address(priceOracle));
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        torito.supply(address(usdt), 1000e6);
        
        vm.expectRevert("Currency not supported");
        torito.borrow(address(usdt), 500, bytes32("EUR"));
        vm.stopPrank();
    }

    function test_BorrowRevertInsufficientCollateral() public {
        // Setup supply first
        torito.setSupportedToken(address(usdt), true);
        
        uint256 supplyAmount = 100e6; // $100 worth
        uint256 borrowAmount = 200; // $200 USD (exceeds collateral)
        
        vm.startPrank(user1);
        usdt.approve(address(torito), supplyAmount);
        torito.supply(address(usdt), supplyAmount);
        
        vm.expectRevert("Insufficient collateral");
        torito.borrow(address(usdt), borrowAmount, bytes32("USD"));
        vm.stopPrank();
    }

    // Interest Calculation Tests
    function test_UpdateInterest() public {
        // Setup borrow
        torito.setSupportedToken(address(usdt), true);
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        torito.supply(address(usdt), 1000e6);
        torito.borrow(address(usdt), 500, bytes32("USD"));
        vm.stopPrank();
        
        // Fast forward time
        vm.warp(block.timestamp + 365 days);
        
        // Update interest
        torito.updateInterest(bytes32("USD"));
        
        (,,,,uint256 interestAccrued,,,,,,) = torito.borrows(user1, bytes32("USD"));
        assertGt(interestAccrued, 0);
    }

    // Repayment Tests
    function test_RepayLoan() public {
        // Setup borrow
        torito.setSupportedToken(address(usdt), true);
        
        uint256 borrowAmount = 500;
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        torito.supply(address(usdt), 1000e6);
        torito.borrow(address(usdt), borrowAmount, bytes32("USD"));
        
        // Update interest
        torito.updateInterest(bytes32("USD"));
        
        vm.expectEmit(true, true, false, true);
        emit Torito.LoanRepaid(user1, bytes32("USD"), borrowAmount, 0);
        torito.repayLoan(bytes32("USD"), borrowAmount);
        vm.stopPrank();
        
        Torito.Borrow memory borrow = torito.getBorrow(user1, bytes32("USD"));
        assertEq(uint256(borrow.status), uint256(Torito.BorrowStatus.REPAID));
    }

    // View Function Tests
    function test_GetTokenValueUSD() public {
        uint256 amount = 1000e6;
        uint256 value = torito.getTokenValueUSD(address(usdt), amount, bytes32("USD"));
        assertEq(value, 1000e18); // $1000 worth
    }

    function test_GetLoanHealth() public {
        // Setup borrow
        torito.setSupportedToken(address(usdt), true);
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        torito.supply(address(usdt), 1000e6);
        torito.borrow(address(usdt), 500, bytes32("USD"));
        vm.stopPrank();
        
        uint256 health = torito.getLoanHealth(user1, bytes32("USD"));
        assertGt(health, 1e18); // Should be above 100%
    }

    function test_GetUserTokens() public {
        torito.setSupportedToken(address(usdt), true);
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 2000e6);
        torito.supply(address(usdt), 1000e6);
        torito.supply(address(usdt), 1000e6); // This will update existing supply
        vm.stopPrank();
        
        address[] memory tokens = torito.getUserTokens(user1);
        assertEq(tokens.length, 1); // Only one token (USDT)
        assertEq(tokens[0], address(usdt));
    }

    function test_GetUserCurrencies() public {
        // Setup borrows
        torito.setSupportedToken(address(usdt), true);
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 2000e6);
        torito.supply(address(usdt), 1000e6);
        torito.borrow(address(usdt), 500, bytes32("USD"));
        torito.borrow(address(usdt), 300, bytes32("BOB")); // This will update existing borrow
        vm.stopPrank();
        
        bytes32[] memory currencies = torito.getUserCurrencies(user1);
        assertEq(currencies.length, 2); // Two currencies (USD and BOB)
        assertEq(currencies[0], bytes32("USD"));
        assertEq(currencies[1], bytes32("BOB"));
    }
    
    function test_CurrencySpecificRates() public {
        // Test that different currencies can have different rates
        assertEq(torito.getCurrencyExchangeRate(bytes32("USD")), usdExchangeRate);
        assertEq(torito.getCurrencyInterestRate(bytes32("USD")), usdInterestRate);
        assertEq(torito.getCurrencyExchangeRate(bytes32("BOB")), bobExchangeRate);
        assertEq(torito.getCurrencyInterestRate(bytes32("BOB")), bobInterestRate);
        
        // Update rates for specific currency
        uint256 newUsdRate = 2e18;
        uint256 newBobRate = 15e16;
        
        torito.updateCurrencyExchangeRate(bytes32("USD"), newUsdRate);
        torito.updateCurrencyInterestRate(bytes32("BOB"), newBobRate);
        
        assertEq(torito.getCurrencyExchangeRate(bytes32("USD")), newUsdRate);
        assertEq(torito.getCurrencyInterestRate(bytes32("BOB")), newBobRate);
        
        // Other currency rates should remain unchanged
        assertEq(torito.getCurrencyExchangeRate(bytes32("BOB")), bobExchangeRate);
        assertEq(torito.getCurrencyInterestRate(bytes32("USD")), usdInterestRate);
    }
    
    function test_CurrencySpecificRiskParameters() public {
        // Test that different currencies can have different risk parameters
        assertEq(torito.getCurrencyCollateralizationRatio(bytes32("USD")), 150e16);
        assertEq(torito.getCurrencyLiquidationThreshold(bytes32("USD")), 120e16);
        assertEq(torito.getCurrencyCollateralizationRatio(bytes32("BOB")), 200e16);
        assertEq(torito.getCurrencyLiquidationThreshold(bytes32("BOB")), 150e16);
        
        // Update risk parameters for specific currency
        uint256 newUsdCollateralRatio = 180e16;
        uint256 newBobLiquidationThreshold = 160e16;
        
        torito.updateCurrencyCollateralizationRatio(bytes32("USD"), newUsdCollateralRatio);
        torito.updateCurrencyLiquidationThreshold(bytes32("BOB"), newBobLiquidationThreshold);
        
        assertEq(torito.getCurrencyCollateralizationRatio(bytes32("USD")), newUsdCollateralRatio);
        assertEq(torito.getCurrencyLiquidationThreshold(bytes32("BOB")), newBobLiquidationThreshold);
        
        // Other currency parameters should remain unchanged
        assertEq(torito.getCurrencyCollateralizationRatio(bytes32("BOB")), 200e16);
        assertEq(torito.getCurrencyLiquidationThreshold(bytes32("USD")), 120e16);
    }

    // Pause/Unpause Tests
    function test_PauseUnpause() public {
        torito.pause();
        assertTrue(torito.paused());
        
        torito.unpause();
        assertFalse(torito.paused());
    }

    function test_PausedSupplyRevert() public {
        torito.setSupportedToken(address(usdt), true);
        torito.pause();
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        
        vm.expectRevert("Pausable: paused");
        torito.supply(address(usdt), 1000e6);
        vm.stopPrank();
    }

    // Withdrawal Tests
    function test_WithdrawSupply() public {
        torito.setSupportedToken(address(usdt), true);
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        torito.supply(address(usdt), 1000e6);
        
        torito.withdrawSupply(address(usdt), 100e6);
        vm.stopPrank();
        
        (,,,,Torito.SupplyStatus status,,) = torito.supplies(user1, address(usdt));
        assertEq(uint256(status), uint256(Torito.SupplyStatus.WITHDRAWN));
    }

    function test_WithdrawSupplyRevertNotOwner() public {
        torito.setSupportedToken(address(usdt), true);
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        torito.supply(address(usdt), 1000e6);
        vm.stopPrank();
        
        vm.startPrank(user2);
        vm.expectRevert("Not supply owner");
        torito.withdrawSupply(address(usdt), 100e6);
        vm.stopPrank();
    }

    function test_PartialRepayment() public {
        // Setup borrow
        torito.setSupportedToken(address(usdt), true);
        
        uint256 borrowAmount = 1000;
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 2000e6);
        torito.supply(address(usdt), 2000e6);
        torito.borrow(address(usdt), borrowAmount, bytes32("USD"));
        
        // Update interest
        torito.updateInterest(bytes32("USD"));
        
        // Partial repayment
        uint256 partialRepayment = 300;
        vm.expectEmit(true, true, false, true);
        emit Torito.LoanRepaid(user1, bytes32("USD"), partialRepayment, borrowAmount - partialRepayment);
        torito.repayLoan(bytes32("USD"), partialRepayment);
        
        // Check borrow status
        Torito.Borrow memory borrow = torito.getBorrow(user1, bytes32("USD"));
        assertEq(borrow.totalRepaid, partialRepayment);
        assertEq(uint256(borrow.status), uint256(Torito.BorrowStatus.ACTIVE)); // Still active
        
        // Full repayment
        uint256 remainingAmount = borrowAmount - partialRepayment;
        vm.expectEmit(true, true, false, true);
        emit Torito.LoanRepaid(user1, bytes32("USD"), remainingAmount, 0);
        torito.repayLoan(bytes32("USD"), remainingAmount);
        
        // Check borrow status
        borrow = torito.getBorrow(user1, bytes32("USD"));
        assertEq(uint256(borrow.status), uint256(Torito.BorrowStatus.REPAID));
        vm.stopPrank();
    }
    
    function test_WithdrawSupplyRevertNotActive() public {
        torito.setSupportedToken(address(usdt), true);
        
        vm.startPrank(user1);
        usdt.approve(address(torito), 1000e6);
        torito.supply(address(usdt), 1000e6);
        torito.borrow(address(usdt), 500, bytes32("USD")); // This locks the supply
        
        vm.expectRevert("Supply not available for withdrawal");
        torito.withdrawSupply(address(usdt), 100e6);
        vm.stopPrank();
    }
}
