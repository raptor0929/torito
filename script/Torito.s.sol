// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Torito} from "../src/Torito.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract ToritoScript is Script {
    Torito public toritoImplementation;
    TransparentUpgradeableProxy public toritoProxy;

    // Deployment parameters - update these for your deployment
    address public aavePool = address(0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff); // Aave Pool for Arbitrum Sepolia

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);
        vm.startBroadcast();

        // Deploy the implementation contract
        toritoImplementation = new Torito();

        // Encode the initialization data
        bytes memory initData = abi.encodeWithSelector(Torito.initialize.selector, aavePool, owner);

        // Deploy the transparent proxy
        toritoProxy = new TransparentUpgradeableProxy(address(toritoImplementation), owner, initData);

        Torito torito = Torito(address(toritoProxy));

        // Set up USD currency with its own oracle and risk parameters
        torito.setSupportedCurrency(
            bytes32("USD"),
            1e18, // Exchange rate (1:1)
            5e16, // 5% interest rate
            address(0x123), // USD oracle address (replace with actual)
            150e16, // 150% collateralization ratio
            120e16 // 120% liquidation threshold
        );

        // Set up BOB currency with different parameters
        torito.setSupportedCurrency(
            bytes32("BOB"),
            76923076923076923, // Exchange rate (1:13)
            10e16, // 10% interest rate
            address(0x456), // BOB oracle address (replace with actual)
            200e16, // 200% collateralization ratio (higher risk)
            150e16 // 150% liquidation threshold
        );

        vm.stopBroadcast();

        // Log deployment addresses
        console2.log("=== Torito Deployment ===");
        console2.log("Torito Implementation deployed at:", address(toritoImplementation));
        console2.log("Proxy Admin deployed at:", owner);
        console2.log("Torito Proxy deployed at:", address(toritoProxy));
        console2.log("Owner set to:", owner);
        console2.log("Aave Pool:", aavePool);
        console2.log("USD Exchange Rate:", torito.getCurrencyExchangeRate(bytes32("USD")));
        console2.log("USD Interest Rate:", torito.getCurrencyInterestRate(bytes32("USD")));
        console2.log("USD Collateralization Ratio:", torito.getCurrencyCollateralizationRatio(bytes32("USD")));
        console2.log("USD Liquidation Threshold:", torito.getCurrencyLiquidationThreshold(bytes32("USD")));
        console2.log("USD Oracle:", torito.getCurrencyOracle(bytes32("USD")));
        console2.log("BOB Exchange Rate:", torito.getCurrencyExchangeRate(bytes32("BOB")));
        console2.log("BOB Interest Rate:", torito.getCurrencyInterestRate(bytes32("BOB")));
        console2.log("BOB Collateralization Ratio:", torito.getCurrencyCollateralizationRatio(bytes32("BOB")));
        console2.log("BOB Liquidation Threshold:", torito.getCurrencyLiquidationThreshold(bytes32("BOB")));
        console2.log("BOB Oracle:", torito.getCurrencyOracle(bytes32("BOB")));
        console2.log("Note: Exchange rates and interest rates are now set per currency");
        console2.log("==========================");
    }
}
