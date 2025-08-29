import axios from 'axios';
import { ethers } from 'ethers';
import * as dotenv from 'dotenv';

// Load environment variables
dotenv.config();

interface P2PPriceResponse {
    moneda: string;
    nombre: string;
    tipoDeCambio: number;
    fiat: string;
    fechaActualizacion: string;
}

class OracleTester {
    /**
     * Test API connectivity and response format
     */
    async testAPI(): Promise<void> {
        console.log('🧪 Testing API connectivity...');
        
        try {
            const response = await axios.get<P2PPriceResponse>(process.env.P2P_API_URL!);
            
            console.log('✅ API Response:');
            console.log('  Currency:', response.data.moneda);
            console.log('  Name:', response.data.nombre);
            console.log('  Exchange Rate:', response.data.tipoDeCambio);
            console.log('  Fiat:', response.data.fiat);
            console.log('  Last Update:', response.data.fechaActualizacion);
            
            // Test conversion to wei
            const priceInWei = ethers.parseUnits(response.data.tipoDeCambio.toString(), 18);
            console.log('  Price in Wei:', priceInWei.toString());
            
            // Test currency encoding
            const currencySymbol = ethers.encodeBytes32String(response.data.moneda);
            console.log('  Currency Symbol (bytes32):', currencySymbol);
            
        } catch (error) {
            console.error('❌ API test failed:', error);
            throw error;
        }
    }

    /**
     * Test blockchain connectivity
     */
    async testBlockchain(): Promise<void> {
        console.log('\n🧪 Testing blockchain connectivity...');
        
        try {
            const provider = new ethers.JsonRpcProvider(process.env.RPC_URL!);
            const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);
            
            console.log('✅ Blockchain Connection:');
            console.log('  Network:', await provider.getNetwork());
            console.log('  Wallet Address:', wallet.address);
            console.log('  Balance:', ethers.formatEther(await provider.getBalance(wallet.address)), 'ETH');
            
            // Test if oracle contract exists
            if (process.env.ORACLE_CONTRACT_ADDRESS) {
                const code = await provider.getCode(process.env.ORACLE_CONTRACT_ADDRESS);
                if (code !== '0x') {
                    console.log('  Oracle Contract: Exists at', process.env.ORACLE_CONTRACT_ADDRESS);
                } else {
                    console.log('  Oracle Contract: No contract found at', process.env.ORACLE_CONTRACT_ADDRESS);
                }
            }
            
        } catch (error) {
            console.error('❌ Blockchain test failed:', error);
            throw error;
        }
    }

    /**
     * Test environment configuration
     */
    testEnvironment(): void {
        console.log('\n🧪 Testing environment configuration...');
        
        const requiredVars = [
            'RPC_URL',
            'PRIVATE_KEY',
            'ORACLE_CONTRACT_ADDRESS',
            'P2P_API_URL'
        ];
        
        const optionalVars = [
            'USD_TOKEN_ADDRESS',
            'BOB_TOKEN_ADDRESS',
            'GAS_LIMIT',
            'MAX_FEE_PER_GAS',
            'MAX_PRIORITY_FEE_PER_GAS'
        ];
        
        console.log('✅ Required Environment Variables:');
        for (const envVar of requiredVars) {
            if (process.env[envVar]) {
                console.log(`  ${envVar}: Set`);
            } else {
                console.log(`  ${envVar}: ❌ Missing`);
            }
        }
        
        console.log('\n📋 Optional Environment Variables:');
        for (const envVar of optionalVars) {
            if (process.env[envVar]) {
                console.log(`  ${envVar}: ${process.env[envVar]}`);
            } else {
                console.log(`  ${envVar}: Not set (using defaults)`);
            }
        }
    }

    /**
     * Run all tests
     */
    async runAllTests(): Promise<void> {
        console.log('🚀 Running Oracle Test Suite...');
        console.log('='.repeat(50));
        
        try {
            this.testEnvironment();
            await this.testAPI();
            await this.testBlockchain();
            
            console.log('\n' + '='.repeat(50));
            console.log('🎉 All tests passed! Oracle setup is ready.');
            
        } catch (error) {
            console.error('\n' + '='.repeat(50));
            console.error('💥 Test suite failed:', error);
            throw error;
        }
    }
}

// Main execution
if (require.main === module) {
    const tester = new OracleTester();
    
    const args = process.argv.slice(2);
    const testType = args[0];

    switch (testType) {
        case 'api':
            tester.testAPI()
                .then(() => process.exit(0))
                .catch((error) => {
                    console.error('API test failed:', error);
                    process.exit(1);
                });
            break;

        case 'blockchain':
            tester.testBlockchain()
                .then(() => process.exit(0))
                .catch((error) => {
                    console.error('Blockchain test failed:', error);
                    process.exit(1);
                });
            break;

        case 'env':
            tester.testEnvironment();
            process.exit(0);
            break;

        default:
            tester.runAllTests()
                .then(() => process.exit(0))
                .catch((error) => {
                    console.error('Test suite failed:', error);
                    process.exit(1);
                });
            break;
    }
}

export { OracleTester };
