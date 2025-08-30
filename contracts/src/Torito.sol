// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "./PriceOracle.sol";
import {console} from "forge-std/console.sol";

// Morpho vault interface
interface IMetaMorpho {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}

contract Torito is Ownable {
    // Enums
    enum SupplyStatus { ACTIVE, INACTIVE, LOCKED_IN_LOAN }
    enum BorrowStatus { PENDING, PROCESSED, CANCELED, REPAID, LIQUIDATED }

    // Structs
    struct Supply {
        address owner;
        uint256 shares;
        address token;
        bytes32 borrowFiatCurrency;
        SupplyStatus status;
    }

    struct Borrow {
        address owner;
        uint256 borrowedAmount;       // scaled by borrowIndex (includes interest)
        address collateralToken;
        bytes32 fiatCurrency;
        uint256 totalRepaid;
        BorrowStatus status;
    }

    struct FiatCurrency {
        bytes32 currency;
        uint256 collateralizationRatio;
        uint256 liquidationThreshold;
        address oracle;

        /// 🔑 Dynamic interest config
        uint256 baseRate;      
        uint256 minRate;
        uint256 maxRate;
        uint256 sensitivity;

        /// 🔑 Borrow index tracking
        uint256 borrowIndex; 
        uint256 lastUpdateBorrowIndex;     
    }

    uint256 constant RAY = 1e27;

    // Storage
    mapping(address => mapping(address => Supply)) public supplies; // user => token => supply
    mapping(address => mapping(bytes32 => Borrow)) public borrows; // user => currency => borrow
    mapping(address => bool) public supportedTokens; 
    mapping(bytes32 => FiatCurrency) public supportedCurrencies;

    IMetaMorpho public vault;

    // Events
    event SupplyUpdated(address indexed user, address token, uint256 amount, uint256 totalAmount);
    event BorrowUpdated(address indexed user, bytes32 currency, uint256 amount, uint256 totalAmount);
    event LoanRepaid(address indexed user, bytes32 currency, uint256 amount, uint256 remainingAmount);
    event CollateralLiquidated(address indexed user, uint256 collateralAmount);
    event BorrowProcessed(address indexed user, bytes32 currency);
    event BorrowCanceled(address indexed user, bytes32 currency);

    constructor(address _vault, address _owner) Ownable(_owner) {
        vault = IMetaMorpho(_vault);
    }

    // --- Admin ---
    function setSupportedToken(address token, bool supported) external onlyOwner {
        supportedTokens[token] = supported;
        IERC20(token).approve(address(vault), type(uint256).max);
    }

    function addSupportedCurrency(
        bytes32 currency,
        address oracle,
        uint256 collateralizationRatio,
        uint256 liquidationThreshold,
        uint256 baseRate,
        uint256 minRate,
        uint256 maxRate,
        uint256 sensitivity
    ) external onlyOwner {
        require(collateralizationRatio >= 100e16, "collat >= 100%");
        require(liquidationThreshold >= 100e16, "liq >= 100%");
        require(liquidationThreshold <= collateralizationRatio, "liq <= collat");

        supportedCurrencies[currency] = FiatCurrency({
            currency: currency,
            oracle: oracle,
            collateralizationRatio: collateralizationRatio,
            liquidationThreshold: liquidationThreshold,
            baseRate: baseRate,
            minRate: minRate,
            maxRate: maxRate,
            sensitivity: sensitivity,
            borrowIndex: RAY,        /// 🔑 start index
            lastUpdateBorrowIndex: block.timestamp
        });
    }

    function updateCurrencyOracle(bytes32 currency, address oracle) external onlyOwner {
        supportedCurrencies[currency].oracle = oracle;
    }

    modifier hasSupply(address user, address token) {
        require(supplies[user][token].owner != address(0), "no supply");
        _;
    }

    modifier hasBorrow(address user, bytes32 currency) {
        require(borrows[user][currency].owner != address(0), "no borrow");
        _;
    }

    // --- Interest model ---
    /// 🔑 Compute dynamic rate for a currency using linear interpolation
    function getDynamicBorrowRate(bytes32 currency) public view returns (uint256) {
        FiatCurrency storage fc = supportedCurrencies[currency];
        if (fc.oracle == address(0)) return fc.baseRate;

        uint256 bobPriceUSD = convertCurrencyToUSD(fc.currency, 1e18);
        if (bobPriceUSD == 0) return fc.baseRate;

        // Linear interpolation: when BOB down = rates down, BOB up = rates up
        // We add to baseRate when BOB price increases
        uint256 rate = fc.baseRate + ((bobPriceUSD - 1e18) * fc.sensitivity) / 1e18;
        
        return rate > fc.maxRate ? fc.maxRate : (rate < fc.minRate ? fc.minRate : rate);
    }

    /// 🔑 Update borrowIndex per currency
    function updateBorrowIndex(bytes32 currency) public {
        FiatCurrency storage fc = supportedCurrencies[currency];
        uint256 elapsed = block.timestamp - fc.lastUpdateBorrowIndex;
        if (elapsed == 0) return;

        uint256 currentRate = getDynamicBorrowRate(currency);

        fc.borrowIndex = (fc.borrowIndex * (RAY + (currentRate * elapsed) / 365 days)) / RAY;
        fc.lastUpdateBorrowIndex = block.timestamp;
    }

    // --- Supply ---
    function supply(address token, uint256 amount) external {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount > 0");

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        console.log("torito balance", IERC20(token).balanceOf(address(this)));

        // Ensure vault has approval to spend Torito's tokens
        IERC20(token).approve(address(vault), amount);

        uint256 shares = vault.deposit(amount, address(this));
        console.log("shares", shares);
        console.log("amount", amount);

        Supply storage userSupply = supplies[msg.sender][token];
        if (userSupply.owner == address(0)) {
            userSupply.owner = msg.sender;
            userSupply.token = token;
            userSupply.status = SupplyStatus.ACTIVE;
            userSupply.shares = shares;
        } else {
            userSupply.shares += shares;
        }
        emit SupplyUpdated(msg.sender, token, amount, userSupply.shares);
    }

    function withdrawSupply(address token, uint256 assetsToWithdraw) external hasSupply(msg.sender, token) {
        Supply storage userSupply = supplies[msg.sender][token];
        require(vault.previewWithdraw(assetsToWithdraw) <= userSupply.shares, "Insufficient shares");
        require(assetsToWithdraw > 0, "Amount > 0");

        // Check if supply is locked in a loan
        if (userSupply.status == SupplyStatus.LOCKED_IN_LOAN) {
            Borrow storage loan = borrows[msg.sender][userSupply.borrowFiatCurrency];

            // Calculate health factor before withdrawal
            uint256 currentCollateralValueUSD = vault.previewRedeem(userSupply.shares);
            uint256 outstandingDebt = (loan.borrowedAmount * 
                supportedCurrencies[loan.fiatCurrency].borrowIndex) / RAY - 
                loan.totalRepaid;
            uint256 debtValueUSD = convertCurrencyToUSD(loan.fiatCurrency, outstandingDebt);
    
            // Calculate health factor after withdrawal
            uint256 newCollateralValueUSD = currentCollateralValueUSD - assetsToWithdraw;
            // health factor = collateral / debt
            uint256 healthFactor = (newCollateralValueUSD * 1e18) / debtValueUSD;

            require(healthFactor > 1e18, "Health factor must be > 1 after withdrawal");
        }

        // Withdraw from vault
        uint256 sharesBurned = vault.withdraw(assetsToWithdraw, msg.sender, address(this));
        
        // Update user supply
        userSupply.shares -= sharesBurned;
        
        // If no shares left, reset the supply
        if (userSupply.shares == 0) {
            userSupply.owner = address(0);
            userSupply.token = address(0);
            userSupply.status = SupplyStatus.ACTIVE;
        }

        emit SupplyUpdated(msg.sender, token, assetsToWithdraw, userSupply.shares);
    }

    // --- Borrow ---
    function borrow(address collateralToken, uint256 borrowAmount, bytes32 fiatCurrency)
        external hasSupply(msg.sender, collateralToken)
    {
        require(supportedCurrencies[fiatCurrency].currency != bytes32(0), "Currency not supported");
        updateBorrowIndex(fiatCurrency);  /// 🔑 sync interest

        Supply storage userSupply = supplies[msg.sender][collateralToken];
        require(userSupply.status == SupplyStatus.ACTIVE, "supply not active");

        // Convert borrow amount from BOB to USD (in 6 decimals for USDC)
        uint256 borrowValueUSD = convertCurrencyToUSD(fiatCurrency, borrowAmount);
        uint256 requiredCollateralUSD = (borrowValueUSD * supportedCurrencies[fiatCurrency].collateralizationRatio) / 1e18;

        // USDC collateral value in USD (USDC = USD, 1:1)
        uint256 currentCollateralValueUSD = vault.previewRedeem(userSupply.shares);
        require(currentCollateralValueUSD >= requiredCollateralUSD, "insufficient collateral");

        Borrow storage userBorrow = borrows[msg.sender][fiatCurrency];
        if (userBorrow.owner == address(0)) {
            userBorrow.owner = msg.sender;
            userBorrow.fiatCurrency = fiatCurrency;
            userBorrow.collateralToken = collateralToken;
            userBorrow.status = BorrowStatus.PENDING;
            userBorrow.borrowedAmount = (borrowAmount * RAY) / supportedCurrencies[fiatCurrency].borrowIndex;  /// 🔑 scaled
            userBorrow.totalRepaid = 0;
        } else {
            userBorrow.borrowedAmount += (borrowAmount * RAY) / supportedCurrencies[fiatCurrency].borrowIndex; /// 🔑 scaled
        }
        userSupply.status = SupplyStatus.LOCKED_IN_LOAN;
        emit BorrowUpdated(msg.sender, fiatCurrency, borrowAmount, userBorrow.borrowedAmount);
    }

    function processBorrow(address user, bytes32 currency) external onlyOwner {
        borrows[user][currency].status = BorrowStatus.PROCESSED;
        emit BorrowProcessed(user, currency);
    }

    function cancelBorrow(address user, bytes32 currency) external onlyOwner {
        borrows[user][currency].status = BorrowStatus.CANCELED;
        emit BorrowCanceled(user, currency);
    }

    // --- Repay ---
    function repayLoan(bytes32 currency, uint256 repaymentAmount) external hasBorrow(msg.sender, currency) {
        updateBorrowIndex(currency);  /// 🔑 sync

        Borrow storage loan = borrows[msg.sender][currency];
        require(loan.status == BorrowStatus.PROCESSED, "not processed");

        uint256 totalOwed = (loan.borrowedAmount * supportedCurrencies[currency].borrowIndex) / RAY
            - loan.totalRepaid;

        require(repaymentAmount <= totalOwed, "exceeds owed");

        loan.totalRepaid += repaymentAmount;

        if (loan.totalRepaid >= totalOwed) {
            loan.status = BorrowStatus.REPAID;
            supplies[msg.sender][loan.collateralToken].status = SupplyStatus.ACTIVE;
        }

        uint256 remaining = totalOwed - repaymentAmount;
        emit LoanRepaid(msg.sender, currency, repaymentAmount, remaining);
    }

    // --- Liquidation (unchanged except index sync can be added) ---
    function liquidate(address user, bytes32 currency) external {
        Borrow storage loan = borrows[user][currency];
        require(loan.owner != address(0), "no borrow");
        require(loan.status == BorrowStatus.PROCESSED, "not processed");

        // Get current USDC collateral value from user's scaled balance
        Supply storage userSupply = supplies[user][loan.collateralToken];
        uint256 collateralValueUSD = vault.previewRedeem(userSupply.shares);

        uint256 threshold = supportedCurrencies[loan.fiatCurrency].liquidationThreshold;

        uint256 outstanding = (loan.borrowedAmount * supportedCurrencies[currency].borrowIndex) / RAY
            - loan.totalRepaid;
        
        // Convert outstanding BOB debt to USD
        uint256 debtValueUSD = convertCurrencyToUSD(currency, outstanding);
        uint256 ratio = (collateralValueUSD * 1e18) / debtValueUSD;

        require(ratio < threshold, "not liquidatable");

        loan.status = BorrowStatus.LIQUIDATED;
        emit CollateralLiquidated(user, userSupply.shares);
    }

    // Convert FROM currency TO USD (returns in 6 decimals for USDC compatibility)
    function convertCurrencyToUSD(bytes32 currency, uint256 amount) public view returns (uint256) {
        uint256 price = IPriceOracle(supportedCurrencies[currency].oracle).getPrice(currency);
        return (amount * 1e18) / price / 1e12;
    }

    // Convert FROM USD TO currency
    function convertUSDToCurrency(bytes32 currency, uint256 usdAmount) public view returns (uint256) {
        uint256 price = IPriceOracle(supportedCurrencies[currency].oracle).getPrice(currency);
        return (usdAmount * price) / 1e6;
    }

    function getBorrow(address user, bytes32 currency) external view returns (Borrow memory) {
        return borrows[user][currency];
    }
}
