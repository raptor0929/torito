// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function getLatestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract Torito is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // Enums
    enum SupplyStatus {
        ACTIVE,
        WITHDRAWN,
        LOCKED_IN_LOAN
    }
    enum BorrowStatus {
        PENDING,
        ACTIVE,
        REPAID,
        DEFAULTED,
        LIQUIDATED,
        MARGIN_CALL
    }

    // Main Structs
    struct Supply {
        address owner;
        uint256 amount;
        uint256 aaveLiquidityIndex; // Index at time of supply for yield calculation
        address token;
        SupplyStatus status;
        uint256 timestamp; // When supply was made
        uint256 lastUpdateTimestamp; // Last time supply was updated
    }

    struct Borrow {
        address owner;
        uint256 borrowedAmount; // Amount in fiat currency
        address collateralToken; // Token used as collateral (USDT, etc.)
        bytes32 fiatCurrency; // "USD", "EUR", "BOB", etc.
        uint256 interestAccrued; // Accumulated interest in fiat
        uint256 totalRepaid; // Total amount repaid
        BorrowStatus status;
        uint256 timestamp; // When borrow was created
        uint256 collateralAmount; // Amount of collateral locked
        uint256 lastInterestUpdate; // Last time interest was calculated
        uint256 lastRepaymentTimestamp; // Last time repayment was made
    }

    struct FiatCurrency {
        bytes32 currency;
        uint256 currencyExchangeRate; // Exchange rate to USD (scaled by 1e18)
        uint256 interestRate; // Annual interest rate for this currency (scaled by 1e18)
        address oracle; // Oracle for this currency
        uint256 collateralizationRatio; // Collateralization ratio for this currency (scaled by 1e18)
        uint256 liquidationThreshold; // Liquidation threshold for this currency (scaled by 1e18)
    }

    // Additional essential variables
    // Removed global collateralizationRatio and liquidationThreshold - now per currency

    // Storage
    mapping(address => mapping(address => Supply)) public supplies; // user -> token -> Supply
    mapping(address => mapping(bytes32 => Borrow)) public borrows; // user -> currency -> Borrow
    mapping(address => address[]) public userTokens; // User -> array of tokens supplied
    mapping(address => bytes32[]) public userCurrencies; // User -> array of currencies borrowed
    mapping(address => bool) public supportedTokens; // Supported collateral tokens
    mapping(bytes32 => FiatCurrency) public supportedCurrencies; // Supported fiat currencies

    // Aave integration
    IAavePool public aavePool;
    mapping(address => address) public aTokens; // token -> aToken mapping

    // Events
    event SupplyUpdated(address indexed user, address token, uint256 amount, uint256 totalAmount);
    event BorrowUpdated(address indexed user, bytes32 currency, uint256 amount, uint256 totalAmount);
    event LoanRepaid(address indexed user, bytes32 currency, uint256 amount, uint256 remainingAmount);
    event CollateralLiquidated(address indexed user, uint256 collateralAmount);
    event InterestAccrued(address indexed user, bytes32 currency, uint256 interestAmount);
    event ExchangeRateUpdated(uint256 newRate);
    event InterestRateUpdated(uint256 newRate);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _aavePool, address _owner) public initializer {
        __ReentrancyGuard_init();
        __Ownable_init(_owner);
        __Pausable_init();

        aavePool = IAavePool(_aavePool);
    }

    // Modifiers
    modifier hasSupply(address token) {
        require(supplies[msg.sender][token].owner != address(0), "No supply found for this token");
        _;
    }

    modifier hasBorrow(bytes32 currency) {
        require(borrows[msg.sender][currency].owner != address(0), "No borrow found for this currency");
        _;
    }

    // Admin functions
    function setSupportedToken(address token, bool supported) external onlyOwner {
        supportedTokens[token] = supported;
    }

    function setSupportedCurrency(
        bytes32 currency,
        uint256 currencyExchangeRate,
        uint256 interestRate,
        address oracle,
        uint256 collateralizationRatio,
        uint256 liquidationThreshold
    ) external onlyOwner {
        require(collateralizationRatio >= 100e16, "Collateralization ratio must be at least 100%");
        require(liquidationThreshold >= 100e16, "Liquidation threshold must be at least 100%");
        require(liquidationThreshold <= collateralizationRatio, "Liquidation threshold must be <= collateral ratio");

        supportedCurrencies[currency] = FiatCurrency({
            currency: currency,
            currencyExchangeRate: currencyExchangeRate,
            interestRate: interestRate,
            oracle: oracle,
            collateralizationRatio: collateralizationRatio,
            liquidationThreshold: liquidationThreshold
        });
    }

    // Removed setTokenOracle - oracles are now set per currency
    function updateTokenOracle(bytes32 currency, address oracle) external onlyOwner {
        supportedCurrencies[currency].oracle = oracle;
    }

    function setAToken(address token, address aToken) external onlyOwner {
        aTokens[token] = aToken;
    }

    function updateCurrencyExchangeRate(bytes32 currency, uint256 newRate) external onlyOwner {
        require(supportedCurrencies[currency].currency != bytes32(0), "Currency not supported");
        supportedCurrencies[currency].currencyExchangeRate = newRate;
        emit ExchangeRateUpdated(newRate);
    }

    function updateCurrencyInterestRate(bytes32 currency, uint256 newRate) external onlyOwner {
        require(supportedCurrencies[currency].currency != bytes32(0), "Currency not supported");
        supportedCurrencies[currency].interestRate = newRate;
        emit InterestRateUpdated(newRate);
    }

    function updateCurrencyCollateralizationRatio(bytes32 currency, uint256 ratio) external onlyOwner {
        require(supportedCurrencies[currency].currency != bytes32(0), "Currency not supported");
        require(ratio >= 100e16, "Ratio must be at least 100%");
        supportedCurrencies[currency].collateralizationRatio = ratio;
    }

    function updateCurrencyLiquidationThreshold(bytes32 currency, uint256 threshold) external onlyOwner {
        require(supportedCurrencies[currency].currency != bytes32(0), "Currency not supported");
        require(threshold >= 100e16, "Threshold must be at least 100%");
        require(
            threshold <= supportedCurrencies[currency].collateralizationRatio, "Threshold must be <= collateral ratio"
        );
        supportedCurrencies[currency].liquidationThreshold = threshold;
    }

    // Supply functions
    function supply(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount must be > 0");

        // Transfer tokens from user
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Get current Aave liquidity index
        uint256 liquidityIndex = aavePool.getReserveNormalizedIncome(token);

        // Supply to Aave for yield
        IERC20(token).approve(address(aavePool), amount);
        aavePool.supply(token, amount, address(this), 0);

        // Update or create supply record
        Supply storage userSupply = supplies[msg.sender][token];
        if (userSupply.owner == address(0)) {
            // First time supply for this user and token
            userSupply.owner = msg.sender;
            userSupply.token = token;
            userSupply.status = SupplyStatus.ACTIVE;
            userSupply.timestamp = block.timestamp;
            userSupply.aaveLiquidityIndex = liquidityIndex;
            userSupply.amount = amount;

            // Add token to user's token list
            userTokens[msg.sender].push(token);
        } else {
            // Update existing supply
            userSupply.amount += amount;
            userSupply.lastUpdateTimestamp = block.timestamp;
        }

        emit SupplyUpdated(msg.sender, token, amount, userSupply.amount);
    }

    // Borrow functions
    function borrow(address collateralToken, uint256 borrowAmount, bytes32 fiatCurrency)
        external
        nonReentrant
        whenNotPaused
        hasSupply(collateralToken)
    {
        require(supportedCurrencies[fiatCurrency].currency != bytes32(0), "Currency not supported");

        Supply storage userSupply = supplies[msg.sender][collateralToken];
        require(userSupply.status == SupplyStatus.ACTIVE, "Supply not available");

        // Calculate required collateral in USD using currency-specific ratio
        uint256 currencyCollateralizationRatio = supportedCurrencies[fiatCurrency].collateralizationRatio;
        uint256 requiredCollateralUSD = (borrowAmount * currencyCollateralizationRatio) / 1e18;

        // Get collateral value in USD using oracle
        uint256 collateralValueUSD = getTokenValueUSD(collateralToken, userSupply.amount, fiatCurrency);

        require(collateralValueUSD >= requiredCollateralUSD, "Insufficient collateral");

        // Update or create borrow record
        Borrow storage userBorrow = borrows[msg.sender][fiatCurrency];
        if (userBorrow.owner == address(0)) {
            // First time borrow for this user and currency
            userBorrow.owner = msg.sender;
            userBorrow.fiatCurrency = fiatCurrency;
            userBorrow.collateralToken = collateralToken;
            userBorrow.status = BorrowStatus.ACTIVE;
            userBorrow.timestamp = block.timestamp;
            userBorrow.lastInterestUpdate = block.timestamp;
            userBorrow.borrowedAmount = borrowAmount;
            userBorrow.interestAccrued = 0;
            userBorrow.totalRepaid = 0;
            userBorrow.collateralAmount = userSupply.amount;

            // Add currency to user's currency list
            userCurrencies[msg.sender].push(fiatCurrency);
        } else {
            // Update existing borrow
            userBorrow.borrowedAmount += borrowAmount;
            userBorrow.collateralAmount += userSupply.amount;
        }

        // Lock the supply
        userSupply.status = SupplyStatus.LOCKED_IN_LOAN;

        emit BorrowUpdated(msg.sender, fiatCurrency, borrowAmount, userBorrow.borrowedAmount);
    }

    // Repayment function with partial repayments
    function repayLoan(bytes32 currency, uint256 repaymentAmount) external nonReentrant hasBorrow(currency) {
        Borrow storage loan = borrows[msg.sender][currency];
        require(loan.status == BorrowStatus.ACTIVE, "Loan not active");
        require(repaymentAmount > 0, "Repayment amount must be > 0");

        // Update interest
        updateInterest(currency);

        uint256 totalOwed = loan.borrowedAmount + loan.interestAccrued - loan.totalRepaid;
        require(repaymentAmount <= totalOwed, "Repayment amount exceeds total owed");

        // Update repayment tracking
        loan.totalRepaid += repaymentAmount;
        loan.lastRepaymentTimestamp = block.timestamp;

        // Check if loan is fully repaid
        if (loan.totalRepaid >= loan.borrowedAmount + loan.interestAccrued) {
            loan.status = BorrowStatus.REPAID;

            // Release collateral
            Supply storage collateralSupply = supplies[msg.sender][loan.collateralToken];
            collateralSupply.status = SupplyStatus.ACTIVE;
        }

        uint256 remainingAmount = totalOwed - repaymentAmount;
        emit LoanRepaid(msg.sender, currency, repaymentAmount, remainingAmount);
    }

    // Interest calculation
    function updateInterest(bytes32 currency) public hasBorrow(currency) {
        Borrow storage loan = borrows[msg.sender][currency];
        if (loan.status != BorrowStatus.ACTIVE) return;

        uint256 timeElapsed = block.timestamp - loan.lastInterestUpdate;
        uint256 currencyInterestRate = supportedCurrencies[loan.fiatCurrency].interestRate;
        uint256 outstandingAmount = loan.borrowedAmount - loan.totalRepaid;
        uint256 annualInterest = (outstandingAmount * currencyInterestRate) / 1e18;
        uint256 interestForPeriod = (annualInterest * timeElapsed) / 365 days;

        loan.interestAccrued += interestForPeriod;
        loan.lastInterestUpdate = block.timestamp;

        emit InterestAccrued(msg.sender, currency, interestForPeriod);
    }

    // Liquidation function
    function liquidate(address user, bytes32 currency) external nonReentrant {
        Borrow storage loan = borrows[user][currency];
        require(loan.owner != address(0), "No borrow found");
        require(loan.status == BorrowStatus.ACTIVE, "Loan not active");

        updateInterest(currency);

        // Check if liquidation is warranted using currency-specific threshold
        uint256 collateralValueUSD = getTokenValueUSD(loan.collateralToken, loan.collateralAmount, loan.fiatCurrency);
        uint256 currencyExchangeRate = supportedCurrencies[loan.fiatCurrency].currencyExchangeRate;
        uint256 currencyLiquidationThreshold = supportedCurrencies[loan.fiatCurrency].liquidationThreshold;
        uint256 outstandingAmount = loan.borrowedAmount + loan.interestAccrued - loan.totalRepaid;
        uint256 debtValueUSD = outstandingAmount * currencyExchangeRate / 1e18;
        uint256 collateralRatio = (collateralValueUSD * 1e18) / debtValueUSD;

        require(collateralRatio < currencyLiquidationThreshold, "Loan not eligible for liquidation");

        // Liquidate
        loan.status = BorrowStatus.LIQUIDATED;

        // Withdraw from Aave and transfer to liquidator (simplified)
        // In practice, this would involve a liquidation auction or DEX swap

        emit CollateralLiquidated(user, loan.collateralAmount);
    }

    // View functions
    function getTokenValueUSD(address token, uint256 amount, bytes32 currency) public view returns (uint256) {
        address oracle = supportedCurrencies[currency].oracle;
        require(oracle != address(0), "No oracle for currency");

        uint256 price = IPriceOracle(oracle).getPrice(token);
        return (amount * price) / 1e18;
    }

    function getLoanHealth(address user, bytes32 currency) external view returns (uint256) {
        Borrow storage loan = borrows[user][currency];
        require(loan.owner != address(0), "No borrow found");

        uint256 collateralValueUSD = getTokenValueUSD(loan.collateralToken, loan.collateralAmount, loan.fiatCurrency);
        uint256 currencyExchangeRate = supportedCurrencies[loan.fiatCurrency].currencyExchangeRate;
        uint256 outstandingAmount = loan.borrowedAmount + loan.interestAccrued - loan.totalRepaid;
        uint256 debtValueUSD = outstandingAmount * currencyExchangeRate / 1e18;

        if (debtValueUSD == 0) return type(uint256).max;
        return (collateralValueUSD * 1e18) / debtValueUSD;
    }

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    function getUserCurrencies(address user) external view returns (bytes32[] memory) {
        return userCurrencies[user];
    }

    function getSupply(address user, address token) external view returns (Supply memory) {
        return supplies[user][token];
    }

    function getBorrow(address user, bytes32 currency) external view returns (Borrow memory) {
        return borrows[user][currency];
    }

    // Helper functions for currency management
    function getCurrencyInfo(bytes32 currency) external view returns (FiatCurrency memory) {
        return supportedCurrencies[currency];
    }

    function getCurrencyExchangeRate(bytes32 currency) external view returns (uint256) {
        return supportedCurrencies[currency].currencyExchangeRate;
    }

    function getCurrencyInterestRate(bytes32 currency) external view returns (uint256) {
        return supportedCurrencies[currency].interestRate;
    }

    function getCurrencyCollateralizationRatio(bytes32 currency) external view returns (uint256) {
        return supportedCurrencies[currency].collateralizationRatio;
    }

    function getCurrencyLiquidationThreshold(bytes32 currency) external view returns (uint256) {
        return supportedCurrencies[currency].liquidationThreshold;
    }

    function getCurrencyOracle(bytes32 currency) external view returns (address) {
        return supportedCurrencies[currency].oracle;
    }

    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Withdraw functions for active supplies
    function withdrawSupply(address token, uint256 amount) external nonReentrant hasSupply(token) {
        Supply storage userSupply = supplies[msg.sender][token];
        require(userSupply.status == SupplyStatus.ACTIVE, "Supply not available for withdrawal");
        require(amount <= userSupply.amount, "Amount exceeds supply");

        // Check if user has any active borrows that use this token as collateral
        uint256 totalRequiredCollateral = 0;
        bytes32[] memory userCurrencies = userCurrencies[msg.sender];

        for (uint256 i = 0; i < userCurrencies.length; i++) {
            bytes32 currency = userCurrencies[i];
            Borrow storage borrow = borrows[msg.sender][currency];

            // Only check active borrows that use this token as collateral
            if (borrow.status == BorrowStatus.ACTIVE && borrow.collateralToken == token) {
                // Update interest to get current outstanding amount
                updateInterest(currency);

                uint256 outstandingAmount = borrow.borrowedAmount + borrow.interestAccrued - borrow.totalRepaid;
                uint256 currencyCollateralizationRatio = supportedCurrencies[currency].collateralizationRatio;

                // Calculate required collateral for this borrow
                uint256 requiredCollateralUSD = (outstandingAmount * currencyCollateralizationRatio) / 1e18;

                // Convert USD value to token amount using oracle
                address oracle = supportedCurrencies[currency].oracle;
                uint256 tokenPrice = IPriceOracle(oracle).getPrice(token);
                uint256 requiredCollateralTokens = (requiredCollateralUSD * 1e18) / tokenPrice;

                totalRequiredCollateral += requiredCollateralTokens;
            }
        }

        // Calculate remaining available collateral after withdrawal
        uint256 remainingCollateral = userSupply.amount - amount;
        require(remainingCollateral >= totalRequiredCollateral, "Insufficient collateral remaining for loans");

        // Calculate yield from Aave
        uint256 currentIndex = aavePool.getReserveNormalizedIncome(token);
        uint256 accruedAmount = (userSupply.amount * currentIndex) / userSupply.aaveLiquidityIndex;

        // Calculate proportional withdrawal
        uint256 withdrawalRatio = (amount * 1e18) / userSupply.amount;
        uint256 yieldToWithdraw = (accruedAmount * withdrawalRatio) / 1e18;

        // Withdraw from Aave
        uint256 withdrawnAmount = aavePool.withdraw(token, yieldToWithdraw, msg.sender);

        // Update supply amount
        userSupply.amount -= amount;
        userSupply.lastUpdateTimestamp = block.timestamp;

        // If supply is empty, mark as withdrawn
        if (userSupply.amount == 0) {
            userSupply.status = SupplyStatus.WITHDRAWN;
        }
    }
}
