import mssql from "mssql";
import { initializeDatabase } from "../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

/**
 * Errors 58701-58740 (sql/155) are written for the person who sees them: they come back as `userFacing` errors with a status.
 * Anything else is a real failure and stays an ordinary Error (the controller hides its details from the public).
 */
function translate(error) {
  const n = error?.number;
  if (n >= 58701 && n <= 58740) {
    const err = new Error(error.message);
    err.userFacing = true;
    err.dbNumber = n;
    // 58710-58714: the link itself cannot be used (unknown / spent / replaced / expired / KYC no longer rejected)
    if (n >= 58710 && n <= 58714) err.status = 410;
    else if (n === 58732 || n === 58733) err.status = 409;
    else if (n === 58706) err.status = 429;
    else err.status = 422;
    return err;
  }
  return error;
}

async function run(proc, inputs) {
  try {
    const request = mssqlPool.request();
    for (const [name, [type, value]] of Object.entries(inputs)) request.input(name, type, value);
    return (await request.execute(proc)).recordsets;
  } catch (error) {
    throw translate(error);
  }
}

class KycResubmitRepo {
  async issue({ kycId, tokenHash, reason, createdBy, validDays }) {
    const sets = await run("sp_nt_KycResubmitIssue", {
      kyc_basic_info_sno: [mssql.Int, kycId],
      token_hash: [mssql.Char(64), tokenHash],
      reason: [mssql.NVarChar(1000), reason ?? null],
      created_by: [mssql.VarChar(30), String(createdBy ?? "").slice(0, 30)],
      valid_days: [mssql.Int, validDays ?? 7],
    });
    return sets[0][0];
  }

  markEmail(linkSno, sent, note) {
    return run("sp_nt_KycResubmitMarkEmail", {
      link_sno: [mssql.Int, linkSno],
      sent: [mssql.Bit, sent ? 1 : 0],
      note: [mssql.NVarChar(300), note ?? null],
    });
  }

  async linkStatus(kycId) {
    const sets = await run("sp_nt_KycResubmitLinkStatus", { kyc_basic_info_sno: [mssql.Int, kycId] });
    return sets[0][0] ?? null;
  }

  /** Throws the link error (unknown / spent / replaced / expired) - reads only. */
  async check(tokenHash) {
    const sets = await run("sp_nt_KycResubmitCheck", { token_hash: [mssql.Char(64), tokenHash] });
    return sets[0][0];
  }

  /** The 8 result sets of sp_nt_KycResubmitOpen. */
  open(tokenHash) {
    return run("sp_nt_KycResubmitOpen", { token_hash: [mssql.Char(64), tokenHash] });
  }

  async save({ tokenHash, payload, documents, filesJson, clientIp }) {
    const sets = await run("sp_nt_KycResubmitSave", {
      token_hash: [mssql.Char(64), tokenHash],
      payload: [mssql.NVarChar(mssql.MAX), JSON.stringify(payload)],
      documents: [mssql.NVarChar(mssql.MAX), JSON.stringify(documents)],
      files_json: [mssql.NVarChar(mssql.MAX), JSON.stringify(filesJson)],
      client_ip: [mssql.VarChar(45), clientIp ? String(clientIp).slice(0, 45) : null],
    });
    return sets[0][0];
  }
}

export default KycResubmitRepo;
