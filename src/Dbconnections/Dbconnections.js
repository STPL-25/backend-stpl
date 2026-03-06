import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();


const config = {
  user: process.env.DB_USER,
  password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER,
  database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: {
    trustServerCertificate: true,
    enableArithAbort: true,
    connectionTimeout: 30000,
    requestTimeout: 30000,
  },
  pool: {
    max: 50,
    min: 5,
    idleTimeoutMillis: 30000,
    acquireTimeoutMillis: 15000,
  },
};

let pool;

async function initializeDatabase() {
  try {
    pool = await sql.connect(config);
    return pool;
  } catch (err) {
    console.error("SQL Server connection failed:", err);
    throw err;
  }
}

export { initializeDatabase };

// Graceful shutdown
process.on('SIGINT', async () => {
  if (pool) {
    await pool.close()
  }
  process.exit(0)
})
