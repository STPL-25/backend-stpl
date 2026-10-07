import sql from "mssql"; import fs from "node:fs"; import { configDotenv } from "dotenv"; configDotenv();
const p = await new sql.ConnectionPool({user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,server:process.env.SERVER,database:process.env.DATABASE,options:{trustServerCertificate:true}}).connect();
for (const n of ['sp_nt_DirectIssueServicePO','sp_nt_ApproveServicePoCycle','sp_Save_PO_Request']) {
 const r = await p.query(`SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.${n}')) d`);
 fs.writeFileSync(process.argv[2]+'/'+n+'.sql', r.recordset[0].d);
}
await p.close();
