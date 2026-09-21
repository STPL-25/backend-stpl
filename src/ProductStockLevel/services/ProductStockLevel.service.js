import ProductStockLevelRepository from "../repository/ProductStockLevel.repository.js";

class ProductStockLevelService {
  static repo = new ProductStockLevelRepository();

  static async getAll() {
    return this.repo.getAll();
  }

  static async create(data) {
    if (!data?.prod_sno) {
      throw new Error("prod_sno is required.");
    }
    if (!data?.scope_type || !["ORG", "LOCATION"].includes(data.scope_type)) {
      throw new Error("scope_type must be either ORG or LOCATION.");
    }
    if (data.min_qty == null || data.max_qty == null || data.reorder_level == null) {
      throw new Error("min_qty, max_qty and reorder_level are all required.");
    }
    return this.repo.create(data);
  }

  static async update(data) {
    if (!data?.stock_level_sno) {
      throw new Error("stock_level_sno is required.");
    }
    return this.repo.update(data);
  }

  static async delete(data) {
    if (!data?.stock_level_sno) {
      throw new Error("stock_level_sno is required.");
    }
    return this.repo.delete(data);
  }

  static async getApplicable(scope) {
    const { prod_sno } = scope ?? {};
    if (!prod_sno) {
      throw new Error("prod_sno is required.");
    }
    return this.repo.getApplicable(scope);
  }
}

export default ProductStockLevelService;
