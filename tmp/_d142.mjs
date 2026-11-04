import sql from "mssql"; import {configDotenv} from "dotenv"; configDotenv();
const p=await new sql.ConnectionPool({server:process.env.SERVER,database:process.env.DATABASE,user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,port:parseInt(process.env.DB_PORT)||1433,options:{encrypt:false,trustServerCertificate:true}}).connect();
const d=(await p.request().query("select object_definition(object_id('dbo.sp_nt_CreateSupplierQuotation')) d")).recordset[0].d;
console.log(d.includes('freight_gst_pct'), d.includes('fn_resolve_approval_entity'), d.includes('freight_charges'));
console.log((await p.request().query("select top 5 sq_basic_sno,freight_charges,other_charges,freight_gst_pct,other_charges_gst_pct from supplier_quotation_info order by 1 desc")).recordset);
process.exit(0)
