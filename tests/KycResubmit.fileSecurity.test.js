// fileSecurity.js - what an anonymous supplier may upload through the KYC correction link (sql/155).
// The PDFs in fixtures/kyc-resubmit were written by a real PDF library (PyMuPDF): plain, with compressed object streams,
// with an embedded file, encrypted, and with a JavaScript action both in the open and hidden inside an object stream.
import { describe, it, expect, jest, beforeEach, afterEach } from "@jest/globals";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import {
  inspectUpload, inspectUploads, detectKind, safeBaseName, scanWithClamAv, FileRejected, MAX_FILE_BYTES,
} from "../src/KycResubmit/fileSecurity.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = (name) => fs.readFileSync(path.join(here, "fixtures", "kyc-resubmit", name));

// ── minimal but structurally valid pictures
const chunk = (type, data) => {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  return Buffer.concat([len, Buffer.from(type, "latin1"), data, Buffer.alloc(4)]);
};
const png = ({ w = 10, h = 10, trailing = Buffer.alloc(0), extra = Buffer.alloc(0) } = {}) => {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr),
    ...(extra.length ? [chunk("tEXt", extra)] : []),
    chunk("IDAT", zlib.deflateSync(Buffer.alloc(40))), chunk("IEND", Buffer.alloc(0)), trailing,
  ]);
};
const jpeg = ({ w = 10, h = 10 } = {}) =>
  Buffer.concat([
    Buffer.from([0xff, 0xd8]),
    Buffer.from([0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]),
    Buffer.from([0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]),
    Buffer.from([0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00, 0x12, 0x34, 0x56]),
    Buffer.from([0xff, 0xd9]),
  ]);
const webp = ({ w = 10, h = 10 } = {}) => {
  const b = Buffer.alloc(30);
  b.write("RIFF", 0, "latin1");
  b.writeUInt32LE(22, 4);
  b.write("WEBPVP8X", 8, "latin1");
  b.writeUInt32LE(10, 16);
  b.writeUIntLE(w - 1, 24, 3);
  b.writeUIntLE(h - 1, 27, 3);
  return b;
};
const pdf = (body = "") =>
  Buffer.from(`%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R ${body} >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n`, "latin1");
const objStm = (inside, { deflate = true, dictExtra = "" } = {}) => {
  const data = deflate ? zlib.deflateSync(Buffer.from(inside, "latin1")) : Buffer.from(inside, "latin1");
  return Buffer.concat([
    Buffer.from(`%PDF-1.5\n5 0 obj\n<< /Type /ObjStm /N 1 /First 4 ${deflate ? "/Filter /FlateDecode" : ""} ${dictExtra} /Length ${data.length} >>\nstream\n`, "latin1"),
    data,
    Buffer.from("\nendstream\nendobj\ntrailer\n<< >>\n%%EOF\n", "latin1"),
  ]);
};

const upload = (buffer, originalname, mimetype, fieldname = "pan_file") => ({ fieldname, originalname, mimetype, size: buffer.length, buffer });
const pdfFile = (buffer, name = "pan.pdf") => upload(buffer, name, "application/pdf");
const rejected = async (promise, pattern) => {
  const err = await promise.then(() => null, (e) => e);
  expect(err).toBeInstanceOf(FileRejected);
  expect(err.userFacing).toBe(true);
  if (pattern) expect(err.message).toMatch(pattern);
  return err;
};

beforeEach(() => {
  delete process.env.CLAMAV_HOST;
  jest.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  delete process.env.CLAMAV_HOST;
  jest.restoreAllMocks();
});

