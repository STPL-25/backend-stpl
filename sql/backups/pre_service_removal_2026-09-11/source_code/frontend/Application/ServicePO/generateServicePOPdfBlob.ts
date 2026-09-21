import { jsPDF } from 'jspdf';
import { autoTable } from 'jspdf-autotable';

// Mirrors PurchaseOrder/PurchaseTeam/generatePOPdfBlob.ts's layout/style —
// same visual language, adapted to Service PO's fields (service_name/
// agreed_unit_price/net_cost instead of prod_name/unit_price/total_amount,
// no PR/quotation object — just the already-fetched pending-approval record).

export interface ServicePOItem {
  service_name?: string;
  specification?: string;
  qty: number;
  unit_name?: string;
  agreed_unit_price: number;
  discount_pct?: number;
  tax_pct?: number;
  net_cost?: number;
}

export interface ServicePOPdfInput {
  po_no: string;
  vendor_name?: string;
  po_type?: string;
  pr_no?: string;
  purpose?: string;
  validity_from?: string;
  validity_to?: string;
  terms_conditions?: string;
  delivery_address?: string;
  items: ServicePOItem[];
}

const formatDate = (d?: string) => {
  if (!d) return '—';
  try {
    return new Date(d).toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
  } catch { return d; }
};

const formatINR = (n: number) =>
  new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 }).format(n || 0);

export function buildServicePOPdfBlob({
  po_no, vendor_name, po_type, pr_no, purpose, validity_from, validity_to,
  terms_conditions, delivery_address, items,
}: ServicePOPdfInput): { doc: jsPDF; fileName: string } {
  const safeItems = Array.isArray(items) ? items : [];
  const grandTotal = safeItems.reduce(
    (sum, it) => sum + Number(it.net_cost ?? it.qty * it.agreed_unit_price),
    0
  );

  const doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: 'a4', compress: true });
  doc.setProperties({ title: `Service Purchase Order - ${po_no}`, subject: 'Service Purchase Order', creator: 'Non-Trade Purchase Order System' });

  doc.setFont('helvetica', 'bold');
  doc.setFontSize(16);
  doc.setTextColor(79, 70, 229);
  doc.text('SERVICE PURCHASE ORDER', 14, 18);

  doc.setFont('helvetica', 'normal');
  doc.setFontSize(10);
  doc.setTextColor(30, 30, 30);
  doc.text(`PO Number: ${po_no}`, 14, 26);
  doc.text(`Date: ${formatDate(new Date().toISOString())}`, 14, 32);

  doc.setFont('helvetica', 'bold');
  doc.text('Vendor', 14, 42);
  doc.setFont('helvetica', 'normal');
  doc.text(vendor_name || '-', 14, 48);

  doc.setFont('helvetica', 'bold');
  doc.text('PO Type', 110, 42);
  doc.setFont('helvetica', 'normal');
  doc.text(po_type || '-', 110, 48);

  doc.setFont('helvetica', 'bold');
  doc.text('Source PR', 14, 58);
  doc.setFont('helvetica', 'normal');
  doc.text(pr_no || '—', 14, 64);

  doc.setFont('helvetica', 'bold');
  doc.text('Validity', 110, 58);
  doc.setFont('helvetica', 'normal');
  doc.text(
    validity_from || validity_to ? `${formatDate(validity_from)} – ${formatDate(validity_to)}` : '—',
    110, 64
  );

  let headerY = 74;
  if (purpose) {
    doc.setFont('helvetica', 'bold');
    doc.text('Purpose', 14, headerY);
    doc.setFont('helvetica', 'normal');
    const purposeLines = doc.splitTextToSize(purpose, 180) as string[];
    doc.text(purposeLines, 14, headerY + 6);
    headerY += 6 + purposeLines.length * 4 + 4;
  }

  const rows = safeItems.map((item, idx) => [
    String(idx + 1),
    item.service_name || '-',
    String(item.qty),
    item.unit_name || '-',
    formatINR(item.agreed_unit_price),
    `${item.discount_pct ?? 0}%`,
    `${item.tax_pct ?? 0}%`,
    formatINR(Number(item.net_cost ?? item.qty * item.agreed_unit_price)),
  ]);

  autoTable(doc, {
    startY: headerY,
    head: [['#', 'Service', 'Qty', 'Unit', 'Rate', 'Disc%', 'Tax%', 'Amount']],
    body: rows,
    theme: 'grid',
    styles: { font: 'helvetica', fontSize: 8, cellPadding: 2 },
    headStyles: { fillColor: [79, 70, 229], textColor: 255, fontStyle: 'bold' },
    columnStyles: {
      0: { cellWidth: 8, halign: 'center' },
      2: { halign: 'right' },
      4: { halign: 'right' },
      5: { halign: 'right' },
      6: { halign: 'right' },
      7: { halign: 'right' },
    },
  });

  const tableDoc = doc as jsPDF & { lastAutoTable?: { finalY: number } };
  let y = (tableDoc.lastAutoTable?.finalY ?? headerY) + 8;

  const totalsX = 130;
  doc.setFillColor(79, 70, 229);
  doc.rect(totalsX - 2, y - 5, 68, 8, 'F');
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(9);
  doc.setTextColor(255, 255, 255);
  doc.text('Grand Total', totalsX, y);
  doc.text(formatINR(grandTotal), 196, y, { align: 'right' });
  doc.setTextColor(30, 30, 30);

  y += 16;
  if (terms_conditions) {
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(10);
    doc.text('Terms & Conditions', 14, y);
    y += 6;
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9);
    const termLines = doc.splitTextToSize(terms_conditions, 180) as string[];
    doc.text(termLines, 14, y);
    y += termLines.length * 4 + 6;
  }
  if (delivery_address) {
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(10);
    doc.text('Delivery Address', 14, y);
    y += 6;
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9);
    const addrLines = doc.splitTextToSize(delivery_address, 180) as string[];
    doc.text(addrLines, 14, y);
  }

  return { doc, fileName: `${po_no}.pdf` };
}
