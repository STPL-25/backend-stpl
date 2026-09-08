import TermsConditionsService from "../services/TermsConditions.service.js";

class TermsConditionsController {
  // GET /getTermsConditions — full grid list for the admin screen
  static async getAll(req, res) {
    try {
      const data = await TermsConditionsService.getAll();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POST /createTermsConditions
  static async create(req, res) {
    try {
      const result = await TermsConditionsService.create({ ...req.body, created_by: req.user_ecno });
      res.status(201).json({ success: true, message: "Terms & conditions saved", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // PUT /updateTermsConditions
  static async update(req, res) {
    try {
      const result = await TermsConditionsService.update({ ...req.body, modified_by: req.user_ecno });
      res.json({ success: true, message: "Terms & conditions updated", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // DELETE /deleteTermsConditions — soft delete
  static async delete(req, res) {
    try {
      const result = await TermsConditionsService.delete({ ...req.body, modified_by: req.user_ecno });
      res.json({ success: true, message: "Terms & conditions deleted", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // GET /getDefaultTermsConditions?com_sno=&div_sno=&brn_sno=&dept_sno=
  // Used by PO creation to prefill the terms_conditions textarea. Returns
  // {success:true, data:null} (not an error) when no default is configured
  // for that scope — that's an expected, normal case.
  static async getDefault(req, res) {
    try {
      const { com_sno, div_sno, brn_sno, dept_sno } = req.query;
      const rows = await TermsConditionsService.getDefault({
        com_sno: Number(com_sno),
        div_sno: Number(div_sno),
        brn_sno: Number(brn_sno),
        dept_sno: Number(dept_sno),
      });
      res.json({ success: true, data: rows?.[0] ?? null });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }
}

export default TermsConditionsController;
