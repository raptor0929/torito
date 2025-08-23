# 🐂 Torito - Decentralized Lending Protocol

Torito is a decentralized lending protocol built on Ethereum that enables users to supply collateral tokens and borrow fiat currencies with flexible repayment options and per-currency risk management.

## 🚀 Features

### Core Functionality
- **Collateral Supply**: Users can supply supported tokens (USDT, USDC, etc.) to earn yield through Aave integration
- **Fiat Currency Borrowing**: Borrow multiple fiat currencies (USD, EUR, BOB, etc.) against supplied collateral
- **Partial Repayments**: Flexible loan repayment system allowing users to repay loans in installments
- **Per-Currency Configuration**: Each fiat currency has its own exchange rate, interest rate, and risk parameters

### Risk Management
- **Dynamic LTV (Loan-to-Value)**: Real-time collateralization ratio checks using price oracles
- **Currency-Specific Risk Parameters**: 
  - Collateralization ratios per currency
  - Liquidation thresholds per currency
  - Interest rates per currency
- **Liquidation System**: Automated liquidation of undercollateralized positions
- **Supply Health Checks**: Prevents withdrawal of collateral needed for active loans

### Technical Features
- **Upgradeable Architecture**: Uses OpenZeppelin's Transparent Proxy pattern for future upgrades
- **Oracle Integration**: Price feeds for accurate collateral valuation
- **Aave Integration**: Yield generation through Aave's lending pool
- **Reentrancy Protection**: Secure against reentrancy attacks
- **Pausable**: Emergency pause functionality for security

## 🏗️ Architecture

### Smart Contracts

#### `Torito.sol` - Main Contract
The core lending protocol contract with the following key components:

**Storage Structure:**
- `supplies[user][token]` - User's supply records per token
- `borrows[user][currency]` - User's borrow records per currency
- `supportedCurrencies[currency]` - Per-currency configuration

**Key Structs:**
```solidity
struct Supply {
    address owner;
    uint256 amount;
    uint256 aaveLiquidityIndex;
    address token;
    SupplyStatus status;
    uint256 timestamp;
    uint256 lastUpdateTimestamp;
}

struct Borrow {
    address owner;
    uint256 borrowedAmount;
    address collateralToken;
    bytes32 fiatCurrency;
    uint256 interestAccrued;
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
    uint256 interestRate;
    address oracle;
    uint256 collateralizationRatio;
    uint256 liquidationThreshold;
}
```

### Mock Contracts
- `MockAavePool.sol` - Simulates Aave lending pool interactions
- `MockPriceOracle.sol` - Provides price feeds for testing

## 📋 Usage

### For Users

#### 1. Supply Collateral
```solidity
// Approve tokens first
usdt.approve(address(torito), amount);
// Supply tokens
torito.supply(address(usdt), amount);
```

#### 2. Borrow Fiat Currency
```solidity
// Borrow USD against USDT collateral
torito.borrow(address(usdt), borrowAmount, bytes32("USD"));
```

#### 3. Repay Loan (Partial or Full)
```solidity
// Partial repayment
torito.repayLoan(bytes32("USD"), partialAmount);
// Full repayment
torito.repayLoan(bytes32("USD"), fullAmount);
```

#### 4. Withdraw Supply
```solidity
// Withdraw available supply (respects LTV requirements)
torito.withdrawSupply(address(usdt), amount);
```

### For Administrators

#### 1. Configure Supported Currencies
```solidity
torito.setSupportedCurrency(
    bytes32("USD"),
    1e18,           // Exchange rate to USD
    50000000000000000, // 5% annual interest rate
    oracleAddress,  // Price oracle
    1500000000000000000, // 150% collateralization ratio
    1300000000000000000  // 130% liquidation threshold
);
```

#### 2. Update Risk Parameters
```solidity
torito.updateCurrencyInterestRate(bytes32("USD"), newRate);
torito.updateCurrencyCollateralizationRatio(bytes32("USD"), newRatio);
torito.updateCurrencyLiquidationThreshold(bytes32("USD"), newThreshold);
```

## 🔧 Development

### Prerequisites
- [Foundry](https://getfoundry.sh/) - Ethereum development toolkit
- Node.js (for testing)

### Setup
```bash
# Clone the repository
git clone <repository-url>
cd torito

# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test
```

### Testing
```bash
# Run all tests
forge test

# Run specific test
forge test --match-test test_Supply

# Run with verbose output
forge test -vvv
```

### Deployment
```bash
# Deploy to local network
forge script script/Torito.s.sol:ToritoScript --rpc-url http://localhost:8545 --private-key <private_key>

# Deploy to testnet
forge script script/Torito.s.sol:ToritoScript --rpc-url <testnet_rpc> --private-key <private_key> --broadcast
```

## 🔒 Security Features

### Access Control
- `OwnableUpgradeable` - Administrative functions restricted to owner
- `PausableUpgradeable` - Emergency pause functionality
- `ReentrancyGuardUpgradeable` - Protection against reentrancy attacks

### Risk Management
- **LTV Checks**: Prevents over-collateralization
- **Oracle Integration**: Real-time price feeds for accurate valuations
- **Liquidation System**: Automated protection against bad debt
- **Supply Health Validation**: Ensures sufficient collateral for active loans

### Upgradeability
- **Transparent Proxy Pattern**: Allows future upgrades while preserving state
- **Initialization Pattern**: Proper initialization of upgradeable contracts

## 📊 Key Metrics

### Per-Currency Configuration
- **Exchange Rates**: Dynamic rates relative to USD
- **Interest Rates**: Annual rates per currency (e.g., 5% for USD, 8% for BOB)
- **Collateralization Ratios**: Minimum collateral required (e.g., 150% for USD)
- **Liquidation Thresholds**: Trigger points for liquidation (e.g., 130% for USD)

### Supply Management
- **One Record Per (User, Token)**: Efficient storage and management
- **Yield Generation**: Integration with Aave for passive income
- **Health Checks**: Real-time validation of withdrawal eligibility

### Borrow Management
- **One Record Per (User, Currency)**: Simplified loan tracking
- **Partial Repayments**: Flexible repayment options
- **Interest Accrual**: Real-time interest calculation

## 🚨 Emergency Procedures

### Pause Protocol
```solidity
// Pause all operations
torito.pause();

// Resume operations
torito.unpause();
```

### Liquidation
```solidity
// Liquidate undercollateralized position
torito.liquidate(userAddress, currency);
```

## 📝 License

This project is licensed under the MIT License.

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

For detailed development setup and commands, see [DEVELOPMENT.md](./DEVELOPMENT.md).
