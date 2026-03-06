import BudgetServices from "../Services/BudgeServices.js";
class BudgetControllers {
  static async postBudgetData(req, res) {
    try {
      const data = req.body;
      const result = await BudgetServices.postBudgetData(data);
      res.status(200).json({ success: true, data: result });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  }
  static async getBudgetData(req, res) {
    try {
      const result = await BudgetServices.getBudgetData(req.body.user);
      res.status(200).json({ success: true, data: result });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
}
}

export default BudgetControllers;
