#! /bin/bash
source .env

forge script script/Torito.s.sol:ToritoScript \
--rpc-url https://lisk.drpc.org \
--broadcast \
--verify \
-vvvv \
--sig "run(address)" $ORACLE_CONTRACT_ADDRESS