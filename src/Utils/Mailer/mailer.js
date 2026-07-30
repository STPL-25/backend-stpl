/**
 * SMTP mailer for supplier-portal invite emails, sent automatically when a
 * KYC record reaches final approval and its supplier code is generated.
 *
 * Dev-bypass convention: without SMTP_HOST/USER/PASS configured, sendMail()
 * logs the message to the console instead of throwing, so the approval flow
 * keeps working before real credentials exist.
 */
import nodemailer from "nodemailer";
import { configDotenv } from "dotenv";
configDotenv();

const SMTP_HOST = process.env.SMTP_HOST;
const SMTP_PORT = parseInt(process.env.SMTP_PORT || "587");
const SMTP_USER = process.env.SMTP_USER;
const SMTP_PASS = process.env.SMTP_PASS;
const SMTP_FROM = process.env.SMTP_FROM || SMTP_USER;

const isConfigured = Boolean(SMTP_HOST && SMTP_USER && SMTP_PASS);

const transporter = isConfigured
  ? nodemailer.createTransport({
      host: SMTP_HOST,
      port: SMTP_PORT,
      secure: SMTP_PORT === 465,
      auth: { user: SMTP_USER, pass: SMTP_PASS },
    })
  : null;

/** @param {{ to: string, subject: string, text: string, html?: string }} message */
async function sendMail(message) {
  if (!isConfigured) {
    console.log(`[mailer] SMTP not configured — logging message instead of sending:\n`, message);
    return { sent: false, reason: "SMTP not configured" };
  }

  await transporter.sendMail({ from: SMTP_FROM, ...message });
  return { sent: true };
}

/** Escape values interpolated into the HTML email body. */
function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => {
    switch (ch) {
      case "&": return "&amp;";
      case "<": return "&lt;";
      case ">": return "&gt;";
      case '"': return "&quot;";
      default: return "&#39;";
    }
  });
}

function buildSupplierInviteEmail({ to, companyName, suppCode, tempPassword, portalUrl }) {
  const text =
    `Hello ${companyName},\n\n` +
    `Your KYC has been approved and your supplier portal access is ready.\n\n` +
    `Login URL: ${portalUrl}\n` +
    `Login ID: ${suppCode}\n` +
    `Temporary password: ${tempPassword}\n\n` +
    `You'll be asked to set a new password on first login.\n\n` +
    `For your security, do not share these credentials with anyone.`;

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Supplier portal access</title>
</head>
<body style="margin:0; padding:0; background-color:#f4f5f7; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f5f7; padding:24px 0;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px; background-color:#ffffff; border-radius:12px; overflow:hidden; box-shadow:0 1px 3px rgba(0,0,0,0.08);">
          <tr>
            <td style="background-color:#0f172a; padding:28px 32px;">
              <h1 style="margin:0; color:#ffffff; font-size:20px; font-weight:600; letter-spacing:0.2px;">Supplier Portal Access</h1>
            </td>
          </tr>
          <tr>
            <td style="padding:32px;">
              <p style="margin:0 0 16px; color:#0f172a; font-size:16px;">Hello ${esc(companyName)},</p>
              <p style="margin:0 0 24px; color:#475569; font-size:15px; line-height:1.6;">
                Your KYC has been approved and your access to the supplier portal is now ready. Use the credentials below to sign in.
              </p>
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f8fafc; border:1px solid #e2e8f0; border-radius:8px; margin-bottom:24px;">
                <tr>
                  <td style="padding:16px 20px; border-bottom:1px solid #e2e8f0;">
                    <div style="color:#64748b; font-size:12px; text-transform:uppercase; letter-spacing:0.5px; margin-bottom:4px;">Login ID</div>
                    <div style="color:#0f172a; font-size:16px; font-weight:600; font-family:'Courier New',monospace;">${esc(suppCode)}</div>
                  </td>
                </tr>
                <tr>
                  <td style="padding:16px 20px;">
                    <div style="color:#64748b; font-size:12px; text-transform:uppercase; letter-spacing:0.5px; margin-bottom:4px;">Temporary Password</div>
                    <div style="color:#0f172a; font-size:16px; font-weight:600; font-family:'Courier New',monospace;">${esc(tempPassword)}</div>
                  </td>
                </tr>
              </table>
              <table role="presentation" cellpadding="0" cellspacing="0" style="margin-bottom:24px;">
                <tr>
                  <td style="border-radius:8px; background-color:#2563eb;">
                    <a href="${esc(portalUrl)}" target="_blank" style="display:inline-block; padding:12px 28px; color:#ffffff; font-size:15px; font-weight:600; text-decoration:none; border-radius:8px;">Go to Supplier Portal</a>
                  </td>
                </tr>
              </table>
              <p style="margin:0 0 8px; color:#475569; font-size:14px; line-height:1.6;">
                You'll be asked to set a new password on first login.
              </p>
              <p style="margin:0; color:#94a3b8; font-size:13px; line-height:1.6;">
                For your security, do not share these credentials with anyone.
              </p>
            </td>
          </tr>
          <tr>
            <td style="padding:20px 32px; background-color:#f8fafc; border-top:1px solid #e2e8f0;">
              <p style="margin:0; color:#94a3b8; font-size:12px; line-height:1.5;">
                This is an automated message. If you did not expect this email, please contact our procurement team.
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;

  return {
    to,
    subject: "Your supplier portal access",
    text,
    html,
  };
}

