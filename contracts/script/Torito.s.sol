// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Torito} from "../src/Torito.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Torito} from "../src/Torito.sol";

contract ToritoScript is Script {
    Torito public torito;

    // Deployment parameters - update these for your deployment
    address public aavePool = address(0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b); // Aave Pool for Base Sepolia

    function setUp() public {}

    function run(address oracle) public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);
        vm.startBroadcast();

        // Deploy the implementation contract
        torito = new Torito(aavePool, owner);

        // Set up BOB currency with different parameters
        torito.addSupportedCurrency(
            bytes32("BOB"),
            oracle, // BOB oracle address (replace with actual)
            200e16, // 200% collateralization ratio (higher risk)
            150e16, // 150% liquidation threshold
            10e16, // 10% base rate
            5e16, // 5% min rate
            15e16, // 15% max rate
            25e16 // 25% sensitivity
        );

        vm.stopBroadcast();

        (,uint256 collateralizationRatio, uint256 liquidationThreshold, address oracle2, uint256 baseRate, uint256 minRate, uint256 maxRate, uint256 sensitivity,,) = torito.supportedCurrencies(bytes32("BOB"));
        // Log deployment addresses
        console.log("=== Torito Deployment ===");
        console.log("Torito deployed at:", address(torito));
        console.log("Owner set to:", owner);
        console.log("Aave Pool:", aavePool);
        console.log("BOB Collateralization Ratio:", collateralizationRatio / 1e16);
        console.log("BOB Liquidation Threshold:", liquidationThreshold / 1e16);
        console.log("BOB Oracle:", address(oracle2));
        console.log("BOB Base Rate:", baseRate / 1e16);
        console.log("BOB Min Rate:", minRate / 1e16);
        console.log("BOB Max Rate:", maxRate / 1e16);
        console.log("BOB Sensitivity:", sensitivity / 1e16);
        console.log("==========================");
    }
}
