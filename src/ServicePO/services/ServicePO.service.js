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
  const { vendors_json, agreement_vendors_json, history_json, ...rest } = row;
  return {
    ...rest,
    ...(history_json !== undefined ? { history: parseJson(history_json) } : {}),
    vendors: parseJson(vendors_json),
    ...(agreement_vendors_json !== undefined ? { agreement_vendors: parseJson(agreement_vendors_json) } : {}),
  };
}

// Supplier invoices, merged in rather than added to the list procs. Each cycle gets
// invoices[] (all POs of the cycle) and each supplier split row its own invoices[].
async function attachInvoices(repo, cycles) {
  if (!cycles.length) return cycles;
  const invoices = await repo.getInvoices({});
  const byPo = new Map();
  for (const inv of invoices) {
    if (!byPo.has(inv.po_basic_sno)) byPo.set(inv.po_basic_sno, []);
    byPo.get(inv.po_basic_sno).push(inv);
  }
  return cycles.map((c) => {
    const vendors = (c.vendors ?? []).map((v) => ({ ...v, invoices: v.po_basic_sno ? byPo.get(v.po_basic_sno) ?? [] : [] }));
    const poSnos = new Set([...(c.po_basic_sno ? [c.po_basic_sno] : []), ...vendors.map((v) => v.po_basic_sno).filter(Boolean)]);
    // everything uploaded for this cycle: against its PO(s), or at rate-entry time before the PO existed
    const all = invoices.filter((i) => i.cycle_sno === c.cycle_sno || poSnos.has(i.po_basic_sno));
    return { ...c, vendors, invoices: all };
  });
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
    return attachInvoices(this.repo, rows.map(withParsedSupplierColumns));
  }

  static async attachEntryInvoice(payload) {
    return this.repo.attachEntryInvoice(payload);
  }

  static async uploadInvoice(payload) {
    return this.repo.uploadInvoice(payload);
  }

  static async getServicePoCyclesForApproval(ecno) {
    const rows = await this.repo.getServicePoCyclesForApproval(ecno);
    // invoices[] = what was uploaded with the rate entry (and any later invoice) — the approver reviews it
    return attachInvoices(this.repo, rows.map(withParsedSupplierColumns));
  }
}

export default ServicePoService;
