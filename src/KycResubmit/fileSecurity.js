/**
 * Checks for files an UNAUTHENTICATED supplier uploads through the KYC correction link (sql/155).
 *
 * Nothing here trusts the browser: the file name, the extension and the declared MIME type are only hints, the bytes decide.
 * A file is accepted only when ALL of these hold, and is refused (never "cleaned") otherwise:
 *   1. extension is one of pdf / png / jpg / jpeg / webp, and the first bytes really are that type (magic number)
 *   2. the MIME type the browser declared matches that type
 *   3. size is 1 byte to 5 MB
 *   4. images: structure parses (PNG chunks, JPEG segments, WebP RIFF), the picture size is sane (no 60000x60000 "bomb"),
 *      and no script / HTML / PHP text is hidden inside
 *   5. PDFs: no JavaScript, launch actions, embedded files, rich media, forms that submit, or encryption - including
 *      inside compressed object streams and names written with #xx escapes (/Java#53cript)
 *   6. if CLAMAV_HOST is set, ClamAV says the file is clean; if it is set but cannot be reached the file is REFUSED
 * The stored name is rebuilt: a safe base name + the extension of the DETECTED type, so "invoice.php.pdf" or "a.exe.png"
 * can never be stored under a double extension.
 *
 * This is not a replacement for antivirus: it removes the ways a document upload is normally abused, and ClamAV (above) adds
 * signature scanning when the server has it.
 */
import crypto from "node:crypto";
import net from "node:net";
import path from "node:path";
import zlib from "node:zlib";

export const MAX_FILE_BYTES = 5 * 1024 * 1024;
export const MAX_FILES = 6;
const MAX_SIDE = 20_000;
const MAX_PIXELS = 100_000_000;
const MAX_OBJSTM = 200;
const MAX_INFLATE_PER_STREAM = 10 * 1024 * 1024;
const MAX_INFLATE_TOTAL = 40 * 1024 * 1024;

/** document_type values stored in kyc_document_info (the same names the onboarding form uses). */
export const RESUBMIT_DOCUMENT_FIELDS = {
  pan_file: "PAN card",
  gst_file: "GST certificate",
  msme_file: "MSME / Udyam certificate",
  bankCancelCheque_0: "Cancelled cheque / bank letter",
  other_file: "Other document",
};

const KINDS = {
  pdf: { ext: ".pdf", mime: "application/pdf", declared: ["application/pdf"] },
  png: { ext: ".png", mime: "image/png", declared: ["image/png"] },
  jpeg: { ext: ".jpg", mime: "image/jpeg", declared: ["image/jpeg", "image/jpg", "image/pjpeg"] },
  webp: { ext: ".webp", mime: "image/webp", declared: ["image/webp"] },
};
const EXTENSIONS = { ".pdf": "pdf", ".png": "png", ".jpg": "jpeg", ".jpeg": "jpeg", ".webp": "webp" };
export const ALLOWED_EXTENSIONS_TEXT = "PDF, PNG, JPG or WEBP";

/** An error whose message is written for the supplier. */
export class FileRejected extends Error {
  constructor(message, status = 422) {
    super(message);
    this.name = "FileRejected";
    this.userFacing = true;
    this.status = status;
  }
}

/** A name that is safe to show back to the supplier in a message. */
const shown = (name) => `"${String(name ?? "file").replace(/[^\w .()-]/g, "?").slice(0, 60)}"`;

/** Base name only: no path, no dots, no odd characters, never empty. The extension is added from the detected type. */
export function safeBaseName(original) {
  const base = path.basename(String(original ?? "").replace(/\\/g, "/"));
  const withoutExt = base.replace(/\.[^.]*$/, "");
  const clean = withoutExt.normalize("NFKC").replace(/[^A-Za-z0-9 _()-]+/g, "_").replace(/\s+/g, " ").trim().slice(0, 60);
  return /[A-Za-z0-9]/.test(clean) ? clean : "document";
}

export function extensionKind(originalName) {
  return EXTENSIONS[path.extname(String(originalName ?? "")).toLowerCase()] ?? null;
}

