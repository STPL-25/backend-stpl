import CommonMasterServices from "../Services/CommonMasterServices.js";
import { validateMasterCreate } from "../validation/masterValidation.js";

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

      // Required-field enforcement — a form (or a direct API call) that
      // omits mandatory fields is rejected here, before any stored
      // procedure runs. The UI can be bypassed; this cannot.
      const { valid, errors } = validateMasterCreate(masterField, req.body);
      if (!valid) {
        return res.status(422).json({
          success: false,
          error: errors.join("; "),
          fields: errors,
        });
      }

      const data = await CommonMasterServices.createCommonMaster(
        masterField,
        req.body
      );

      // A 201 must mean a row actually exists now. If the stored procedure
      // returned no recordset (e.g. it no-opped on a payload it didn't like
      // instead of raising an error), that is a failure, not a success —
      // telling the user "created successfully" here would be a lie.
      const created = Array.isArray(data) ? data.length > 0 : Boolean(data);
      if (!created) {
        return res.status(500).json({
          success: false,
          error: `${masterField} was not created — the database returned no record.`,
        });
      }

      req.io?.emit("master:updated", { masterField, action: "created" });

      res.status(201).json({
        success: true,
        data: data,
        message: `${masterField} created successfully`,
      });
    } catch (error) {
      console.log(error)
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

      req.io?.emit("master:updated", { masterField, action: "updated" });

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

      req.io?.emit("master:updated", { masterField, action: "deleted" });

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
