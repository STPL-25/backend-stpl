import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class KYCRepo {
  constructor() {
    this.storedProcedures = {
      getAllKYC: 'sp_get_kyc_info',
      getPendingApprovals: 'sp_get_kyc_approval',
      approveKyc: 'sp_approve_kyc_datas',
      fetchVendorDatas: 'sp_fetch_vendor_datas',
      createSupplierLogin: 'sp_nt_CreateSupplierLogin',
      // getKYCById: 'sp_nt_GetKYCRecordById',
      // createKYC: 'sp_nt_CreateKYCRecord',
      createKYC: 'sp_InsertKYCData',
      // updateKYC: 'sp_nt_UpdateKYCRecord',
      // updateKYCStatus: 'sp_nt_UpdateKYCStatus',
      // uploadDocuments: 'sp_nt_UploadKYCDocuments',
      // getDocuments: 'sp_nt_GetKYCDocuments',
      // getExpiryAlerts: 'sp_nt_GetKYCExpiryAlerts',
      // bulkVerify: 'sp_nt_BulkVerifyKYC',
      // deleteKYC: 'sp_nt_DeleteKYCRecord',
      // getStatistics: 'sp_nt_GetKYCStatistics'
    };
  }

  async getAllKYCRecords() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute(this.storedProcedures.getAllKYC);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getPendingApprovals(ecno) {
    try {
      const request = mssqlPool.request();
      request.input('Ecno', mssql.VarChar(50), ecno);

      const result = await request.execute(this.storedProcedures.getPendingApprovals);
      return result.recordset;
    } catch (error) {
      console.log(error)
      throw new Error(`Database error: ${error.message}`);
    }
  }
  // async getKycApproval(ecno) {
  //   try {
  //     const request = mssqlPool.request();
  //     request.input('Ecno', mssql.VarChar(50), ecno);
  //     const result = await request.execute(this.storedProcedures.getKycApproval);
  //     return result.recordset;
  //   }
  //     catch (error) {
  //     throw new Error(`Database error: ${error.message}`);
  //   }
  // }

  async getKYCRecordById(id) {
    try {
      const request = mssqlPool.request();
      request.input('kycId', mssql.Int, id);
      
      const result = await request.execute(this.storedProcedures.getKYCById);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async createKYCRecord(data) {
    try {
      const request = mssqlPool.request();
      console.log(data)
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(data));
      
      const result = await request.execute(this.storedProcedures.createKYC);
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async updateKYCRecord(id, data) {
    try {
      const request = mssqlPool.request();
      request.input('kycId', mssql.Int, id);
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(data));
      
      const result = await request.execute(this.storedProcedures.updateKYC);
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async updateKYCStatus(id, statusData) {
    try {
      const request = mssqlPool.request();
      request.input('kycId', mssql.Int, id);
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(statusData));
      
      const result = await request.execute(this.storedProcedures.updateKYCStatus);
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async uploadDocuments(documentData) {
    try {
      const request = mssqlPool.request();
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(documentData));
      
      const result = await request.execute(this.storedProcedures.uploadDocuments);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getKYCDocuments(kycId) {
    try {
      const request = mssqlPool.request();
      request.input('kycId', mssql.Int, kycId);
      
      const result = await request.execute(this.storedProcedures.getDocuments);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getExpiryAlerts(daysBeforeExpiry) {
    try {
      const request = mssqlPool.request();
      request.input('daysBeforeExpiry', mssql.Int, daysBeforeExpiry);
      
      const result = await request.execute(this.storedProcedures.getExpiryAlerts);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async bulkVerifyKYC(data) {
    try {
      const request = mssqlPool.request();
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(data));
      
      const result = await request.execute(this.storedProcedures.bulkVerify);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async deleteKYCRecord(id, hardDelete) {
    try {
      const request = mssqlPool.request();
      request.input('kycId', mssql.Int, id);
      request.input('hardDelete', mssql.Bit, hardDelete);
      
      const result = await request.execute(this.storedProcedures.deleteKYC);
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getKYCStatistics(filters) {
    try {
      const request = mssqlPool.request();
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(filters));

      const result = await request.execute(this.storedProcedures.getStatistics);
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async approveKyc(approvalData) {
    try {
      const request = mssqlPool.request();
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(approvalData));
      const result = await request.execute(this.storedProcedures.approveKyc);
      // The SP emits debug SELECTs before its outcome row, so the meaningful
      // recordset is the last one — return them all and let the service pick.
      return result.recordsets;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getSupplierContact(kyc_basic_info_sno) {
    try {
      const request = mssqlPool.request();
      request.input('kyc_basic_info_sno', mssql.Int, kyc_basic_info_sno);
      const result = await request.query(
        `SELECT company_name, email, supp_code
         FROM kyc_basic_info
         WHERE kyc_basic_info_sno = @kyc_basic_info_sno`
      );
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async createSupplierLogin({ kyc_basic_info_sno, login_email, password_hash, created_by }) {
    try {
      const request = mssqlPool.request();
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify({
        kyc_basic_info_sno,
        login_email,
        password_hash,
        created_by,
      }));
      const result = await request.execute(this.storedProcedures.createSupplierLogin);
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async fetchVendorDatas(filters = {}) {
    try {
      const request = mssqlPool.request();
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(filters));
      const result = await request.execute(this.storedProcedures.fetchVendorDatas);
      // SP returns a single row with the FOR JSON result
      const raw = result.recordset?.[0];
      const jsonStr = raw ? Object.values(raw)[0] : null;
      return jsonStr ? JSON.parse(jsonStr) : { vendors: [] };
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Returns the subset of `mappings` whose {com_sno, div_sno, brn_sno, dept_sno} does NOT
  // form a real chain in the masters (i.e. the department doesn't actually belong to that
  // branch/division/company). An empty array means every mapping is valid. This is what
  // stops a client from saving a nonsensical combination — e.g. a branch from one company
  // paired with a department from another.
  async validateOrgMappings(mappings) {
    if (!Array.isArray(mappings) || mappings.length === 0) return [];
    const invalid = [];
    for (const m of mappings) {
      try {
        const request = mssqlPool.request();
        request.input('com_sno', mssql.Int, m.com_sno);
        request.input('div_sno', mssql.Int, m.div_sno);
        request.input('brn_sno', mssql.Int, m.brn_sno);
        request.input('dept_sno', mssql.Int, m.dept_sno);
        const result = await request.query(`
          SELECT d.dept_sno
          FROM dept_master d
          JOIN branch_master b   ON b.brn_sno = d.brn_sno
          JOIN division_master v ON v.div_sno = b.div_sno
          WHERE d.dept_sno = @dept_sno
            AND d.brn_sno  = @brn_sno
            AND b.div_sno  = @div_sno
            AND v.com_sno  = @com_sno
            AND d.is_active = 'Y' AND b.is_active = 'Y' AND v.is_active = 'Y'
        `);
        if (result.recordset.length === 0) invalid.push(m);
      } catch (error) {
        invalid.push(m);
      }
    }
    return invalid;
  }

  // One row per {com_sno, div_sno, brn_sno, dept_sno} mapping — never a cross-join of
  // independently selected companies/divisions/branches/departments.
  async createKYCOrgMappings(kycBasicInfoSno, mappings, createdBy) {
    if (!Array.isArray(mappings) || mappings.length === 0) return [];
    const inserted = [];
    for (const m of mappings) {
      const request = mssqlPool.request();
      request.input('kyc_basic_info_sno', mssql.Int, kycBasicInfoSno);
      request.input('com_sno', mssql.Int, m.com_sno);
      request.input('div_sno', mssql.Int, m.div_sno);
      request.input('brn_sno', mssql.Int, m.brn_sno);
      request.input('dept_sno', mssql.Int, m.dept_sno);
      request.input('is_primary', mssql.Char(1), m.is_primary ? 'Y' : 'N');
      request.input('created_by', mssql.NVarChar(50), createdBy || '');
      const result = await request.query(`
        INSERT INTO kyc_cmp_info
          (kyc_basic_info_sno, com_sno, div_sno, brn_sno, dept_sno, is_primary, created_by, created_date, is_active)
        OUTPUT INSERTED.kyc_cmp_sno
        VALUES
          (@kyc_basic_info_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @is_primary, @created_by, GETDATE(), 'Y')
      `);
      inserted.push(result.recordset[0]);
    }
    return inserted;
  }

  async getKYCOrgMappings(kycBasicInfoSno) {
    const request = mssqlPool.request();
    request.input('kyc_basic_info_sno', mssql.Int, kycBasicInfoSno);
    const result = await request.query(`
      SELECT
        k.kyc_cmp_sno, k.com_sno, k.div_sno, k.brn_sno, k.dept_sno, k.is_primary,
        c.com_name, v.div_name, b.brn_name, d.dept_name
      FROM kyc_cmp_info k
      JOIN company_master  c ON c.com_sno = k.com_sno
      JOIN division_master v ON v.div_sno = k.div_sno
      JOIN branch_master   b ON b.brn_sno = k.brn_sno
      JOIN dept_master     d ON d.dept_sno = k.dept_sno
      WHERE k.kyc_basic_info_sno = @kyc_basic_info_sno AND k.is_active = 'Y'
      ORDER BY k.is_primary DESC, k.kyc_cmp_sno
    `);
    return result.recordset;
  }
}

export default KYCRepo;
