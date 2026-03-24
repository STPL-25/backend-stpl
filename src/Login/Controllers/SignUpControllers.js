import SignUpService from "../Services/SignUpServices.js";
import { createJWTToken } from "../../AuthMiddleware/TokenAuth.js";

class SignUpControllers {

    static async createUser(req, res) {
        try {
            const userData = req.body;
            const result = await SignUpService.createUser('sign_up', userData);

            if (req.io) {
                req.io.emit("user:new", {
                    ecno:  userData.ecno  ?? null,
                    ename: userData.ename ?? null,
                    dept:  userData.dept  ?? null,
                });
            }

            res.status(201).json({
                success: true,
                message: "User created successfully",
                data: result
            });
        } catch (error) {
            const status = error.message.includes("already exists") ? 409 : 500;
            res.status(status).json({ success: false, message: error.message });
        }
    }

    static async logUser(req, res) {
        try {
            const { ecno, sign_up_pass } = req.body;
            if (!ecno || !sign_up_pass) {
                return res.status(400).json({ success: false, message: "ECNO and password are required" });
            }

            const result = await SignUpService.logUser(ecno, sign_up_pass);
            if (!result || result.length === 0) {
                return res.status(401).json({ success: false, message: "Invalid credentials" });
            }

            // Create JWT and store it server-side in the session.
            // The client only receives an HttpOnly session cookie — the JWT is never exposed.
            const jwtToken = createJWTToken(result);
            req.session.jwt = jwtToken;
            await new Promise((resolve, reject) => {
                req.session.save((err) => (err ? reject(err) : resolve()));
            });

            req.io.to(`user:${ecno}`).emit("user_connected", { message: "User logged in" });

            // Return user data (not the token) for the frontend to display
            res.status(200).json({
                success: true,
                message: "User logged in successfully",
                data: result
            });
        } catch (error) {
            const status = error.message.includes("does not exist") ? 404 :
                           error.message.includes("Invalid") ? 401 : 500;
            res.status(status).json({ success: false, message: error.message });
        }
    }

    static async logoutUser(req, res) {
        req.session.destroy((err) => {
            if (err) return res.status(500).json({ success: false, message: "Logout failed" });
            res.clearCookie("sessionId");
            res.json({ success: true, message: "Logged out successfully" });
        });
    }

    // Returns the current authenticated user's data (read from session-backed JWT).
    // Protected by verifyJWT — only reachable with a valid session.
    static async getMe(req, res) {
        res.json({ success: true, data: req.user });
    }

    static async getAllUsers(req, res) {
        try {
            const result = await SignUpService.getAllUsers();
            res.status(200).json({ success: true, message: "Users fetched successfully", data: result });
        } catch (error) {
            res.status(500).json({ success: false, message: error.message });
        }
    }
}

export default SignUpControllers;