/** What the first bytes say the file is. */
export function detectKind(buf) {
  if (buf.length >= 5 && buf.toString("latin1", 0, 5) === "%PDF-") return "pdf";
  if (buf.length >= 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "png";
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "jpeg";
  if (buf.length >= 12 && buf.toString("latin1", 0, 4) === "RIFF" && buf.toString("latin1", 8, 12) === "WEBP") return "webp";
  return null;
}

// ───────────────────────── images

function checkDimensions(name, width, height) {
  if (!(width > 0 && height > 0)) throw new FileRejected(`${shown(name)} is not a valid picture.`);
  if (width > MAX_SIDE || height > MAX_SIDE || width * height > MAX_PIXELS) {
    throw new FileRejected(`${shown(name)} is too large as a picture (${width} x ${height} pixels). Upload a smaller scan or photo.`);
  }
}

function checkPng(name, buf) {
  if (buf.length < 33 || buf.readUInt32BE(8) !== 13 || buf.toString("latin1", 12, 16) !== "IHDR") {
    throw new FileRejected(`${shown(name)} is not a valid PNG picture.`);
  }
  checkDimensions(name, buf.readUInt32BE(16), buf.readUInt32BE(20));
  let offset = 8;
  while (offset + 12 <= buf.length) {
    const length = buf.readUInt32BE(offset);
    const type = buf.toString("latin1", offset + 4, offset + 8);
    if (length > buf.length) break;
    offset += 12 + length;
    if (type === "IEND") {
      if (offset !== buf.length) throw new FileRejected(`${shown(name)} has extra data after the picture, so it was not accepted.`);
      return;
    }
  }
  throw new FileRejected(`${shown(name)} is damaged or incomplete (PNG).`);
}

function checkJpeg(name, buf) {
  let offset = 2;
  while (offset + 4 <= buf.length) {
    if (buf[offset] !== 0xff) break;
    const marker = buf[offset + 1];
    if (marker === 0xff) { offset += 1; continue; } // fill byte
    if (marker === 0xda) break; // start of scan: a size segment must have come first
    const isSize = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSize) {
      if (offset + 9 > buf.length) break;
      checkDimensions(name, buf.readUInt16BE(offset + 7), buf.readUInt16BE(offset + 5));
      if (!buf.includes(Buffer.from([0xff, 0xd9]))) throw new FileRejected(`${shown(name)} is damaged or incomplete (JPG).`);
      return;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) { offset += 2; continue; } // markers without a length
    offset += 2 + buf.readUInt16BE(offset + 2);
  }
  throw new FileRejected(`${shown(name)} is not a valid JPG picture.`);
}