describe("what is accepted", () => {
  it("accepts a plain PDF and one with compressed object streams (real files)", async () => {
    expect((await inspectUpload(pdfFile(fixture("plain.pdf")))).kind).toBe("pdf");
    expect((await inspectUpload(pdfFile(fixture("objstm.pdf")))).kind).toBe("pdf");
  });

  it("accepts PNG, JPEG and WEBP pictures", async () => {
    expect((await inspectUpload(upload(png(), "scan.png", "image/png"))).kind).toBe("png");
    expect((await inspectUpload(upload(jpeg(), "photo.jpeg", "image/jpeg"))).kind).toBe("jpeg");
    expect((await inspectUpload(upload(webp(), "photo.webp", "image/webp"))).kind).toBe("webp");
  });

  it("accepts a picture saved under another picture extension and stores it under its real type", async () => {
    const r = await inspectUpload(upload(jpeg(), "cheque.png", "image/png"));
    expect(r.kind).toBe("jpeg");
    expect(r.originalname).toBe("cheque.jpg");
    expect(r.mimetype).toBe("image/jpeg");
  });

  it("accepts a PNG whose metadata carries a drawing as <svg> markup (design tools do this)", async () => {
    const r = await inspectUpload(upload(png({ extra: Buffer.from('Source\0<svg width="716" height="716"></svg>') }), "logo.png", "image/png"));
    expect(r.kind).toBe("png");
  });

  it("returns a sha256 and the real size", async () => {
    const buf = png();
    const r = await inspectUpload(upload(buf, "a.png", "image/png"));
    expect(r.sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(r.size).toBe(buf.length);
    expect(r.av).toBe("not configured");
  });
});

describe("what is refused - wrong kind of file", () => {
  it("refuses extensions that are not PDF / picture, whatever the content", async () => {
    for (const name of ["run.exe", "page.html", "drawing.svg", "script.js", "macro.docm", "sheet.xlsx", "arch.zip", "shell.php", "noextension", "x.pdf.exe"]) {
      await rejected(inspectUpload(upload(fixture("plain.pdf"), name, "application/pdf")), /not allowed. Only PDF, PNG, JPG or WEBP/);
    }
  });

  it("refuses a Windows program renamed .pdf or .png", async () => {
    const exe = Buffer.concat([Buffer.from("MZ"), Buffer.alloc(200, 1)]);
    await rejected(inspectUpload(pdfFile(exe, "invoice.pdf")), /not a real PDF file/);
    await rejected(inspectUpload(upload(exe, "scan.png", "image/png")), /not a real PNG file/);
  });

  it("refuses an HTML page or an SVG drawing renamed to .png / .pdf", async () => {
    await rejected(inspectUpload(upload(Buffer.from("<html><script>alert(1)</script></html>"), "a.png", "image/png")), /not a real PNG/);
    await rejected(inspectUpload(pdfFile(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>'), "a.pdf")), /not a real PDF/);
  });

  it("refuses a picture posing as a PDF and a PDF posing as a picture", async () => {
    await rejected(inspectUpload(pdfFile(png(), "x.pdf")), /not a real PDF/);
    await rejected(inspectUpload(upload(fixture("plain.pdf"), "x.png", "image/png")), /not a real PNG/);
  });

  it("refuses a declared type that does not fit", async () => {
    await rejected(inspectUpload(upload(png(), "a.png", "text/html")), /does not match/);
    await rejected(inspectUpload(upload(png(), "a.png", "application/octet-stream")), /does not match/);
    await rejected(inspectUpload(upload(png(), "a.png", "")), /does not match/);
  });

  it("refuses unknown form fields, empty and oversized files", async () => {
    await rejected(inspectUpload(upload(png(), "a.png", "image/png", "shell")), /document we do not accept/);
    await rejected(inspectUpload(upload(Buffer.alloc(0), "a.png", "image/png")), /empty/);
    const big = Buffer.concat([fixture("plain.pdf"), Buffer.alloc(MAX_FILE_BYTES)]);
    await rejected(inspectUpload(pdfFile(big)), /larger than 5 MB/);
  });

  it("refuses prototype-style field names", async () => {
    await rejected(inspectUpload(upload(png(), "a.png", "image/png", "__proto__")), /document we do not accept/);
    await rejected(inspectUpload(upload(png(), "a.png", "image/png", "constructor")), /document we do not accept/);
  });
});

describe("what is refused - pictures", () => {
  it("refuses data after the end of a PNG, a damaged PNG and a PNG that is a decompression bomb", async () => {
    await rejected(inspectUpload(upload(png({ trailing: Buffer.from("<?php system($_GET[0]); ?>") }), "a.png", "image/png")), /extra data/);
    await rejected(inspectUpload(upload(png().subarray(0, 60), "a.png", "image/png")), /damaged|not a valid/);
    await rejected(inspectUpload(upload(png({ w: 60000, h: 60000 }), "a.png", "image/png")), /too large as a picture/);
  });

  it("refuses oversized JPEG / WEBP pictures and a cut-off JPEG", async () => {
    await rejected(inspectUpload(upload(jpeg({ w: 30000, h: 30000 }), "a.jpg", "image/jpeg")), /too large as a picture/);
    await rejected(inspectUpload(upload(webp({ w: 30000, h: 30000 }), "a.webp", "image/webp")), /too large as a picture/);
    await rejected(inspectUpload(upload(jpeg().subarray(0, jpeg().length - 2), "a.jpg", "image/jpeg")), /damaged|not a valid/);
  });

  it("refuses script or web-page text hidden inside a picture", async () => {
    for (const payload of ["<script>alert(1)</script>", "<?php system($_GET['c']); ?>", "<html><body>", "<iframe src=x>", "JavaScript:alert(1)"]) {
      await rejected(inspectUpload(upload(png({ extra: Buffer.from(`Comment\0${payload}`) }), "a.png", "image/png")), /hidden script/);
      const jpg = jpeg();
      const withComment = Buffer.concat([jpg.subarray(0, 2), Buffer.from([0xff, 0xfe, 0x00, 2 + payload.length]), Buffer.from(payload), jpg.subarray(2)]);
      await rejected(inspectUpload(upload(withComment, "a.jpg", "image/jpeg")), /hidden script/);
    }
  });
});

describe("what is refused - PDFs with active content", () => {
  it.each([
    ["JavaScript action (real file)", () => fixture("js_plain.pdf")],
    ["JavaScript hidden in a compressed object stream (real file)", () => fixture("js_objstm.pdf")],
    ["embedded file (real file)", () => fixture("embedded.pdf")],
    ["encrypted (real file)", () => fixture("encrypted.pdf")],
    ["/JavaScript", () => pdf("/OpenAction << /S /JavaScript /JS (app.alert(1)) >>")],
    ["name written with #xx escapes", () => pdf("/OpenAction << /S /Java#53cript /J#53 (app.alert(1)) >>")],
    ["/JS by reference", () => pdf("/AA << /O << /S /Foo /JS 7 0 R >> >>")],
    ["/Launch", () => pdf("/OpenAction << /S /Launch /F (cmd.exe) >>")],
    ["/EmbeddedFiles", () => pdf("/Names << /EmbeddedFiles 4 0 R >>")],
    ["/RichMedia", () => pdf("/Annots [ << /Subtype /RichMedia >> ]")],
    ["/SubmitForm", () => pdf("/A << /S /SubmitForm /F (http://evil) >>")],
    ["/GoToR", () => pdf("/A << /S /GoToR /F (\\\\evil\\share) >>")],
    ["/XFA", () => pdf("/AcroForm << /XFA 9 0 R >>")],
    ["3D annotation", () => pdf("/Annots [ << /Subtype /3D >> ]")],
    ["/Encrypt", () => pdf("/Encrypt 8 0 R")],
    ["JS inside a deflated object stream", () => objStm("7 0 << /S /JavaScript /JS (x) >>")],
    ["JS inside an object stream with no filter", () => objStm("7 0 << /S /Launch /F (x) >>", { deflate: false })],
  ])("refuses a PDF with %s", async (_label, make) => {
    await rejected(inspectUpload(pdfFile(make())), /active content|encrypted/);
  });

  it("refuses PDFs it cannot look inside: other filters, predictors, damaged or hidden object streams", async () => {
    await rejected(inspectUpload(pdfFile(objStm("7 0 << >>", { dictExtra: "/Filter /ASCIIHexDecode" }))), /could not be checked safely/);
    await rejected(inspectUpload(pdfFile(objStm("7 0 << >>", { dictExtra: "/DecodeParms << /Predictor 12 >>" }))), /could not be checked safely/);
    const garbled = Buffer.from(objStm("7 0 << >>").toString("latin1").replace("\nendstream", "\nendstrXam"), "latin1");
    await rejected(inspectUpload(pdfFile(garbled)), /could not be checked safely|damaged/);
    // an object stream whose dictionary contains the word "endstream" so a naive search skips it: the count check catches it
    const sneaky = Buffer.from(
      "%PDF-1.5\n5 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Z /endstream /Length 5 >>\nstream\nXXXXX\nendstream\nendobj\n6 0 obj\n<< /Type /ObjStm /Foo >>\nstream\nendstream\ntrailer\n<< >>\n%%EOF\n", "latin1");
    const result = await inspectUpload(pdfFile(sneaky)).then(() => "accepted", (e) => e.message);
    expect(result).toMatch(/could not be checked safely|active content/);
  });

  it("refuses a truncated PDF", async () => {
    await rejected(inspectUpload(pdfFile(fixture("plain.pdf").subarray(0, 300))), /damaged or incomplete/);
  });

  it("does not refuse a big scan just because random picture data resembles a keyword", async () => {
    // 2 MB of pseudo-random bytes in a picture stream, with keyword-like fragments scattered through it:
    // "/JS ", "/3D" and "/XFA/" are not followed by a value, so they are not the real thing
    const noise = Buffer.alloc(2 * 1024 * 1024);
    for (let i = 0; i < noise.length; i += 1) noise[i] = (i * 2654435761) >>> 24;
    for (let i = 0; i < noise.length - 32; i += 4096) noise.write("/JS /3D /XFA/Sound", i, "latin1");
    const file = Buffer.concat([
      Buffer.from("%PDF-1.4\n1 0 obj\n<< /Type /XObject /Subtype /Image /Length 1 >>\nstream\n", "latin1"),
      noise,
      Buffer.from("\nendstream\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n", "latin1"),
    ]);
    const err = await inspectUpload(pdfFile(file)).then(() => null, (e) => e);
    // "/Sound" is followed by a byte that is not a name delimiter in this noise: only that real shape counts
    expect(err === null || /active content/.test(err.message)).toBe(true);
    if (err) expect(err.message).not.toMatch(/JS|3D|XFA/);
  });
});

describe("file names", () => {
  it("rebuilds the stored name: no path, no dots, the real extension", () => {
    expect(safeBaseName("../../etc/passwd.php.pdf")).toBe("passwd_php");
    expect(safeBaseName("C:\\Users\\x\\PAN card (1).PDF")).toBe("PAN card (1)");
    expect(safeBaseName("a.b.c.png")).toBe("a_b_c");
    expect(safeBaseName("..")).toBe("document");
    expect(safeBaseName("")).toBe("document");
    expect(safeBaseName("name\0with\nbad\tchars.pdf")).toBe("name_with_bad_chars");
    expect(safeBaseName(`${"x".repeat(300)}.pdf`).length).toBe(60);
    expect(safeBaseName("<script>.png")).toBe("_script_");
  });

  it("stores 'invoice.php.pdf' as 'invoice_php.pdf'", async () => {
    const r = await inspectUpload(pdfFile(fixture("plain.pdf"), "invoice.php.pdf"));
    expect(r.originalname).toBe("invoice_php.pdf");
  });

  it("detects types from the first bytes only", () => {
    expect(detectKind(fixture("plain.pdf"))).toBe("pdf");
    expect(detectKind(png())).toBe("png");
    expect(detectKind(jpeg())).toBe("jpeg");
    expect(detectKind(webp())).toBe("webp");
    expect(detectKind(Buffer.from("GIF89a"))).toBeNull();
    expect(detectKind(Buffer.from("PK\u0003\u0004"))).toBeNull();
    expect(detectKind(Buffer.alloc(0))).toBeNull();
  });
});

describe("a whole upload", () => {
  it("allows one file per document type and several 'other' documents, at most 6 files", async () => {
    const ok = await inspectUploads([
      pdfFile(fixture("plain.pdf")), upload(png(), "gst.png", "image/png", "gst_file"),
      upload(jpeg(), "o1.jpg", "image/jpeg", "other_file"), upload(jpeg(), "o2.jpg", "image/jpeg", "other_file"),
    ]);
    expect(ok).toHaveLength(4);
    await rejected(inspectUploads([pdfFile(fixture("plain.pdf")), pdfFile(fixture("objstm.pdf"), "again.pdf")]), /only one PAN card/i);
    const seven = Array.from({ length: 7 }, (_, i) => upload(png(), `o${i}.png`, "image/png", "other_file"));
    await rejected(inspectUploads(seven), /at most 6 files/);
  });

  it("refuses the whole upload when one file is bad", async () => {
    await rejected(inspectUploads([pdfFile(fixture("plain.pdf")), upload(Buffer.from("MZ......"), "x.png", "image/png", "gst_file")]), /not a real PNG/);
    await expect(inspectUploads(undefined)).resolves.toEqual([]);
  });
});

describe("ClamAV (only when CLAMAV_HOST is set)", () => {
  it("passes a file the scanner calls clean and records it", async () => {
    process.env.CLAMAV_HOST = "clam.local";
    const scanner = jest.fn().mockResolvedValue({ clean: true });
    const r = await inspectUpload(pdfFile(fixture("plain.pdf")), { scanner });
    expect(r.av).toBe("clean");
    expect(scanner).toHaveBeenCalledWith(expect.any(Buffer), { host: "clam.local", port: 3310 });
  });

  it("refuses an infected file and does not echo the signature name", async () => {
    process.env.CLAMAV_HOST = "clam.local";
    const err = await rejected(inspectUpload(pdfFile(fixture("plain.pdf")), { scanner: async () => ({ clean: false, signature: "Eicar-Test-Signature" }) }), /blocked by the virus scanner/);
    expect(err.message).not.toMatch(/Eicar/);
  });

  it("refuses everything (fail closed, 503) when the scanner is configured but unreachable", async () => {
    process.env.CLAMAV_HOST = "clam.local";
    const err = await rejected(inspectUpload(pdfFile(fixture("plain.pdf")), { scanner: async () => { throw new Error("ECONNREFUSED"); } }), /cannot be security-checked right now/);
    expect(err.status).toBe(503);
  });

  it("speaks the clamd INSTREAM protocol", async () => {
    const seen = [];
    const server = net.createServer((socket) => {
      let buf = Buffer.alloc(0);
      socket.on("data", (d) => {
        buf = Buffer.concat([buf, d]);
        if (!buf.includes(Buffer.from("zINSTREAM\0"))) return;
        let o = "zINSTREAM\0".length;
        const parts = [];
        while (buf.length >= o + 4) {
          const n = buf.readUInt32BE(o);
          if (n === 0) {
            seen.push(Buffer.concat(parts));
            socket.end(Buffer.concat(parts).includes("EICAR") ? "stream: Eicar-Test-Signature FOUND\0" : "stream: OK\0");
            return;
          }
          if (buf.length < o + 4 + n) return;
          parts.push(buf.subarray(o + 4, o + 4 + n));
          o += 4 + n;
        }
      });
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const { port } = server.address();
    try {
      const clean = Buffer.alloc(200_000, 7);
      expect(await scanWithClamAv(clean, { host: "127.0.0.1", port })).toEqual({ clean: true });
      expect(seen[0].equals(clean)).toBe(true);
      expect(await scanWithClamAv(Buffer.from("EICAR-STANDARD"), { host: "127.0.0.1", port })).toEqual({ clean: false, signature: "Eicar-Test-Signature" });
    } finally {
      server.close();
    }
    await expect(scanWithClamAv(Buffer.from("x"), { host: "127.0.0.1", port: 1, timeoutMs: 500 })).rejects.toThrow();
  });
});
