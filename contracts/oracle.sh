#! /bin/bash
source .env

forge script script/DeployPriceOracle.s.sol:DeployPriceOracle \
 --etherscan-api-key $ETHERSCAN_API_KEY \
 --rpc-url https://lisk.drpc.org \
 --broadcast \
 --verifier blockscout \
 --verifier-url 'https://blockscout.lisk.com/api/' \
 --verify \
 -vvvv

