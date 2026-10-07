import svc from "./KycVerification.service.js";

const wrap = (fn) => async (req, res) => {
  try {
    res.json({ success: true, data: await fn(req) });
  } catch (error) {
    console.error("[kyc-verification]", error.message);
    res.status(error.statusCode ?? 500).json({ success: false, error: error.message });
  }
};

export default {
  verifyPan: wrap((req) => svc.verifyPan(req.body?.pan)),
  verifyGstin: wrap((req) => svc.verifyGstin(req.body?.gst)),
  verifyUdyam: wrap((req) => svc.verifyUdyam(req.body?.msme_no)),
  checkDuplicate: wrap((req) => svc.checkDuplicate(req.body ?? {})),
  verifyIfsc: wrap((req) => svc.verifyIfsc(req.body?.ifsc)),
  verifyBank: wrap((req) => svc.verifyBank(req.body?.ac_number, req.body?.ifsc, req.body?.name)),
};
