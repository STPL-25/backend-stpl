import CommonMasterServices from "../Services/CommonMasterServices.js"

class CommonMasterControllers {
    static async getBasicDetailsByFields(req, res) {
        try {
            const masterField = req.body;
            const data = await CommonMasterServices.getBasicDetailsByFields(masterField);
            res.json({ success: true, data, masterField });
        } catch (error) {
            res.status(500).json({ success: false, error: error.message });
        }
    }

    static async getBasicDetailsEmployee(req, res) {
        try {
            const masterField = req.body;
            const data = await CommonMasterServices.getBasicDetailsEmployee(masterField);
            res.json({ success: true, data });
        } catch (error) {
            res.status(500).json({ success: false, error: error.message });
        }
    }
    

         
}

export default CommonMasterControllers;
