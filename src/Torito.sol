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
    enum SupplyStatus { ACTIVE, WITHDRAWN, LOCKED_IN_LOAN }
    enum BorrowStatus { PENDING, PROCESSED, CANCELED, REPAID, DEFAULTED, LIQUIDATED, MARGIN_CALL }

    // Structs
    struct Supply {
        address owner;
        uint256 scaledBalance;
        address token;
        SupplyStatus status;
        uint256 timestamp;
        uint256 lastUpdateTimestamp;
    }

    struct Borrow {
        address owner;
        uint256 borrowedAmount;       // scaled by borrowIndex
        address collateralToken;
        bytes32 fiatCurrency;
        uint256 interestAccrued;      // extra interest not yet rolled into borrowedAmount
        uint256 totalRepaid;
        BorrowStatus status;
        uint256 timestamp;
        uint256 collateralAmount;
        uint256 lastInterestUpdate;
        uint256 lastRepaymentTimestamp;
    }

    struct FiatCurrency {
        bytes32 currency;
        uint256 currencyExchangeRate;
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
        uint256 lastUpdate;  
        uint256 R_entry;     
    }

    uint256 constant RAY = 1e27;

    // Storage
    mapping(address => mapping(address => Supply)) public supplies; 
    mapping(address => mapping(bytes32 => Borrow)) public borrows; 
    mapping(address => address[]) public userTokens; 
    mapping(address => bytes32[]) public userCurrencies; 
    mapping(address => bool) public supportedTokens; 
    mapping(bytes32 => FiatCurrency) public supportedCurrencies; 

    IAavePool public aavePool;
    mapping(address => address) public aTokens;

    // Events
    event SupplyUpdated(address indexed user, address token, uint256 amount, uint256 totalAmount);
    event BorrowUpdated(address indexed user, bytes32 currency, uint256 amount, uint256 totalAmount);
    event LoanRepaid(address indexed user, bytes32 currency, uint256 amount, uint256 remainingAmount);
    event CollateralLiquidated(address indexed user, uint256 collateralAmount);
    event InterestAccrued(address indexed user, bytes32 currency, uint256 interestAmount);
    event ExchangeRateUpdated(uint256 newRate);
    event InterestRateUpdated(uint256 newRate);
    event BorrowProcessed(address indexed user, bytes32 currency);
    event BorrowCanceled(address indexed user, bytes32 currency);

    constructor() { _disableInitializers(); }

    function initialize(address _aavePool, address _owner) public initializer {
        __ReentrancyGuard_init();
        __Ownable_init(_owner);
        __Pausable_init();
        aavePool = IAavePool(_aavePool);
    }

    // --- Admin ---
    function setSupportedToken(address token, bool supported) external onlyOwner {
        supportedTokens[token] = supported;
    }

    function setSupportedCurrency(
        bytes32 currency,
        uint256 currencyExchangeRate,
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
            currencyExchangeRate: currencyExchangeRate,
            oracle: oracle,
            collateralizationRatio: collateralizationRatio,
            liquidationThreshold: liquidationThreshold,
            baseRate: baseRate,
            minRate: minRate,
            maxRate: maxRate,
            sensitivity: sensitivity,
            borrowIndex: RAY,        /// 🔑 start index
            lastUpdate: block.timestamp,
            R_entry: 0
        });
    }

    function updateTokenOracle(bytes32 currency, address oracle) external onlyOwner {
        supportedCurrencies[currency].oracle = oracle;
    }

    function setAToken(address token, address aToken) external onlyOwner {
        aTokens[token] = aToken;
    }

    // --- Interest model ---
    /// 🔑 Compute dynamic rate for a currency
    function getDynamicBorrowRate(bytes32 currency) public view returns (uint256) {
        FiatCurrency storage fc = supportedCurrencies[currency];
        if (fc.oracle == address(0)) return fc.baseRate;

        uint256 priceA = IPriceOracle(fc.oracle).getPrice(fc.currency); // note: adapt if using token pairs
        uint256 priceB = 1e18; // fallback baseline (USD = 1)

        if (priceA == 0 || priceB == 0) return fc.baseRate;

        uint256 R_now = (priceA * 1e18) / priceB;
        if (fc.R_entry == 0) return fc.baseRate;

        int256 delta = int256(R_now) - int256(fc.R_entry);
        int256 rel = (delta * 1e18) / int256(fc.R_entry);
        int256 rate = int256(fc.baseRate) + (rel * int256(fc.sensitivity) / 1e18);

        if (rate < int256(fc.minRate)) rate = int256(fc.minRate);
        if (rate > int256(fc.maxRate)) rate = int256(fc.maxRate);

        return uint256(rate);
    }

    /// 🔑 Update borrowIndex per currency
    function updateBorrowIndex(bytes32 currency) public {
        FiatCurrency storage fc = supportedCurrencies[currency];
        uint256 elapsed = block.timestamp - fc.lastUpdate;
        if (elapsed == 0) return;

        uint256 currentRate = getDynamicBorrowRate(currency);

        fc.borrowIndex = (fc.borrowIndex * (RAY + (currentRate * elapsed) / 365 days)) / RAY;
        fc.lastUpdate = block.timestamp;

        // update ratio snapshot
        if (fc.oracle != address(0)) {
            uint256 priceA = IPriceOracle(fc.oracle).getPrice(fc.currency);
            uint256 priceB = 1e18;
            if (priceA > 0 && priceB > 0) {
                fc.R_entry = (priceA * 1e18) / priceB;
            }
        }
    }

    // --- Supply ---
    function supply(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(supportedTokens[token], "Token not supported");
        require(amount > 0, "Amount > 0");

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        uint256 currentIndex = aavePool.getReserveNormalizedIncome(token);

        IERC20(token).approve(address(aavePool), amount);
        aavePool.supply(token, amount, address(this), 0);

        Supply storage userSupply = supplies[msg.sender][token];
        if (userSupply.owner == address(0)) {
            userSupply.owner = msg.sender;
            userSupply.token = token;
            userSupply.status = SupplyStatus.ACTIVE;
            userSupply.timestamp = block.timestamp;
            userSupply.scaledBalance += (amount * RAY) / currentIndex;
            userTokens[msg.sender].push(token);
        } else {
            userSupply.scaledBalance += (amount * RAY) / currentIndex;
            userSupply.lastUpdateTimestamp = block.timestamp;
        }
        emit SupplyUpdated(msg.sender, token, amount, userSupply.scaledBalance);
    }

    // --- Borrow ---
    function borrow(address collateralToken, uint256 borrowAmount, bytes32 fiatCurrency)
        external nonReentrant whenNotPaused hasSupply(collateralToken)
    {
        require(supportedCurrencies[fiatCurrency].currency != bytes32(0), "Currency not supported");
        updateBorrowIndex(fiatCurrency);  /// 🔑 sync interest

        Supply storage userSupply = supplies[msg.sender][collateralToken];
        require(userSupply.status == SupplyStatus.ACTIVE, "supply not active");

        uint256 requiredCollateralUSD = (borrowAmount * supportedCurrencies[fiatCurrency].collateralizationRatio) / 1e18;
        uint256 collateralValueUSD = getTokenValueUSD(collateralToken, userSupply.scaledBalance, fiatCurrency);
        require(collateralValueUSD >= requiredCollateralUSD, "insufficient collateral");

        Borrow storage userBorrow = borrows[msg.sender][fiatCurrency];
        if (userBorrow.owner == address(0)) {
            userBorrow.owner = msg.sender;
            userBorrow.fiatCurrency = fiatCurrency;
            userBorrow.collateralToken = collateralToken;
            userBorrow.status = BorrowStatus.PENDING;
            userBorrow.timestamp = block.timestamp;
            userBorrow.lastInterestUpdate = block.timestamp;
            userBorrow.borrowedAmount = (borrowAmount * RAY) / supportedCurrencies[fiatCurrency].borrowIndex;  /// 🔑 scaled
            userBorrow.interestAccrued = 0;
            userBorrow.totalRepaid = 0;
            userBorrow.collateralAmount = userSupply.scaledBalance;
            userCurrencies[msg.sender].push(fiatCurrency);
        } else {
            userBorrow.borrowedAmount += (borrowAmount * RAY) / supportedCurrencies[fiatCurrency].borrowIndex; /// 🔑 scaled
            userBorrow.collateralAmount += userSupply.scaledBalance;
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
    function repayLoan(bytes32 currency, uint256 repaymentAmount) external nonReentrant hasBorrow(currency) {
        updateBorrowIndex(currency);  /// 🔑 sync

        Borrow storage loan = borrows[msg.sender][currency];
        require(loan.status == BorrowStatus.PROCESSED, "not processed");

        uint256 totalOwed = (loan.borrowedAmount * supportedCurrencies[currency].borrowIndex) / RAY
            + loan.interestAccrued - loan.totalRepaid;

        require(repaymentAmount <= totalOwed, "exceeds owed");

        loan.totalRepaid += repaymentAmount;
        loan.lastRepaymentTimestamp = block.timestamp;

        if (loan.totalRepaid >= totalOwed) {
            loan.status = BorrowStatus.REPAID;
            supplies[msg.sender][loan.collateralToken].status = SupplyStatus.ACTIVE;
        }

        uint256 remaining = totalOwed - repaymentAmount;
        emit LoanRepaid(msg.sender, currency, repaymentAmount, remaining);
    }

    // --- Liquidation (unchanged except index sync can be added) ---
    function liquidate(address user, bytes32 currency) external nonReentrant {
        Borrow storage loan = borrows[user][currency];
        require(loan.owner != address(0), "no borrow");
        require(loan.status == BorrowStatus.PROCESSED, "not processed");

        uint256 collateralValueUSD = getTokenValueUSD(loan.collateralToken, loan.collateralAmount, loan.fiatCurrency);
        uint256 currencyExchangeRate = supportedCurrencies[loan.fiatCurrency].currencyExchangeRate;
        uint256 threshold = supportedCurrencies[loan.fiatCurrency].liquidationThreshold;

        uint256 outstanding = (loan.borrowedAmount * supportedCurrencies[currency].borrowIndex) / RAY
            + loan.interestAccrued - loan.totalRepaid;
        uint256 debtValueUSD = outstanding * currencyExchangeRate / 1e18;
        uint256 ratio = (collateralValueUSD * 1e18) / debtValueUSD;

        require(ratio < threshold, "not liquidatable");

        loan.status = BorrowStatus.LIQUIDATED;
        emit CollateralLiquidated(user, loan.collateralAmount);
    }

    // --- Views ---
    function getTokenValueUSD(address token, uint256 amount, bytes32 currency) public view returns (uint256) {
        address oracle = supportedCurrencies[currency].oracle;
        require(oracle != address(0), "no oracle");
        uint256 price = IPriceOracle(oracle).getPrice(token);
        return (amount * price) / 1e18;
    }

    function getBorrow(address user, bytes32 currency) external view returns (Borrow memory) {
        return borrows[user][currency];
    }
}
