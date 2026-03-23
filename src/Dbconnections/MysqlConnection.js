import mysql from "mysql2/promise";
import { configDotenv } from "dotenv";
configDotenv();

const mysqlConfig = {
  host: process.env.MYSQL_HOST,
  port: parseInt(process.env.MYSQL_PORT) || 3306,
  user: process.env.MYSQL_USER,
  password: process.env.MYSQL_PASSWORD,
  database: process.env.MYSQL_DATABASE || undefined,
  waitForConnections: true,
  connectionLimit: 20,
  queueLimit: 0,
  connectTimeout: 30000,
};

let mysqlPool;

async function initializeMysqlDatabase() {
  try {
    mysqlPool = mysql.createPool(mysqlConfig);
    // Verify connection
    const conn = await mysqlPool.getConnection();
    conn.release();
    console.log("MySQL connected successfully");
    return mysqlPool;
  } catch (err) {
    console.error("MySQL connection failed:", err);
    throw err;
  }
}

function getMysqlPool() {
  if (!mysqlPool) throw new Error("MySQL pool not initialized");
  return mysqlPool;
}

export { initializeMysqlDatabase, getMysqlPool };

process.on("SIGINT", async () => {
  if (mysqlPool) {
    await mysqlPool.end();
  }
});
