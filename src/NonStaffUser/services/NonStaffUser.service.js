import bcrypt from "bcryptjs";
import crypto from "crypto";
import NonStaffUserRepository from "../repository/NonStaffUser.repository.js";
import { sendNonStaffInviteEmail } from "../../Utils/Notify/notifyClient.js";

const SALT_ROUNDS = 10;
const PORTAL_URL = process.env.NONSTAFF_PORTAL_URL || "http://localhost:5173/nonstaff";

function generateTempPassword() {
  // 10 URL-safe chars, e.g. "aZ3-kQ9pLm" — same scheme as the Supplier portal
  return crypto.randomBytes(8).toString("base64url").slice(0, 10);
}

class NonStaffUserService {
  static repo = new NonStaffUserRepository();

  static async createUser({ login_id, full_name, designation_sno, email, phone, created_by }) {
    console.log("Creating non-staff user:", { login_id, full_name, designation_sno, email, phone, created_by });
    if (!login_id || !full_name || !designation_sno || !email) {
      throw new Error("login_id, full_name, designation_sno and email are required.");
    }

    const tempPassword = generateTempPassword();
    const password_hash = await bcrypt.hash(tempPassword, SALT_ROUNDS);

    const [login] = await this.repo.createLogin({
      login_id, full_name, designation_sno, email, phone, password_hash, created_by,
    });

    const mailResult = await sendNonStaffInviteEmail({
      to: email,
      fullName: full_name,
      designationName: login?.designation_name,
      loginId: login_id,
      tempPassword,
      portalUrl: PORTAL_URL,
    });

    return { login, emailSent: mailResult.sent };
  }

  static async login({ login_id, password }) {
    if (!login_id || !password) {
      throw new Error("login_id and password are required.");
    }

    const [account] = await this.repo.findLoginById(login_id);
    if (!account || account.is_active !== "Y") {
      throw new Error("Invalid login ID or password.");
    }

    const matches = await bcrypt.compare(password, account.password_hash);
    if (!matches) {
      throw new Error("Invalid login ID or password.");
    }

    const nonstaff = {
      login_id: account.login_id,
      full_name: account.full_name,
      email: account.email,
      designation_sno: account.designation_sno,
      designation_name: account.designation_name,
      must_reset_password: account.must_reset_password === "Y",
    };

    return { must_reset_password: nonstaff.must_reset_password, nonstaff };
  }

  static async resetPassword(login_id, new_password) {
    if (!new_password || new_password.length < 6) {
      throw new Error("New password must be at least 6 characters.");
    }
    if (login_id && new_password.toUpperCase().includes(String(login_id).toUpperCase())) {
      throw new Error("Password must not contain your login ID.");
    }
    const password_hash = await bcrypt.hash(new_password, SALT_ROUNDS);
    const [result] = await this.repo.setPassword({ login_id, password_hash });
    return result;
  }

  static async listUsers() {
    return this.repo.listUsers();
  }

  // Re-derives must_reset_password from the DB (not the login response) so a
  // page refresh mid-flow can't let a first-time user skip the forced reset.
  static async getMe(login_id) {
    const [account] = await this.repo.findLoginById(login_id);
    if (!account || account.is_active !== "Y") {
      throw new Error("Account not found or inactive.");
    }
    return {
      nonstaff: {
        login_id: account.login_id,
        full_name: account.full_name,
        email: account.email,
        designation_sno: account.designation_sno,
        designation_name: account.designation_name,
      },
      must_reset_password: account.must_reset_password === "Y",
    };
  }
}

export default NonStaffUserService;