function checkWebp(name, buf) {
  const riffEnd = buf.readUInt32LE(4) + 8;
  if (riffEnd > buf.length || buf.length - riffEnd > 1) throw new FileRejected(`${shown(name)} is damaged or has extra data (WEBP).`);
  const chunk = buf.toString("latin1", 12, 16);
  if (chunk === "VP8X" && buf.length >= 30) checkDimensions(name, 1 + buf.readUIntLE(24, 3), 1 + buf.readUIntLE(27, 3));
  else if (chunk === "VP8 " && buf.length >= 30) checkDimensions(name, buf.readUInt16LE(26) & 0x3fff, buf.readUInt16LE(28) & 0x3fff);
  else if (chunk === "VP8L" && buf.length >= 25) {
    const bits = buf.readUInt32LE(21);
    checkDimensions(name, (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
  } else throw new FileRejected(`${shown(name)} is not a valid WEBP picture.`);
}

// Only signatures long enough that they cannot turn up by chance in compressed pixels (a 2-byte "<%" does, every few hundred KB),
// and not "<svg": design tools legitimately keep their source drawing inside a PNG's metadata.
const SCRIPT_SIGNATURES = ["<script", "<?php", "<html", "<iframe", "javascript:", "vbscript:"];

/** A picture is binary: readable script / web-page text inside it is a smuggled payload (a "polyglot"), never a picture. */
function checkNoHiddenMarkup(name, buf) {
  const text = buf.toString("latin1").toLowerCase();
  if (SCRIPT_SIGNATURES.some((s) => text.includes(s))) {
    throw new FileRejected(`${shown(name)} contains hidden script or web-page content, so it was not accepted.`);
  }
}

// ───────────────────────── PDF

/**
 * What makes a PDF do something (run code, open programs or files, send data) or stops us from looking inside. The whole file
 * is searched, including compressed picture data, so short names are only matched in the shape they have in a real PDF
 * (/JS followed by its value, /XFA followed by its value, /Subtype /3D): a bare "/JS" could otherwise turn up by chance in a
 * big scan and reject a good file.
 */
const NAME_END = "(?=[\\s/<>\\[\\]()%{}]|$)";
const PDF_FORBIDDEN_RE = new RegExp(
  `/(JavaScript|Launch|EmbeddedFiles?|RichMedia|SubmitForm|ImportData|GoToR|GoToE|Movie|Sound|Rendition|Encrypt)${NAME_END}` +
    "|/JS\\s*(?:[(<]|\\d+\\s+\\d+\\s+R)" +
    "|/XFA\\s*[\\[<\\d]" +
    `|/Subtype\\s*/3D${NAME_END}`,
);

/** /Java#53cript is the same name as /JavaScript: undo the #xx escapes before looking. */
const unescapeNames = (s) => s.replace(/#([0-9a-fA-F]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));

function assertPdfClean(name, text) {
  const hit = PDF_FORBIDDEN_RE.exec(unescapeNames(text));
  if (!hit) return;
  const what = hit[1] === "Encrypt" ? "is password-protected or encrypted" : "contains scripts, embedded files or other active content";
  throw new FileRejected(`${shown(name)} ${what}, so it was not accepted. Save or print it again as a plain PDF, or upload a photo of the document.`);
}

function checkPdf(name, buf) {
  const text = buf.toString("latin1");
  if (!text.slice(-2048).includes("%%EOF")) throw new FileRejected(`${shown(name)} is damaged or incomplete (PDF).`);
  assertPdfClean(name, text);

  // Objects can hide inside compressed "object streams": open each one and look at what is inside.
  const cannotCheck = () => new FileRejected(`${shown(name)} could not be checked safely (PDF), so it was not accepted. Save or print it again as a plain PDF, or upload a photo of the document.`);
  const ObjStmName = /\/Type\s*\/ObjStm/;
  const streamRe = />>\s*stream(?:\r\n|\n|\r)/g;
  let scanned = 0;
  let inflated = 0;
  for (let m = streamRe.exec(text); m; m = streamRe.exec(text)) {
    // the dictionary of this stream: back to the previous stream's end, at most 4 KB
    const from = Math.max(text.lastIndexOf("endstream", m.index), m.index - 4096, 0);
    const dict = unescapeNames(text.slice(from, m.index + 2));
    if (!ObjStmName.test(dict)) continue;
    scanned += 1;
    if (scanned > MAX_OBJSTM) throw new FileRejected(`${shown(name)} is too complex to check, so it was not accepted.`);
    const dataStart = m.index + m[0].length;
    const dataEnd = text.indexOf("endstream", dataStart);
    if (dataEnd < 0) throw cannotCheck();
    let raw = buf.subarray(dataStart, dataEnd);
    const filters = dict.match(/\/Filter\s*(\[[^\]]*\]|\/\w+)/g)?.pop()?.replace(/^\/Filter\s*/, "") ?? "";
    // a predictor scrambles the bytes we would be looking at, so such a stream cannot be read either
    if (/\/DecodeParms|\/DP\b/.test(dict)) throw cannotCheck();
    let inner;
    if (!filters) inner = raw.toString("latin1");
    else if (/^\[?\s*\/(FlateDecode|Fl)\s*\]?$/.test(filters.trim())) {
      try {
        while (raw.length && (raw[raw.length - 1] === 0x0a || raw[raw.length - 1] === 0x0d)) raw = raw.subarray(0, -1);
        inner = zlib.inflateSync(raw, { maxOutputLength: MAX_INFLATE_PER_STREAM }).toString("latin1");
      } catch {
        throw cannotCheck();
      }
    } else {
      throw cannotCheck();
    }
    inflated += inner.length;
    if (inflated > MAX_INFLATE_TOTAL) throw new FileRejected(`${shown(name)} is too complex to check, so it was not accepted.`);
    assertPdfClean(name, inner);
  }
  // Safety net: every object stream named in the file must have been opened above. If the file hides one from the search
  // (for example by putting the word "endstream" inside its dictionary) the counts differ and the file is refused.
  const named = (unescapeNames(text).match(/\/Type\s*\/ObjStm/g) ?? []).length;
  if (named !== scanned) throw cannotCheck();
}

// ───────────────────────── ClamAV (optional)

/** Streams the bytes to clamd (INSTREAM). Resolves { clean, signature }. Rejects when the scanner cannot be used. */
export function scanWithClamAv(buf, { host, port = 3310, timeoutMs = 20_000 } = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port });
    let reply = "";
    const fail = (err) => { socket.destroy(); reject(err); };
    socket.setTimeout(timeoutMs, () => fail(new Error("ClamAV timed out")));
    socket.on("error", fail);
    socket.on("data", (d) => { reply += d.toString("utf8"); });
    socket.on("close", () => {
      const text = reply.replace(/\0/g, "").trim();
      if (/\bOK$/.test(text)) return resolve({ clean: true });
      const found = /:\s*(.+?)\s+FOUND$/.exec(text);
      if (found) return resolve({ clean: false, signature: found[1] });
      reject(new Error(`ClamAV said: ${text || "nothing"}`));
    });
    socket.on("connect", () => {
      socket.write("zINSTREAM\0");
      for (let i = 0; i < buf.length; i += 64 * 1024) {
        const chunk = buf.subarray(i, i + 64 * 1024);
        const size = Buffer.alloc(4);
        size.writeUInt32BE(chunk.length);
        socket.write(size);
        socket.write(chunk);
      }
      socket.write(Buffer.alloc(4));
    });
  });
}

