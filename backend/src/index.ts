import { ethers } from 'ethers';
import axios from 'axios';
import * as dotenv from 'dotenv';

// Load environment variables
dotenv.config();

// API Response Interface
interface P2PPriceResponse {
    moneda: string;
    nombre: string;
    tipoDeCambio: number;
    fiat: string;
    fechaActualizacion: string;
}

// Oracle Contract ABI (only the functions we need)
const ORACLE_ABI = [
    'function updateCurrencyPrice(bytes32 currency, uint256 price) external',
    'function getPrice(bytes32 currency) external view returns (uint256)',
    'function priceData(bytes32 currency) external view returns (uint256 price, uint256 timestamp)',
    'event PriceUpdated(bytes32 indexed currency, uint256 price, uint256 timestamp)'
];

class ToritoOracleUpdater {
    private provider: ethers.JsonRpcProvider;
    private wallet: ethers.Wallet;
    private oracleContract: ethers.Contract;

    constructor() {
        // Validate environment variables
        this.validateEnvironment();

        // Initialize provider and wallet
        this.provider = new ethers.JsonRpcProvider(process.env.RPC_URL!);
        this.wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, this.provider);
        
        // Initialize oracle contract
        this.oracleContract = new ethers.Contract(
            process.env.ORACLE_CONTRACT_ADDRESS!,
            ORACLE_ABI,
            this.wallet
        );

