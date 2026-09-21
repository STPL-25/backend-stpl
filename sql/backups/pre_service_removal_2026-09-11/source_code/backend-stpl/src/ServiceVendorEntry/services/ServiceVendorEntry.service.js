import ServiceVendorEntryRepository from "../repository/ServiceVendorEntry.repository.js";
import ServicePOService from "../../ServicePO/services/ServicePO.service.js";

class ServiceVendorEntryService {
  static repo = new ServiceVendorEntryRepository();

  static async createEntry(payload) {
    const data = await this.repo.createEntry(payload);
    return data?.[0];
  }

  static async getEntries(filters) {
    return this.repo.getEntries(filters);
  }

  static async cancelEntry(payload) {
    const data = await this.repo.cancelEntry(payload);
    return data?.[0];
  }

  // Per-entry approval — verifies a single already-purchased entry
  // (retrospective review, not a pre-purchase gate: the goods are already
  // bought by the time an entry exists). Approve flips it back to PENDING,
  // the same status the consolidation screen has always filtered on, so
  // that screen needed no changes — it naturally only ever offers entries
  // that already cleared this step.
  static async approveEntry(payload) {
    const data = await this.repo.approveEntry(payload);
    return data?.[0];
  }

  // The "select checkboxes, raise PO" action. Locks the chosen PENDING
  // entries (PENDING -> PROCESSING, atomically — see sql/41_service_vendor_
  // daily_entry.sql), builds a Service PO items[] array from them, and calls
  // the SAME sp_nt_CreateServicePO path the old one-shot Vendor Driven submit
  // already used. On success the entries are marked CONSOLIDATED against the
  // new po_basic_sno; on any failure they're released back to PENDING so a
  // failed PO attempt never strands entries in limbo.
  static async consolidate({ entry_snos, consolidated_by, delivery_address, terms_conditions, purpose, po_type }) {
    const locked = await this.repo.lockEntries({ entry_snos, locked_by: consolidated_by });

    try {
      const first = locked[0];
      const items = locked.map((e) => ({
        service_sno: e.service_sno,
        qty: e.qty,
        unit: e.unit,
        agreed_unit_price: e.unit_price,
        total_cost: e.total_amount,
        specification: e.specification,
        remarks: e.remarks,
      }));

      const poResult = await ServicePOService.createServicePO({
        vendor_sno: first.vendor_sno,
        service_type_code: "VENDOR_BILL",
        po_type: po_type || "ONE_TIME",
        is_retrospective: true,
        com_sno: first.com_sno,
        div_sno: first.div_sno,
        brn_sno: first.brn_sno,
        dept_sno: first.dept_sno,
        delivery_address,
        terms_conditions,
        purpose,
        created_by: consolidated_by,
        items,
      });

      const po = poResult?.[0];
      await this.repo.finalizeEntries({ entry_snos, po_basic_sno: po.po_basic_sno, consolidated_by });

      return { ...po, entries_consolidated: locked.length };
    } catch (error) {
      await this.repo.releaseEntriesLock({ entry_snos }).catch(() => {});
      throw error;
    }
  }
}

export default ServiceVendorEntryService;
