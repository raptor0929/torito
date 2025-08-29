# Quick Start Guide

This guide will help you set up and run the Torito Oracle Script in 5 minutes.

## Prerequisites

- Node.js 18+ installed
- An Ethereum wallet with some ETH for gas fees
- Access to an Ethereum RPC endpoint (Alchemy, Infura, etc.)

## Step 1: Install Dependencies

```bash
cd oracle-script
npm install
```

## Step 2: Configure Environment

```bash
cp env.example .env
```

Edit `.env` with your settings:

```env
# Required - Replace with your values
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
PRIVATE_KEY=your_private_key_without_0x_prefix
ORACLE_CONTRACT_ADDRESS=0x0000000000000000000000000000000000000000

# Optional - Set token addresses if you want to map currencies
USD_TOKEN_ADDRESS=0x0000000000000000000000000000000000000000
BOB_TOKEN_ADDRESS=0x0000000000000000000000000000000000000000
```

## Step 3: Deploy Oracle Contract

```bash
# From the root directory
forge script script/DeployOracle.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Update your `.env` with the deployed contract address.

## Step 4: Test Setup

```bash
npm run test
```

This will test:
- ✅ API connectivity
- ✅ Blockchain connectivity  
- ✅ Environment configuration

## Step 5: Run Single Update (Test)

```bash
npm run dev -- --once
```

This will:
- 📡 Fetch current P2P price data
- 🔄 Update the oracle contract
- 📝 Log the transaction details

## Step 6: Start Scheduled Updates

```bash
npm run dev -- schedule
```

The script will now run every 15 minutes automatically.

## Troubleshooting

### "Missing required environment variable"
- Check that all required variables are set in `.env`

### "Transaction failed"
- Verify you have enough ETH for gas fees
- Check your private key is correct

### "API request failed"
- Verify the API endpoint is accessible
- Check your internet connection

## Next Steps

- Set up monitoring and alerting
- Configure token addresses for currency mapping
- Deploy to production with PM2
- Set up log rotation

## Support

If you encounter issues:
1. Run `npm run test` to diagnose problems
2. Check the logs for detailed error messages
3. Verify your environment configuration
