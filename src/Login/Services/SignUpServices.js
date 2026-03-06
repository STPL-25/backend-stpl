import SignUpRepo from "../Repository/SignUpRepo.js";

class SignUpService {
  static signUpRepository = new SignUpRepo();

  static async createUser(masterField, userData) {
    try {
      if (!userData) throw new Error("User data is required");
      if (!userData.ecno) throw new Error("ECNO is required");

      const isUserExists = await this.#isUserExists(userData.ecno);
      if (isUserExists) throw new Error("User already exists. Please login.");

      return await this.signUpRepository.createUser(masterField, userData);
    } catch (error) {
      throw error;
    }
  }

  static async #isUserExists(ecno) {
    if (!ecno || typeof ecno !== "string") throw new Error("Valid ECNO is required");
    return await this.signUpRepository.isUserExists(ecno.trim());
  }

  static async logUser(ecno, sign_up_pass) {
    const userExists = await this.#isUserExists(ecno);
    if (!userExists) throw new Error("User does not exist. Please sign up first.");
    return await this.signUpRepository.logInUser("log_in", ecno, sign_up_pass);
  }

  static async getAllUsers() {
    return await this.signUpRepository.getAllUsers();
  }
}

export default SignUpService;
