import NonStaffUserService from "../services/NonStaffUser.service.js";
import { createJWTToken } from "../../AuthMiddleware/TokenAuth.js";

class NonStaffUserController {
  // Staff-only (verifyJWT) — creates a non-staff login and emails the temp password
  static async createUser(req, res) {
    try {
      console.log("Received request to create non-staff user:", req.body);
      const { login_id, full_name, designation_sno, email, phone } = req.body ?? {};
      const result = await NonStaffUserService.createUser({
        login_id,
        full_name,
        designation_sno,
        email,
        phone,
        created_by: req.user_ecno,
      });
      res.json({ success: true, data: result, message: "Invite email sent" });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // Staff-only (verifyJWT) — admin management grid
  static async listUsers(req, res) {
    try {
      const data = await NonStaffUserService.listUsers();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Public — signs in through the same session-cookie mechanism as staff
  // (SignUpControllers.logUser) so a non-staff login lands on the same
  // Dashboard, not a separate portal.
  static async login(req, res) {
    try {
      const { login_id, password } = req.body ?? {};
      const { nonstaff } = await NonStaffUserService.login({ login_id, password });

      const jwtToken = createJWTToken(nonstaff);
      req.session.jwt = jwtToken;
      req.session.createdAt = Date.now();
      req.session.lastActivity = Date.now();
      await new Promise((resolve, reject) => {
        req.session.save((err) => (err ? reject(err) : resolve()));
      });

      res.json({ success: true, data: nonstaff });
    } catch (error) {
      res.status(401).json({ success: false, error: error.message });
    }
  }

  // Session-authenticated (verifyJWT) — forced/self password reset
  static async resetPassword(req, res) {
    try {
      const { new_password } = req.body ?? {};
      const data = await NonStaffUserService.resetPassword(req.user.login_id, new_password);
      res.json({ success: true, data, message: "Password updated" });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // Session-authenticated (verifyJWT) — re-derives must_reset_password from the DB on mount
  static async me(req, res) {
    try {
      const data = await NonStaffUserService.getMe(req.user.login_id);
      res.json({ success: true, data });
    } catch (error) {
      res.status(401).json({ success: false, error: error.message });
    }
  }
}

export default NonStaffUserController;
