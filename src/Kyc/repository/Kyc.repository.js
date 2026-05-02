import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class KYCRepo {
  constructor() {
    this.storedProcedures = {
      getAllKYC: 'sp_get_kyc_info',
      getPendingApprovals: 'sp_get_kyc_approval',
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
      console.log(approvalData)
      const request = mssqlPool.request();
      request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(approvalData));
      const result = await request.execute('sp_approve_kyc_datas');
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default KYCRepo;
