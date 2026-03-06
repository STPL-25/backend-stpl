import BudgetRepo from "../Repository/BudgetRepo.js";

class BudgetServices {
    static budgetRepository = new BudgetRepo();

    static async postBudgetData(data) {
        return await this.budgetRepository.postBudgetData(data);
    }

    static async getBudgetData(data) {
        
        return await this.budgetRepository.getBudgetData(data);
    }

}
export default BudgetServices;
