import SignUpService from "../Services/SignUpServices.js";

import doubleEncodeUserData from "../../AuthMiddleware/TokenAuth.js";

class SignUpControllers {
    
    static async createUser(req, res) {
        try {
            const userData = req.body;

            const result = await SignUpService.createUser('sign_up', userData);

            // Broadcast to all connected admins so the user-list refreshes in real-time
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
            res.status(status).json({
                success: false,
                message: error.message,
            });
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
            // Emit only to the specific user's room, not broadcast to everyone
            req.io.to(`user:${ecno}`).emit("user_connected", { message: "User logged in" });
            res.status(200).json({
                success: true,
                message: "User logged in successfully",
                data: doubleEncodeUserData(result)
            });
        } catch (error) {
            const status = error.message.includes("does not exist") ? 404 :
                           error.message.includes("Invalid") ? 401 : 500;
            res.status(status).json({
                success: false,
                message: error.message,
            });
        }
    }
    static async getAllUsers(req, res) {
        try {
            const result = await SignUpService.getAllUsers();
            res.status(200).json({
                success: true,
                message: "Users fetched successfully",
                data: result
            });
        } catch (error) {
            res.status(500).json({
                success: false,
                message: error.message,
            });
        }
    }
}

export default SignUpControllers;
