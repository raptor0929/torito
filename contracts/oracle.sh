#! /bin/bash
source .env

forge script script/DeployPriceOracle.s.sol:DeployPriceOracle \
--rpc-url https://lisk.drpc.org \
--broadcast \
--verify \
-vvvv

