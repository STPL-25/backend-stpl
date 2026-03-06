import CommonMasterRepo from "../Repository/CommonMasterRepo.js";
import HierarchyMasterRepo from "../Repository/HierarchyMasterRepo.js";
class CommonMasterServices {
    static commonMasterRepository = new CommonMasterRepo();
    static hierarchyMasterRepository = new HierarchyMasterRepo();

    static async getAllCommonMasters(masterField) {
        return this.commonMasterRepository.getAllCommonMasters(masterField);
    }

    static async getCommonMasterById(id, masterField) {
        return this.commonMasterRepository.getCommonMasterById(id, masterField);
    }

    static async createCommonMaster(masterField, data) {
        return this.commonMasterRepository.createCommonMaster(masterField, data);
    }

    static async updateCommonMaster(id, masterField, data) {
        return this.commonMasterRepository.updateCommonMaster(id, masterField, data);
    }

    static async deleteCommonMaster(id, masterField) {
        return this.commonMasterRepository.deleteCommonMaster(id, masterField);
    }
    static async getAllMasterDataByHierarchy(data) {
        return this.hierarchyMasterRepository.getAllHierarchyData(data);
    }
    static async getRequiredMasterForOptions(data) {
        return this.commonMasterRepository.getRequiredMasterForOptions(data);
    }
}
export default CommonMasterServices;
