import ftp from "basic-ftp";

// Connection-level failures worth discarding the dead login for and
// retrying once on a fresh one (idle server timeout, dropped socket,
// connection reset). A normal FTP protocol result — e.g. 550 "file/dir
// not found" — is NOT a connection error: the control connection is still
// healthy and the result must propagate immediately (callers rely on it,
// e.g. to return 404), never be retried.
function isConnectionError(err) {
  if (!err) return false;
  if (err.code === 421) return true; // "Service not available, closing control connection" (idle timeout)
  const netCodes = ["ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "EPIPE", "ENOTFOUND", "EHOSTUNREACH"];
  if (netCodes.includes(err.code)) return true;
  return /closed|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EPIPE|premature close|not connected/i.test(
    String(err.message || "")
  );
}

/**
 * A small fixed-size pool of persistent, authenticated FTP control
 * connections.
 *
 * This replaces the previous "new ftp.Client() -> login -> ... -> close()"
 * pattern that was used for every single upload/download/exists check.
 * Opening a fresh FTP login per file/request is slow (a full auth
 * handshake per operation) and, under any real concurrency (a form with
 * several attachments, a page rendering many thumbnails), was blowing
 * straight through the FTP server's max concurrent/per-IP login limit.
 *
 * Connections here are reused across calls. Operations beyond `size`
 * concurrent callers simply queue for the next free pooled connection
 * instead of opening a new login — that queue is what actually caps
 * concurrent logins at the server, regardless of how bursty the traffic is.
 */
export class FtpConnectionPool {
  constructor(config, size = 4) {
    this.config = config;
    this.size = Math.max(1, size);
    this.slots = Array.from({ length: this.size }, () => ({ client: null, busy: false }));
    this.waiters = [];
  }

  async _connect() {
    const client = new ftp.Client(30_000);
    client.ftp.verbose = false;
    await client.access(this.config);
    return client;
  }

  async _acquire() {
    let slot = this.slots.find((s) => !s.busy);
    if (!slot) {
      // Every slot is busy — wait in line for the next release() instead
      // of opening an extra login.
      slot = await new Promise((resolve) => this.waiters.push(resolve));
    }
    slot.busy = true;
    if (!slot.client || slot.client.closed) {
      try {
        slot.client = await this._connect();
      } catch (err) {
        slot.busy = false;
        this._wakeNext();
        throw err;
      }
    }
    return slot;
  }

  _release(slot, { discard = false } = {}) {
    if (discard && slot.client) {
      try {
        slot.client.close();
      } catch {
        /* already dead */
      }
      slot.client = null;
    }
    slot.busy = false;
    this._wakeNext();
  }

  _wakeNext() {
    const next = this.waiters.shift();
    if (!next) return;
    const slot = this.slots.find((s) => !s.busy);
    if (slot) next(slot);
    else this.waiters.unshift(next); // shouldn't happen — safety net
  }

  /**
   * Runs `fn(client)` against a pooled, already-authenticated connection.
   * On a connection-level failure the dead connection is discarded and the
   * call is retried once on a freshly connected one. A real FTP result
   * (e.g. 550 file not found) is thrown straight through, untouched.
   */
  async run(fn, { retries = 1 } = {}) {
    let lastErr;
    for (let attempt = 0; attempt <= retries; attempt++) {
      const slot = await this._acquire();
      try {
        const result = await fn(slot.client);
        this._release(slot);
        return result;
      } catch (err) {
        lastErr = err;
        const connIssue = isConnectionError(err);
        this._release(slot, { discard: connIssue });
        if (!connIssue) throw err;
      }
    }
    throw lastErr;
  }

  /** Closes every pooled connection. Call on process shutdown. */
  async closeAll() {
    for (const slot of this.slots) {
      if (slot.client) {
        try {
          slot.client.close();
        } catch {
          /* ignore */
        }
        slot.client = null;
      }
    }
  }
}
