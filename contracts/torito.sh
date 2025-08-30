#! /bin/bash
source .env

forge script script/Torito.s.sol:ToritoScript \
 --etherscan-api-key $ETHERSCAN_API_KEY \
 --rpc-url https://lisk.drpc.org \
 --broadcast \
 --verifier blockscout \
 --verifier-url 'https://blockscout.lisk.com/api/' \
 --verify \
 -vvvv \
 --sig "run(address)" $ORACLE_CONTRACT_ADDRESS