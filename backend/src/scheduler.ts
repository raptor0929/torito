import * as cron from 'node-cron';
import { ToritoOracleUpdater } from './index';
import * as dotenv from 'dotenv';

// Load environment variables
dotenv.config();

class OracleScheduler {
    private updater: ToritoOracleUpdater;
    private cronJob: cron.ScheduledTask | null = null;

    constructor() {
        this.updater = new ToritoOracleUpdater();
    }

    /**
     * Start the scheduler to run every 15 minutes
     */
    start(): void {
        console.log('⏰ Starting Oracle Scheduler...');
        console.log('📅 Schedule: Every 15 minutes');
        console.log('🔄 Next run will be at:', this.getNextRunTime());

        // Schedule job to run every 15 minutes
        this.cronJob = cron.schedule('*/15 * * * *', async () => {
            await this.runUpdate();
        }, {
            scheduled: true,
            timezone: 'UTC'
        });

        console.log('✅ Scheduler started successfully!');
        console.log('🛑 Press Ctrl+C to stop the scheduler');

        // Handle graceful shutdown
        process.on('SIGINT', () => {
            this.stop();
            process.exit(0);
        });

        process.on('SIGTERM', () => {
            this.stop();
            process.exit(0);
        });
    }

    /**
     * Stop the scheduler
     */
    stop(): void {
        if (this.cronJob) {
            this.cronJob.stop();
            console.log('⏹️ Scheduler stopped');
        }
    }

    /**
     * Run a single update
     */
    async runUpdate(): Promise<void> {
        try {
            console.log('\n' + '='.repeat(60));
            console.log('🔄 Running scheduled oracle update...');
            console.log('⏰ Timestamp:', new Date().toISOString());
            console.log('='.repeat(60));

            await this.updater.updateOracleWithP2PData();

            console.log('✅ Scheduled update completed successfully!');
            console.log('⏰ Next scheduled run:', this.getNextRunTime());
            console.log('='.repeat(60) + '\n');

        } catch (error) {
            console.error('❌ Scheduled update failed:', error);
            console.error('⏰ Will retry at next scheduled time:', this.getNextRunTime());
            console.log('='.repeat(60) + '\n');
        }
    }

    /**
     * Get the next scheduled run time
     */
    private getNextRunTime(): string {
        const now = new Date();
        const nextRun = new Date(now.getTime() + (15 * 60 * 1000)); // 15 minutes from now
        return nextRun.toISOString();
    }

    /**
     * Run a single update immediately (for testing)
     */
    async runOnce(): Promise<void> {
        console.log('🚀 Running single oracle update...');
        await this.runUpdate();
        this.stop();
    }
}

// Main execution
if (require.main === module) {
    const scheduler = new OracleScheduler();

    // Check if we want to run once or start the scheduler
    const args = process.argv.slice(2);
    
    if (args.includes('--once') || args.includes('-o')) {
        // Run once and exit
        scheduler.runOnce()
            .then(() => {
                console.log('🎉 Single run completed!');
                process.exit(0);
            })
            .catch((error) => {
                console.error('💥 Single run failed:', error);
                process.exit(1);
            });
    } else {
        // Start the scheduler
        scheduler.start();
    }
}

export { OracleScheduler };
