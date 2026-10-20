import SpecialAgreementRepository from "../repository/SpecialAgreement.repository.js";

// The list SP returns items/history as JSON text columns (FOR JSON) - parse once here.
function parseJson(value, fallback) {
  if (value === null || value === undefined || value === "") return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function parseRow(row) {
  const { items_json, history_json, ...rest } = row;
  return { ...rest, items: parseJson(items_json, []), history: parseJson(history_json, []) };
}

class SpecialAgreementService {
  static repo = new SpecialAgreementRepository();

  static create(payload) { return this.repo.create(payload); }
  static update(payload) { return this.repo.update(payload); }
  static approve(payload) { return this.repo.approve(payload); }
  static async list(filters) { return (await this.repo.list(filters)).map(parseRow); }
  static async listForApproval(ecno) { return (await this.repo.list({ approver_ecno: ecno })).map(parseRow); }
  static async getRate(prod_sno, on_date) {
    const rows = await this.repo.getRate({ prod_sno, on_date });
    return rows?.[0] ?? null;
  }
}

export default SpecialAgreementService;
