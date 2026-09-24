
import { Readable } from "stream";
import multer from "multer";
import { nanoid } from "nanoid";
import path from "path";
import { FtpConnectionPool } from "./FtpConnectionPool.js";
const memoryStorage = multer.memoryStorage();
const upload = multer({ storage: memoryStorage });
const ftpConfig = {
  host:     process.env.FTP_HOST || "10.0.222.102",
  user:     process.env.FTP_USER || "1148",
  password: process.env.FTP_PASS || "$p@cek7m",
  secure:   false,
};


class FtpUploader {
  constructor(config) {
    this.ftpConfig = {
      host: config.host || "localhost",
      user: config.user || "anonymous",
      password: config.password || "",
      secure: config.secure || false,
    };
    this.basePath = config.basePath || "";
    // Persistent, reused logins instead of one fresh FTP login per
    // upload/check — see FtpConnectionPool for why. Size is small since
    // uploads are comparatively rare (form submits, not page renders);
    // override with FTP_UPLOAD_POOL_SIZE if needed.
    this.pool = new FtpConnectionPool(this.ftpConfig, Number(process.env.FTP_UPLOAD_POOL_SIZE) || 3);
  }

  /**
   * Absolute remote directory for a subDirectory, combined with basePath.
   * Always absolute (leading "/") so it's correct regardless of whatever
   * directory a previous call left a reused pooled connection sitting in.
   */
  _remoteDir(subDirectory) {
    const segments = [this.basePath, subDirectory].filter(Boolean).join("/");
    return "/" + segments.replace(/^\/+/, "");
  }

  /**
   * Uploads a file buffer to the FTP server
   * @param {Buffer} fileBuffer - The file content as a buffer
   * @param {string} filename - The name to save the file as
   * @param {string} subDirectory - Optional subdirectory inside the base path
   * @returns {Promise<{success: boolean, url: string, message: string}>}
   */
  async uploadFile(fileBuffer, filename, subDirectory = "") {
    const remoteDir = this._remoteDir(subDirectory);
    try {
      await this.pool.run(async (client) => {
        // Absolute cd (creating the directory if it doesn't exist yet) —
        // safe to call every time even on a reused connection.
        await client.ensureDir(remoteDir);

        // Create a readable stream from buffer and upload directly to FTP
        const fileStream = new Readable();
        fileStream.push(fileBuffer);
        fileStream.push(null); // Signals the end of the stream
        await client.uploadFrom(fileStream, filename);
      });

      console.log(`File uploaded successfully: ${filename} to ${remoteDir}`);
      return {
        success: true,
        message: "File uploaded successfully",
      };
    } catch (err) {
      console.error("FTP upload error:", err);
      return {
        success: false,
        message: `File upload failed: ${err.message}`,
      };
    }
  }

  /**
   * Uploads multiple files to the FTP server
   * @param {Array<{buffer: Buffer, filename: string}>} files - Array of file objects with buffer and filename
   * @param {string} subDirectory - Optional subdirectory inside the base path
   * @returns {Promise<{success: boolean, results: Array}>}
   */
  async uploadMultipleFiles(files, subDirectory = "") {
    // Connections are pooled now, so these can run concurrently — extra
    // files beyond the pool size just queue for a free connection instead
    // of each paying for (and serially waiting on) its own fresh login.
    const results = await Promise.all(
      files.map(async (file) => {
        const result = await this.uploadFile(file.buffer, file.filename, subDirectory);
        return {
          filename: file.filename,
          ...result,
        };
      })
    );

    return {
      success: results.every((r) => r.success),
      results: results,
    };
  }

  /**
   * Check if a file exists on the FTP server
   * @param {string} filename - The filename to check
   * @param {string} subDirectory - Optional subdirectory inside the base path
   * @returns {Promise<boolean>}
   */
  async fileExists(filename, subDirectory = "") {
    const remoteDir = this._remoteDir(subDirectory);
    try {
      return await this.pool.run(async (client) => {
        await client.cd(remoteDir);
        // A single SIZE command instead of listing the whole directory.
        // Missing file -> 550, caught below -> false, same as before.
        await client.size(filename);
        return true;
      });
    } catch {
      return false; // Directory or file doesn't exist
    }
  }
  /**
   * Upload a file if it exists in the request
   * @param {Object} file - The file from multer middleware
   * @param {string} filename - Optional custom filename to use
   * @returns {Promise<string>} - URL of the uploaded file or empty string
   */

  async uploadFileIfExists(file, subDirectory) {
  if (!file) return "";

  const fileExtension = path.extname(file.originalname);
  const baseName = path.basename(file.originalname, fileExtension);
  const uniqueFileName = `${baseName}_${nanoid(10)}${fileExtension}`;

  // Upload using the unique filename
  const result = await this.uploadFile(file.buffer, uniqueFileName, subDirectory);
  return result.success
    ? `${process.env.SERVER_URL}/dwl/${subDirectory}/${uniqueFileName}`
    : "";
}
}
// Create FTP uploader instance
const ftpUploader = new FtpUploader(ftpConfig);

export {ftpUploader,upload}
