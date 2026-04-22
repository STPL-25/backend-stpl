
import ftp from "basic-ftp";
import { Readable } from "stream";
import multer from "multer";
import { nanoid } from "nanoid";
import path from "path";
import fs from "fs";
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
  }

  /**
   * Uploads a file buffer to the FTP server
   * @param {Buffer} fileBuffer - The file content as a buffer
   * @param {string} filename - The name to save the file as
   * @param {string} subDirectory - Optional subdirectory inside the base path
   * @returns {Promise<{success: boolean, url: string, message: string}>}
   */
  async uploadFile(fileBuffer, filename, subDirectory = "") {
    const client = new ftp.Client();
    client.ftp.verbose = false;
    try {
      // Connect to FTP server
      await client.access(this.ftpConfig);

      // Navigate to the base directory
      if (this.basePath) {
        await client.cd(this.basePath);
      }

      // Navigate to subdirectory if provided
      if (subDirectory) {
        try {
          await client.cd(subDirectory);
        } catch (err) {
          await client.mkdir(subDirectory);
          await client.cd(subDirectory);
        }
      }

      // Create a readable stream from buffer and upload directly to FTP
      const fileStream = new Readable();
      fileStream.push(fileBuffer);
      fileStream.push(null); // Signals the end of the stream
      await client.uploadFrom(fileStream, filename);

      return {
        success: true,
        message: "File uploaded successfully",
      };
    } catch (err) {
      return {
        success: false,
        message: `File upload failed: ${err.message}`,
      };
    } finally {
      client.close();
    }
  }

  /**
   * Uploads multiple files to the FTP server
   * @param {Array<{buffer: Buffer, filename: string}>} files - Array of file objects with buffer and filename
   * @param {string} subDirectory - Optional subdirectory inside the base path
   * @returns {Promise<{success: boolean, results: Array}>}
   */
  async uploadMultipleFiles(files, subDirectory = "") {
    const results = [];

    for (const file of files) {
      const result = await this.uploadFile(
        file.buffer,
        file.filename,
        subDirectory
      );
      results.push({
        filename: file.filename,
        ...result,
      });
    }

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
    const client = new ftp.Client();
    client.ftp.verbose = false;

    try {
      await client.access(this.ftpConfig);

      if (this.basePath) {
        await client.cd(this.basePath);
      }

      if (subDirectory) {
        try {
          await client.cd(subDirectory);
        } catch (err) {
          return false; // Directory doesn't exist
        }
      }

      const list = await client.list();
      return list.some((file) => file.name === filename);
    } catch {
      return false;
    } finally {
      client.close();
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

