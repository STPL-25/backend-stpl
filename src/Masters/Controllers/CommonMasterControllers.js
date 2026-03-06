import CommonMasterServices from "../Services/CommonMasterServices.js";

class CommonMasterControllers {
  static async getAllMasterData(req, res) {
    try {
      const { masterField } = req.params;
      const data = await CommonMasterServices.getAllCommonMasters(masterField);
      res.json({
        success: true,
        data: data,
        masterField: masterField,
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message,
      });
    }
  }

  static async getMasterDataById(req, res) {
    try {
      const { id, masterField } = req.params;
      const data = await CommonMasterServices.getCommonMasterById(
        id,
        masterField
      );

      if (!data || data.length === 0) {
        return res.status(404).json({
          success: false,
          error: "Master data not found",
        });
      }

      res.json({
        success: true,
        data: data,
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message,
      });
    }
  }

  static async createMasterData(req, res) {
    try {
      const { masterField } = req.params;
      const data = await CommonMasterServices.createCommonMaster(
        masterField,
        req.body
      );

      res.status(201).json({
        success: true,
        data: data,
        message: `${masterField} created successfully`,
      });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateMasterData(req, res) {
    try {
      const { id, masterField } = req.params;
      const data = await CommonMasterServices.updateCommonMaster(
        id,
        masterField,
        req.body
      );

      if (!data) {
        return res.status(404).json({
          success: false,
          error: "Master data not found",
        });
      }

      res.json({
        success: true,
        data: data,
        message: `${masterField} updated successfully`,
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message,
      });
    }
  }

  static async deleteMasterData(req, res) {
    try {
      const { id, masterField } = req.params;
      const result = await CommonMasterServices.deleteCommonMaster(
        id,
        masterField
      );

      if (!result) {
        return res.status(404).json({
          success: false,
          error: "Master data not found",
        });
      }

      res.json({
        success: true,
        message: `${masterField} deleted successfully`,
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message,
      });
    }
  }
  static async getAllMasterDataByHierarchy(req, res) {
    try {
      const data = await CommonMasterServices.getAllMasterDataByHierarchy(
        req.body
      );
      res.json({
        success: true,
        data: data,
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message,
      });
    }
  }

  static async getRequiredMasterForOptions(req, res) {
    try {
      const data = await CommonMasterServices.getRequiredMasterForOptions(
        req.body.masterFields
      );

      res.json({
        success: true,
        data: data,
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message,
      });
    }
  }

}

export default CommonMasterControllers;