const clamConfig = () => (process.env.CLAMAV_HOST ? { host: process.env.CLAMAV_HOST, port: Number(process.env.CLAMAV_PORT) || 3310 } : null);

// ───────────────────────── the entry point

/**
 * @param file  one multer memory-storage file
 * @param opts  { allowedFields, scanner } - allowedFields: object whose keys are the accepted field names; scanner: test hook
 * @returns the file as it should be stored: { fieldname, buffer, originalname, mimetype, size, kind, sha256, av }
 */
export async function inspectUpload(file, { allowedFields = RESUBMIT_DOCUMENT_FIELDS, scanner = scanWithClamAv } = {}) {
  const name = file?.originalname;
  if (!file || !Buffer.isBuffer(file.buffer)) throw new FileRejected("The upload could not be read. Try again.");
  if (!Object.hasOwn(allowedFields, file.fieldname)) throw new FileRejected(`${shown(name)} was sent for a document we do not accept.`);
  if (file.size === 0 || file.buffer.length === 0) throw new FileRejected(`${shown(name)} is empty.`);
  if (file.buffer.length > MAX_FILE_BYTES) throw new FileRejected(`${shown(name)} is larger than ${MAX_FILE_BYTES / 1024 / 1024} MB.`);

  const byExtension = extensionKind(name);
  if (!byExtension) throw new FileRejected(`${shown(name)} is not allowed. Only ${ALLOWED_EXTENSIONS_TEXT} files can be uploaded.`);
  const detected = detectKind(file.buffer);
  // The bytes decide. A picture saved under another picture extension (a JPEG named .png happens) is still a picture and is
  // stored under its true type; a PDF that is not a PDF, or a picture posing as a PDF (or the other way round), is refused.
  if (!detected || (detected === "pdf") !== (byExtension === "pdf")) {
    throw new FileRejected(`${shown(name)} is not a real ${byExtension.toUpperCase()} file (its content is different), so it was not accepted.`);
  }
  const declared = String(file.mimetype ?? "").toLowerCase().split(";")[0].trim();
  if (!KINDS[detected].declared.includes(declared) && !KINDS[byExtension].declared.includes(declared)) {
    throw new FileRejected(`${shown(name)} was sent as "${declared || "unknown"}", which does not match a ${detected.toUpperCase()} file.`);
  }

  if (detected === "pdf") checkPdf(name, file.buffer);
  else {
    if (detected === "png") checkPng(name, file.buffer);
    else if (detected === "jpeg") checkJpeg(name, file.buffer);
    else checkWebp(name, file.buffer);
    checkNoHiddenMarkup(name, file.buffer);
  }

  let av = "not configured";
  const clam = clamConfig();
  if (clam) {
    let result;
    try {
      result = await scanner(file.buffer, clam);
    } catch (err) {
      console.error("[kyc-resubmit] ClamAV unavailable:", err.message);
      throw new FileRejected("Files cannot be security-checked right now. Please try again in a few minutes.", 503);
    }
    if (!result.clean) throw new FileRejected(`${shown(name)} was blocked by the virus scanner and was not accepted.`);
    av = "clean";
  }

  return {
    fieldname: file.fieldname,
    buffer: file.buffer,
    originalname: `${safeBaseName(name)}${KINDS[detected].ext}`,
    mimetype: KINDS[detected].mime,
    size: file.buffer.length,
    kind: detected,
    sha256: crypto.createHash("sha256").update(file.buffer).digest("hex"),
    av,
  };
}

/** Checks the whole upload: how many, one per document type (except "other"), then each file. Nothing is uploaded here. */
export async function inspectUploads(files, options) {
  const list = Array.isArray(files) ? files : [];
  if (list.length > MAX_FILES) throw new FileRejected(`You can upload at most ${MAX_FILES} files at a time.`);
  const seen = new Set();
  for (const f of list) {
    if (f.fieldname !== "other_file" && seen.has(f.fieldname)) {
      throw new FileRejected(`Upload only one ${RESUBMIT_DOCUMENT_FIELDS[f.fieldname] ?? "file"} at a time.`);
    }
    seen.add(f.fieldname);
  }
  const checked = [];
  for (const f of list) checked.push(await inspectUpload(f, options));
  return checked;
}
