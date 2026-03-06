import SignUpControllers from "../Controllers/SignUpControllers.js";
import express from "express";

const signUpRouter = express.Router();

signUpRouter.post("/sign_up", SignUpControllers.createUser);
signUpRouter.post("/log_user", SignUpControllers.logUser);
signUpRouter.get("/get_all_users_sign_up", SignUpControllers.getAllUsers);

export default signUpRouter;
