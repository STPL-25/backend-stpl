import sql from "mssql"; import {configDotenv} from "dotenv"; configDotenv();
const p=await new sql.ConnectionPool({server:process.env.SERVER,database:process.env.DATABASE,user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,port:parseInt(process.env.DB_PORT)||1433,options:{encrypt:false,trustServerCertificate:true}}).connect();
const r=await p.request().query("select name from sys.columns where object_id=object_id('dbo.supplier_quotation_info') and name like '%gst_pct%' or name in('freight_charges','is_intrastate') and object_id=object_id('dbo.supplier_quotation_info')");
console.log(r.recordset, process.env.DATABASE); process.exit(0)
