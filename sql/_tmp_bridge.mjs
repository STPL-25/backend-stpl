// THROWAWAY: mounts the REAL routers/controllers/services against the dev DB with a fake session
// (KTM1148) and a stubbed FTP upload, so screens can be driven without a login. Delete after use.
import "dotenv/config";
import express from "express";
import cors from "cors";
import ServiceAgreementRouter from "../src/ServiceAgreement/routes/ServiceAgreement.routes.js";
import ServicePoRouter from "../src/ServicePo/routes/ServicePo.routes.js";
import LoanVoucherRouter from "../src/LoanVoucher/routes/LoanVoucher.routes.js";
import commonMasterRouter from "../src/Masters/Routes/CommonMasterRoutes.js";
import { ftpUploader } from "../src/Utils/ImagesUpload/ImgUpload.js";

ftpUploader.uploadFileIfExists = async (file) => `https://example.invalid/demo/${encodeURIComponent(file?.originalname || "agreement.pdf")}`;

const app = express();
app.use(cors({ origin: true, credentials: true }));
app.use(express.json({ limit: "5mb" }));
app.use((req, _res, next) => {
  req.user_ecno = "KTM1148";
  req.io = { to: () => ({ emit: () => {} }) };
  req.redisClient = null;
  next();
});
app.use("/api/service_agreement", ServiceAgreementRouter);
app.use("/api/service_po", ServicePoRouter);
app.use("/api/loan_voucher", LoanVoucherRouter);
app.use("/api/common_master", commonMasterRouter);

const port = 7199;
app.listen(port, () => console.log(`bridge listening on ${port}`));
