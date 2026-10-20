import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(s)=>console.log(JSON.stringify((await pool.request().query(s)).recordset));
await q(`select top 8 po_basic_sno,qty,agreed_unit_price,total_cost,discount_pct,tax_pct,net_cost from po_item_details where po_basic_sno in (1100,1096,1097,60,61,62,47) `);
await q(`select top 6 grn_basic_sno,po_qty,received_qty,invoice_qty,shortage_qty,excess_qty,po_unit_price,received_unit_price,total_po_cost,total_grn_cost,net_cost,tax_pct from grn_item_details where excess_qty>0 or shortage_qty>0 or total_grn_cost is not null order by 1 desc`);
process.exit(0);
