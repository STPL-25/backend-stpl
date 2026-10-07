import TermsConditionsRepository from "../repository/TermsConditions.repository.js";

class TermsConditionsService {
  static repo = new TermsConditionsRepository();

  static async getAll(hierarchyJson) {
    return this.repo.getAll(hierarchyJson);
  }

  // `scopes` is an array of exact {com_sno, div_sno, brn_sno, dept_sno} chains
  // (one per selected department); one master row is stored per scope so the
  // per-scope default flag and PO lookup keep working unchanged. A legacy
  // single com_sno/div_sno/brn_sno/dept_sno payload is still accepted.
  static async create(data) {
    if (!data?.tc_title || !data?.tc_text) {
      throw new Error("tc_title and tc_text are required.");
    }
    const scopes = Array.isArray(data.scopes) && data.scopes.length
      ? data.scopes
      : [{ com_sno: data.com_sno, div_sno: data.div_sno, brn_sno: data.brn_sno, dept_sno: data.dept_sno }];
    if (scopes.some((s) => !s?.com_sno || !s?.div_sno || !s?.brn_sno || !s?.dept_sno)) {
      throw new Error("com_sno, div_sno, brn_sno and dept_sno are required.");
    }
    const { scopes: _ignored, ...base } = data;
    const results = [];
    for (const s of scopes) {
      const rows = await this.repo.create({
        ...base,
        com_sno: s.com_sno, div_sno: s.div_sno, brn_sno: s.brn_sno, dept_sno: s.dept_sno,
      });
      results.push(...(rows ?? []));
    }
    return results;
  }

  static async update(data) {
    if (!data?.tc_sno) {
      throw new Error("tc_sno is required.");
    }
    return this.repo.update(data);
  }

  static async delete(data) {
    if (!data?.tc_sno) {
      throw new Error("tc_sno is required.");
    }
    return this.repo.delete(data);
  }

  static async getForScope(scope) {
    const { com_sno, div_sno, brn_sno, dept_sno } = scope ?? {};
    if (!com_sno || !div_sno || !brn_sno || !dept_sno) {
      throw new Error("com_sno, div_sno, brn_sno and dept_sno are required.");
    }
    return this.repo.getForScope({ com_sno, div_sno, brn_sno, dept_sno });
  }

  static async getDefault(scope) {
    const { com_sno, div_sno, brn_sno, dept_sno } = scope ?? {};
    if (!com_sno || !div_sno || !brn_sno || !dept_sno) {
      throw new Error("com_sno, div_sno, brn_sno and dept_sno are required.");
    }
    return this.repo.getDefault({ com_sno, div_sno, brn_sno, dept_sno });
  }
}

export default TermsConditionsService;
