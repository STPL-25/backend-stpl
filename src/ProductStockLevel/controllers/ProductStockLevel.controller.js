import ProductStockLevelService from "../services/ProductStockLevel.service.js";

class ProductStockLevelController {
  // GET /getProductStockLevels — full grid list for the admin screen
  static async getAll(req, res) {
    try {
      const data = await ProductStockLevelService.getAll();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POST /createProductStockLevel
  static async create(req, res) {
    try {
      const result = await ProductStockLevelService.create({ ...req.body, created_by: req.user_ecno });
      res.status(201).json({ success: true, message: "Stock level configuration saved", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // PUT /updateProductStockLevel
  static async update(req, res) {
    try {
      const result = await ProductStockLevelService.update({ ...req.body, modified_by: req.user_ecno });
      res.json({ success: true, message: "Stock level configuration updated", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // DELETE /deleteProductStockLevel — soft delete
  static async delete(req, res) {
    try {
      const result = await ProductStockLevelService.delete({ ...req.body, modified_by: req.user_ecno });
      res.json({ success: true, message: "Stock level configuration deleted", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // GET /getApplicableStockLevel?prod_sno=&com_sno=&div_sno=&brn_sno=&location_sno=
  // Reference lookup — returns {success:true, data:null} (not an error) when
  // nothing is configured for that product, which is the normal case for a
  // product that has never been added to this master.
  static async getApplicable(req, res) {
    try {
      const { prod_sno, com_sno, div_sno, brn_sno, location_sno } = req.query;
      const rows = await ProductStockLevelService.getApplicable({
        prod_sno: Number(prod_sno),
        com_sno: com_sno ? Number(com_sno) : null,
        div_sno: div_sno ? Number(div_sno) : null,
        brn_sno: brn_sno ? Number(brn_sno) : null,
        location_sno: location_sno ? Number(location_sno) : null,
      });
      res.json({ success: true, data: rows?.[0] ?? null });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }
}

export default ProductStockLevelController;
