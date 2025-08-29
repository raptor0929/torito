# Torito BOB Oracle Script

A simple TypeScript script that fetches P2P price data from the Dolare API and updates the Torito oracle contract every 15 minutes for BOB currency.

## Features

- 🔄 **Automated Updates**: Fetches price data every 15 minutes
- 📊 **P2P Integration**: Connects to the Dolare P2P API
- ⛓️ **Blockchain Integration**: Updates smart contract oracles
- 🛡️ **Error Handling**: Robust error handling and retry logic
- 📝 **Logging**: Comprehensive logging with timestamps

## Prerequisites

- Node.js 18+ 
- npm or yarn
- Ethereum wallet with ETH for gas fees
- Access to an Ethereum RPC endpoint (Alchemy, Infura, etc.)

## Installation

1. **Install dependencies:**
   ```bash
   cd backend
   npm install
   ```

2. **Build the project:**
   ```bash
   npm run build
   ```

## Configuration

1. **Copy the environment template:**
   ```bash
   cp env.example .env
   ```

2. **Edit `.env` with your configuration:**
   ```env
   # Required
   RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
   PRIVATE_KEY=your_private_key_here
   ORACLE_CONTRACT_ADDRESS=0x0000000000000000000000000000000000000000
   P2P_API_URL=https://us-central1-dolare.cloudfunctions.net/p2pPrice
   
   # Optional
   GAS_LIMIT=300000
   MAX_FEE_PER_GAS=20000000000
   MAX_PRIORITY_FEE_PER_GAS=2000000000
   ```

## Smart Contract Setup

The script works with the existing `OracleCurrencyPriceBOB.sol` contract. Make sure:

1. The contract is deployed
2. Your wallet is the owner of the contract
3. The contract address is set in `.env`

## Usage

### Single Update (Test)
Run a single oracle update to test the setup:
```bash
npm run dev -- --once
```

### Scheduled Updates
Start the scheduler to run updates every 15 minutes:
```bash
npm run dev -- schedule
```

### Test Setup
Test the configuration:
```bash
npm run test
```

## How It Works

1. **Fetches P2P Data**: Calls the Dolare API to get current BOB exchange rate
2. **Converts to Wei**: Converts the exchange rate to wei format (18 decimals)
3. **Creates Fake RequestId**: Generates a unique requestId for the transaction
4. **Calls fulfillRequest**: Updates the oracle contract with new price data
5. **Logs Results**: Provides detailed logging of the process

## API Response Format

The script expects this response format:
```json
{
    "moneda": "USD",
    "nombre": "Buildathon P2P",
    "tipoDeCambio": 12.58,
    "fiat": "BOB",
    "fechaActualizacion": "2025-08-29T04:10:11.728Z"
}
```

## Troubleshooting

### Common Issues

1. **"Missing required environment variable"**
   - Check that all required variables are set in `.env`

2. **"Transaction failed"**
   - Verify sufficient ETH balance for gas fees
   - Check your private key is correct
   - Ensure contract address is correct

3. **"API request failed"**
   - Verify API endpoint is accessible
   - Check network connectivity

## Production Deployment

For production deployment:

1. **Use a production RPC endpoint**
2. **Secure your private key**
3. **Set up monitoring and alerting**
4. **Consider using a process manager (PM2)**

### PM2 Configuration

Create `ecosystem.config.js`:
```javascript
module.exports = {
  apps: [{
    name: 'torito-bob-oracle',
    script: 'dist/scheduler.js',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production'
    }
  }]
};
```

Start with PM2:
```bash
pm2 start ecosystem.config.js
pm2 save
pm2 startup
```

## License

MIT License
