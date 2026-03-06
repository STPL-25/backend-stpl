
import express from 'express'
import ftp from 'basic-ftp'


const imageRouter = express();

// FTP connection configuration
const ftpConfig = {
  host: '10.0.222.102',
  user: '1148',
  password: '$p@cek7m',
  secure: false
};



class FTPPool {
  constructor(config, maxConnections = 5) {
    this.config = config;
    this.maxConnections = maxConnections;
    this.pool = [];
    this.inUse = new Set();
  }

  async acquire() {
    let client = this.pool.find(c => !this.inUse.has(c));

    // ❗Remove closed/stale connections
    if (client && client.closed) {
      this.pool = this.pool.filter(c => c !== client);
      client = null;
    }

    if (!client && this.pool.length < this.maxConnections) {
      client = new ftp.Client(120000);
      client.ftp.verbose = false;
      await client.access(this.config);
      this.pool.push(client);
    } else if (!client) {
      await new Promise(resolve => setTimeout(resolve, 100));
      return this.acquire();
    }

    this.inUse.add(client);
    return client;
  }

  release(client) {
    if (!client || client.closed) {
      this.pool = this.pool.filter(c => c !== client);
      return;
    }
    this.inUse.delete(client);
  }
}

const ftpPool = new FTPPool(ftpConfig, 5);


imageRouter.get('/dwl/:imagepath/:subpath/:filename', async (req, res) => {
  const { filename, imagepath, subpath } = req.params;

  let client;

  try {
    client = await ftpPool.acquire();

    // ❗Avoid cd('/'); instead ensure directory exists
    await client.ensureDir(`/${imagepath}/${subpath}`);

    const list = await client.list();
    const file = list.find(f => f.name === filename);

    if (!file) {
      ftpPool.release(client);
      return res.status(404).json({ message: "File not found" });
    }

    res.setHeader("Content-Type", "application/octet-stream");
    res.setHeader("Content-Disposition", `inline; filename="${filename}"`);
    res.setHeader("Content-Length", file.size);

    // ❗Release AFTER download completes
    res.on("finish", () => ftpPool.release(client));
    res.on("close", () => ftpPool.release(client));

    await client.downloadTo(res, filename);

  } catch (err) {
    console.error("FTP operation error:", err);

    if (client) ftpPool.release(client);

    if (!res.headersSent) {
      res.status(500).json({ error: "FTP download failed" });
    } else {
      res.end();
    }
  }
});

export default imageRouter;