        this.initialize();
    }

    private async initialize(): Promise<void> {
        try {
            const network = await this.provider.getNetwork();
            console.log('🔗 Connected to network:', network);
            console.log('👤 Wallet address:', this.wallet.address);
            console.log('📊 Oracle contract:', this.oracleContract.target);
        } catch (error) {
            console.error('❌ Failed to initialize:', error);
            throw error;
        }
    }

    private validateEnvironment(): void {
        const requiredEnvVars = [
            'RPC_URL',
            'PRIVATE_KEY',
            'ORACLE_CONTRACT_ADDRESS',
            'P2P_API_URL'
        ];

        for (const envVar of requiredEnvVars) {
            if (!process.env[envVar]) {
                throw new Error(`Missing required environment variable: ${envVar}`);
            }
        }
    }

    /**
     * Fetch P2P price data from the API
     */
    async fetchP2PPriceData(): Promise<P2PPriceResponse> {
        try {
            console.log('📡 Fetching P2P price data...');
            const response = await axios.get<P2PPriceResponse>(process.env.P2P_API_URL!);
            
            console.log('✅ P2P Price Data:', {
                currency: response.data.moneda,
                name: response.data.nombre,
                exchangeRate: response.data.tipoDeCambio,
                fiat: response.data.fiat,
                lastUpdate: response.data.fechaActualizacion
            });

            return response.data;
        } catch (error) {
            console.error('❌ Error fetching P2P price data:', error);
            throw error;
        }
    }

    /**
     * Convert exchange rate to wei (18 decimals)
     * The API returns exchange rate as a decimal (e.g., 12.57)
     * We need to convert it to wei format for the smart contract
     */
    private convertToWei(exchangeRate: number): bigint {
        // Convert to wei (18 decimals)
        // For example: 12.57 -> 12570000000000000000 (12.57 * 10^18)
        return ethers.parseUnits(exchangeRate.toString(), 18);
    }

    /**
     * Update the oracle with new price data
     * Uses updateCurrencyPrice function for USD currency (since API returns USD/BOB rate)
     */
    async updateOracle(priceData: P2PPriceResponse): Promise<void> {
        try {
            // Convert currency symbol to bytes32
            const currencySymbol = ethers.encodeBytes32String(priceData.moneda);
            
            // Convert exchange rate to wei
            const priceInWei = this.convertToWei(priceData.tipoDeCambio);

            console.log(`🔄 Updating oracle for ${priceData.moneda}...`);
            console.log(`   Exchange Rate: ${priceData.tipoDeCambio} ${priceData.fiat}`);
            console.log(`   Price in Wei: ${priceInWei.toString()}`);
            console.log(`   Currency Symbol: ${currencySymbol}`);

            // Prepare transaction
            const tx = await this.oracleContract.updateCurrencyPrice.populateTransaction(
                currencySymbol,
                priceInWei
            );

            // Add gas configuration
            const gasLimit = process.env.GAS_LIMIT ? parseInt(process.env.GAS_LIMIT) : 300000;
            const maxFeePerGas = process.env.MAX_FEE_PER_GAS ? 
                ethers.parseUnits(process.env.MAX_FEE_PER_GAS, 'wei') : 
                ethers.parseUnits('20', 'gwei');
            const maxPriorityFeePerGas = process.env.MAX_PRIORITY_FEE_PER_GAS ? 
                ethers.parseUnits(process.env.MAX_PRIORITY_FEE_PER_GAS, 'wei') : 
                ethers.parseUnits('2', 'gwei');

            tx.gasLimit = BigInt(gasLimit);
            tx.maxFeePerGas = maxFeePerGas;
            tx.maxPriorityFeePerGas = maxPriorityFeePerGas;

            // Send transaction
            const transaction = await this.wallet.sendTransaction(tx);
            console.log(`📝 Transaction sent: ${transaction.hash}`);

            // Wait for confirmation
            const receipt = await transaction.wait();
            console.log(`✅ Transaction confirmed in block ${receipt?.blockNumber}`);

            // Log the event
            if (receipt?.logs) {
                for (const log of receipt.logs) {
                    try {
                        const parsedLog = this.oracleContract.interface.parseLog(log);
                        if (parsedLog?.name === 'PriceUpdated') {
                            console.log('📊 Price Updated Event:', {
                                currency: parsedLog.args[0],
                                price: ethers.formatUnits(parsedLog.args[1], 18),
                                timestamp: new Date(Number(parsedLog.args[2]) * 1000).toISOString()
                            });
                        }
                    } catch (e) {
                        // Ignore logs that can't be parsed
                    }
                }
            }

        } catch (error) {
            console.error('❌ Error updating oracle:', error);
            throw error;
        }
    }

    /**
     * Get current price data from oracle
     */
    async getCurrentPriceData(): Promise<void> {
        try {
            // Get USD price using currency symbol
            const usdCurrency = ethers.encodeBytes32String('USD');
            const price = await this.oracleContract.getPrice(usdCurrency);
            const priceData = await this.oracleContract.priceData(usdCurrency);
            
            console.log('📊 Current Oracle Data:', {
                currency: 'USD',
                price: ethers.formatUnits(price, 18),
                priceInBOB: ethers.formatUnits(price, 18) + ' BOB per USD',
                lastUpdate: new Date(Number(priceData[1]) * 1000).toISOString()
            });
        } catch (error) {
            console.error('❌ Error getting price data:', error);
        }
    }

    /**
     * Main function to fetch and update oracle
     */
    async updateOracleWithP2PData(): Promise<void> {
        try {
            console.log('\n🚀 Starting oracle update process...');
            console.log('⏰ Timestamp:', new Date().toISOString());

            // Fetch P2P price data
            const priceData = await this.fetchP2PPriceData();

            // Update oracle
            await this.updateOracle(priceData);

            console.log('✅ Oracle update completed successfully!');
            
        } catch (error) {
            console.error('❌ Oracle update failed:', error);
            throw error;
        }
    }
}

// Export for use in scheduler
export { ToritoOracleUpdater };

// Main execution (if run directly)
if (require.main === module) {
    const updater = new ToritoOracleUpdater();
    
    updater.updateOracleWithP2PData()
        .then(() => {
            console.log('🎉 Script completed successfully!');
            process.exit(0);
        })
        .catch((error) => {
            console.error('💥 Script failed:', error);
            process.exit(1);
        });
}
