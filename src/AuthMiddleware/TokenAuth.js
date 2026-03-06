import { configDotenv } from "dotenv";
import jwt from "jsonwebtoken";
import crypto from "crypto";
configDotenv();

const JWT_SECRET = process.env.JWT_SECRET;
const CRYPTO_SECRET = process.env.CRYPTO_SECRET;
const CRYPTO_ALGORITHM = 'aes-256-cbc';

function encryptData(data) {
  try {
    const text = JSON.stringify(data);
    const key = crypto.pbkdf2Sync(CRYPTO_SECRET, 'salt', 1000, 32, 'sha256');
    const iv = crypto.randomBytes(16);

    const cipher = crypto.createCipheriv(CRYPTO_ALGORITHM, key, iv);
    let encrypted = cipher.update(text, 'utf8', 'hex');
    encrypted += cipher.final('hex');

    return {
      token: encrypted,
      iv: iv.toString('hex')
    };
  } catch (error) {
    throw new Error('Encryption failed: ' + error.message);
  }
}

// Decrypt function - must use same iterations as encryptData (1000)
function decryptData(encryptedObj) {
  try {
    const key = crypto.pbkdf2Sync(CRYPTO_SECRET, 'salt', 1000, 32, 'sha256');
    const iv = Buffer.from(encryptedObj.iv, 'hex');
    
    const decipher = crypto.createDecipheriv(CRYPTO_ALGORITHM, key, iv);
    let decrypted = decipher.update(encryptedObj.encrypted, 'hex', 'utf8');
    decrypted += decipher.final('utf8');
    
    return JSON.parse(decrypted);
  } catch (error) {
    throw new Error('Decryption failed: ' + error.message);
  }
}

// Rest of your functions remain the same
function createJWTToken(userData) {
  try {
    const payload = {
      user: userData,
      iat: Math.floor(Date.now() / 1000),
      exp: Math.floor(Date.now() / 1000) + (24 * 60 * 60)
    };

    return jwt.sign(payload, JWT_SECRET, {
      algorithm: 'HS256',
    });
  } catch (error) {
    throw new Error('JWT creation failed: ' + error.message);
  }
}

function doubleEncodeUserData(userData) {
  try {
    const jwtToken = createJWTToken(userData);
    const encryptedJWT = encryptData({ token: jwtToken });
    return encryptedJWT;
  } catch (error) {
    throw new Error('Double encoding failed: ' + error.message);
  }
}

export { doubleEncodeUserData, decryptData, createJWTToken };
export default doubleEncodeUserData;
