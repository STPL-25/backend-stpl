import sql from "mssql"; import {configDotenv} from "dotenv"; configDotenv();
const p=await new sql.ConnectionPool({server:process.env.SERVER,database:process.env.DATABASE,user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,port:parseInt(process.env.DB_PORT)||1433,options:{encrypt:false,trustServerCertificate:true}}).connect();
console.log((await p.request().query("select object_id('dbo.fn_resolve_approval_entity') f")).recordset);
process.exit(0)
