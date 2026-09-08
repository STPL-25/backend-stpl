import TermsConditionsRepository from "../repository/TermsConditions.repository.js";

class TermsConditionsService {
  static repo = new TermsConditionsRepository();

  static async getAll() {
    return this.repo.getAll();
  }

  static async create(data) {
    if (!data?.tc_title || !data?.tc_text) {
      throw new Error("tc_title and tc_text are required.");
    }
    if (!data?.com_sno || !data?.div_sno || !data?.brn_sno || !data?.dept_sno) {
      throw new Error("com_sno, div_sno, brn_sno and dept_sno are required.");
    }
    return this.repo.create(data);
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

  static async getDefault(scope) {
    const { com_sno, div_sno, brn_sno, dept_sno } = scope ?? {};
    if (!com_sno || !div_sno || !brn_sno || !dept_sno) {
      throw new Error("com_sno, div_sno, brn_sno and dept_sno are required.");
    }
    return this.repo.getDefault({ com_sno, div_sno, brn_sno, dept_sno });
  }
}

export default TermsConditionsService;