function buildPOGeneratedEmail({ to, companyName, poNo, poDate, requiredDate, items, totalAmount, termsConditions, deliveryAddress, portalUrl }) {
  const itemLines = items
    .map((it) => `  - ${it.prod_name} | Qty: ${it.qty} ${it.unit_name || ""} | Rate: ${it.unit_price} | Amount: ${it.total_amount}`)
    .join("\n");

  const text =
    `Hello ${companyName},\n\n` +
    `A new Purchase Order has been generated for you.\n\n` +
    `PO Number: ${poNo}\n` +
    `PO Date: ${poDate}\n` +
    `Required By: ${requiredDate}\n\n` +
   
    (deliveryAddress ? `\nDelivery Address: ${deliveryAddress}\n` : "") +
    (termsConditions ? `\nTerms & Conditions: ${termsConditions}\n` : "") +
    `\nThe full PO is attached as a PDF. Log in to the supplier portal to view it online: ${portalUrl}\n`;



  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Purchase Order ${esc(poNo)}</title>
</head>
<body style="margin:0; padding:0; background-color:#eef1f6; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#eef1f6; padding:32px 0;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px; background-color:#ffffff; border-radius:14px; overflow:hidden; box-shadow:0 4px 16px rgba(15,23,42,0.08);">
          <tr>
            <td style="background:linear-gradient(135deg,#0f172a 0%,#1e3a8a 100%); padding:32px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
                <tr>
                  <td>
                    <span style="display:inline-block; background-color:rgba(255,255,255,0.12); color:#93c5fd; font-size:11px; font-weight:700; text-transform:uppercase; letter-spacing:0.8px; padding:5px 10px; border-radius:999px; margin-bottom:12px;">New Purchase Order</span>
                    <h1 style="margin:6px 0 4px; color:#ffffff; font-size:22px; font-weight:700; letter-spacing:0.2px;">${esc(poNo)}</h1>
                    <p style="margin:0; color:#cbd5e1; font-size:13px;">Issued ${esc(poDate)}</p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding:32px;">
              <p style="margin:0 0 16px; color:#0f172a; font-size:16px;">Hello ${esc(companyName)},</p>
              <p style="margin:0 0 24px; color:#475569; font-size:15px; line-height:1.6;">
                A new purchase order has been generated for you. Please review the details below and the attached PDF, and fulfil the order by the required date.
              </p>

              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:24px;">
                <tr>
                  <td width="50%" style="padding:16px 18px; background-color:#f8fafc; border:1px solid #e2e8f0; border-radius:10px 0 0 10px; border-right:none;">
                    <div style="color:#64748b; font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:0.5px; margin-bottom:6px;">Required By</div>
                    <div style="color:#0f172a; font-size:17px; font-weight:700;">${esc(requiredDate)}</div>
                  </td>
                  <td width="50%" style="padding:16px 18px; background-color:#eff6ff; border:1px solid #bfdbfe; border-radius:0 10px 10px 0;">
                    <div style="color:#1d4ed8; font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:0.5px; margin-bottom:6px;">Total Amount</div>
                    <div style="color:#1e3a8a; font-size:17px; font-weight:700;">${esc(totalAmount)}</div>
                  </td>
                </tr>
              </table>

           
              ${
                deliveryAddress || termsConditions
                  ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:24px;">
                <tr>
                  ${
                    deliveryAddress
                      ? `<td valign="top" width="${termsConditions ? "50%" : "100%"}" style="padding:16px 18px; background-color:#f8fafc; border:1px solid #e2e8f0; border-radius:10px;${termsConditions ? " margin-right:12px;" : ""}">
                    <div style="color:#64748b; font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:0.5px; margin-bottom:6px;">Delivery Address</div>
                    <div style="color:#334155; font-size:14px; line-height:1.5;">${esc(deliveryAddress)}</div>
                  </td>${termsConditions ? `<td width="12"></td>` : ""}`
                      : ""
                  }
                  ${
                    termsConditions
                      ? `<td valign="top" width="${deliveryAddress ? "50%" : "100%"}" style="padding:16px 18px; background-color:#f8fafc; border:1px solid #e2e8f0; border-radius:10px;">
                    <div style="color:#64748b; font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:0.5px; margin-bottom:6px;">Terms & Conditions</div>
                    <div style="color:#334155; font-size:14px; line-height:1.5;">${esc(termsConditions)}</div>
                  </td>`
                      : ""
                  }
                </tr>
              </table>`
                  : ""
              }

              <p style="margin:0 0 20px; color:#64748b; font-size:13px; line-height:1.6;">
                The full purchase order is attached as a PDF to this email.
              </p>

              <table role="presentation" cellpadding="0" cellspacing="0">
                <tr>
                  <td style="border-radius:8px; background-color:#2563eb;">
                    <a href="${esc(portalUrl)}" target="_blank" style="display:inline-block; padding:13px 30px; color:#ffffff; font-size:15px; font-weight:600; text-decoration:none; border-radius:8px;">View in Supplier Portal</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding:20px 32px; background-color:#f8fafc; border-top:1px solid #e2e8f0;">
              <p style="margin:0; color:#94a3b8; font-size:12px; line-height:1.5;">
                This is an automated message. If you did not expect this email, please contact our procurement team.
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;

  return {
    to,
    subject: `Purchase Order ${poNo} generated`,
    text,
    html,
  };
}

export { sendMail, buildSupplierInviteEmail, buildPOGeneratedEmail, isConfigured as isMailerConfigured };
