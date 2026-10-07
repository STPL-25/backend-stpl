import ServiceAgreementRepository from "../repository/ServiceAgreement.repository.js";

// The list/approval/history SPs return nested data (supplier split, previous
// version's terms, versions, cycles) as JSON text columns built with FOR JSON.
// Parse them here once so the frontend receives real arrays/objects.
function parseJson(value, fallback = null) {
  if (value === null || value === undefined || value === "") return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function withParsedAgreementColumns(row) {
  const { vendors_json, prev_terms_json, history_json, ...rest } = row;
  return {
    ...rest,
    vendors: parseJson(vendors_json, []),
    ...(history_json !== undefined ? { history: parseJson(history_json, []) } : {}),
    ...(prev_terms_json !== undefined ? { prev_terms: parseJson(prev_terms_json) } : {}),
  };
}

// Signed copies uploaded after approval (newest first). Merged in here rather than
// inside the big list procs so those stay untouched: each agreement row gets
// signed_docs[] and signed_doc_url (the current/newest one).
async function attachSignedDocs(repo, rows) {
  if (!rows.length) return rows;
  const docs = await repo.getSignedDocs({});
  const byAgreement = new Map();
  for (const d of docs) {
    if (!byAgreement.has(d.agreement_sno)) byAgreement.set(d.agreement_sno, []);
    byAgreement.get(d.agreement_sno).push(d);
  }
  return rows.map((r) => {
    const signed_docs = byAgreement.get(r.agreement_sno) ?? [];
    return { ...r, signed_docs, signed_doc_url: signed_docs[0]?.doc_url ?? null };
  });
}

class ServiceAgreementService {
  static repo = new ServiceAgreementRepository();

  static async createServiceAgreement(payload) {
    return this.repo.createServiceAgreement(payload);
  }

  static async updateServiceAgreement(payload) {
    return this.repo.updateServiceAgreement(payload);
  }

  static async approveServiceAgreement(approvalData) {
    return this.repo.approveServiceAgreement(approvalData);
  }

  static async getServiceAgreements(filters) {
    const rows = await this.repo.getServiceAgreements(filters);
    return attachSignedDocs(this.repo, rows.map(withParsedAgreementColumns));
  }

  static async getServiceAgreementsForApproval(ecno) {
    const rows = await this.repo.getServiceAgreementsForApproval(ecno);
    return attachSignedDocs(this.repo, rows.map(withParsedAgreementColumns));
  }

  static async uploadSignedDoc(payload) {
    return this.repo.uploadSignedDoc(payload);
  }

  // Returns null when the agreement doesn't exist.
  static async getServiceAgreementHistory(agreement_sno) {
    const rows = await this.repo.getServiceAgreementHistory(agreement_sno);
    const row = rows?.[0];
    if (!row) return null;
    const { versions_json, cycles_json, ...header } = row;
    return {
      ...header,
      versions: parseJson(versions_json, []),
      cycles: parseJson(cycles_json, []),
    };
  }

  static async getServiceTypeCode(service_sno) {
    return this.repo.getServiceTypeCode(service_sno);
  }

  static async getMonthlyCadenceSno() {
    return this.repo.getMonthlyCadenceSno();
  }

  static async getAgreementsDueForNotification() {
    return this.repo.getAgreementsDueForNotification();
  }

  static async markAgreementNotificationSent(payload) {
    return this.repo.markAgreementNotificationSent(payload);
  }
}

export default ServiceAgreementService;
