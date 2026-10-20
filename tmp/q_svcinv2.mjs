import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async s=>console.log(JSON.stringify((await pool.request().query(s)).recordset,null,0));
await q(`select name from sys.columns where object_id=object_id('service_po_cycle_vendor')`);
await q(`select * from service_po_cycle_vendor where cycle_sno in (1017,1016,1008,1014,1018,1020,1022)`);
await q(`select po_basic_sno,count(*) n,sum(net_cost) s from po_item_details where po_basic_sno in (1092,1093,1094,1096,1097,1099,1101,1100) and is_active='1' group by po_basic_sno`);
await q(`select OBJECT_DEFINITION(OBJECT_ID('sp_nt_GetPayableBills')) d`);
process.exit(0);
