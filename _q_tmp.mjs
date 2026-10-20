import sql from "mssql"; import {configDotenv} from "dotenv"; configDotenv();
const pool=await new sql.ConnectionPool({user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,server:process.env.SERVER,database:process.env.DATABASE,port:parseInt(process.env.DB_PORT)||1433,options:{trustServerCertificate:true}}).connect();
for (const q of process.argv.slice(2)) { try{const r=await pool.request().query(q); console.log(q,"\n",JSON.stringify(r.recordset).slice(0,3000));}catch(e){console.log("ERR",q,e.message)} }
await pool.close();
