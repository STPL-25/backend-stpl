import ServicePoRepository from "../repository/ServicePo.repository.js";

// vendors_json / agreement_vendors_json are FOR JSON text columns (the
// cycle's per-supplier split, and the agreement's configured suppliers) —
// parsed once here so the frontend gets real arrays.
function parseJson(value, fallback = []) {
  if (value === null || value === undefined || value === "") return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function withParsedSupplierColumns(row) {
  const { vendors_json, agreement_vendors_json, ...rest } = row;
  return {
    ...rest,
    vendors: parseJson(vendors_json),
    ...(agreement_vendors_json !== undefined ? { agreement_vendors: parseJson(agreement_vendors_json) } : {}),
  };
}

class ServicePoService {
  static repo = new ServicePoRepository();

  static async submitServicePoEntry(payload) {
    return this.repo.submitServicePoEntry(payload);
  }

  static async approveServicePoCycle(approvalData) {
    return this.repo.approveServicePoCycle(approvalData);
  }

  static async getServicePoCycles(filters) {
    const rows = await this.repo.getServicePoCycles(filters);
    return rows.map(withParsedSupplierColumns);
  }

  static async getServicePoCyclesForApproval(ecno) {
    const rows = await this.repo.getServicePoCyclesForApproval(ecno);
    return rows.map(withParsedSupplierColumns);
  }
}

export default ServicePoService;
