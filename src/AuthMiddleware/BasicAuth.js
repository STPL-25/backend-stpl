import { configDotenv } from "dotenv";
configDotenv();

const basicAuth = (req, res, next) => {
  const isSecure = req.secure || req.headers["x-forwarded-proto"] === "https";
  if (!isSecure) {
    return res.status(403).send("HTTPS required.");
  }

  const b64auth = (req.headers.authorization || "").split(" ")[1] || "";
  const [Username, Password] = Buffer.from(b64auth, "base64").toString().split(":");
  if (Username && Password && Username === process.env.USER_NAME && Password === process.env.USER_PASSWORD) {
    return next();
  }

  res.set("WWW-Authenticate", 'Basic realm="401"');
  res.status(401).send("Authentication required.");
};



export default basicAuth;