// Export helpers for the Books database view.
// xlsx via SheetJS (CDN-loaded on demand), HTML + PDF via blob/print.
import { toDMY, money } from "./config";

// load a script once
function loadScript(src) {
  return new Promise((res, rej) => {
    if (document.querySelector(`script[src="${src}"]`)) return res();
    const s = document.createElement("script"); s.src = src; s.onload = res; s.onerror = rej; document.head.appendChild(s);
  });
}

function fmtCell(v, kind) {
  if (v == null) return "";
  if (kind === "date") return toDMY(v);
  if (kind === "money" || kind === "num") return money(v);
  if (kind === "bool") return v ? "Yes" : "No";
  return String(v);
}

// rows: array of objects; cols: [{key,label,kind}]
export async function exportXLSX(filename, cols, rows) {
  // Try the styled build (jsDelivr) for header fills/fonts; fall back to plain SheetJS.
  let styled = true;
  try {
    await loadScript("https://cdn.jsdelivr.net/npm/xlsx-js-style@1.2.0/dist/xlsx.bundle.js");
    if (!window.XLSX) throw new Error("no XLSX");
  } catch (e) {
    styled = false;
    await loadScript("https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js");
  }
  const XLSX = window.XLSX;

  const INR_FMT = '#,##,##0.00';   // Indian grouping, 2 decimals
  const thin = (rgb) => { const s = { style: "thin", color: { rgb } }; return { top: s, bottom: s, left: s, right: s }; };
  const headerStyle = {
    font: { bold: true, color: { rgb: "FFFFFF" }, sz: 10 },
    fill: { fgColor: { rgb: "1C1C1C" } },
    alignment: { horizontal: "center", vertical: "center", wrapText: true },
    border: thin("999999"),
  };
  const cellBorder = thin("DDDDDD");

  const hasSubs = rows.some(r => r && r.__sub);
  const aoa = [cols.map(c => c.label)];
  rows.forEach(r => aoa.push(cols.map(c => {
    const v = r[c.key];
    if (c.kind === "date") return toDMY(v);
    if (c.kind === "money" || c.kind === "num") return v == null || v === "" ? "" : Number(v);
    if (c.kind === "bool") return v ? "Yes" : "No";
    return v ?? "";
  })));

  const ws = XLSX.utils.aoa_to_sheet(aoa);
  const range = XLSX.utils.decode_range(ws["!ref"]);
  for (let R = range.s.r; R <= range.e.r; R++) {
    for (let C = range.s.c; C <= range.e.c; C++) {
      const addr = XLSX.utils.encode_cell({ r: R, c: C });
      const cell = ws[addr]; if (!cell) continue;
      const kind = cols[C] ? cols[C].kind : "text";
      const isMoney = kind === "money" || kind === "num";
      if (isMoney && typeof cell.v === "number") { cell.t = "n"; cell.z = INR_FMT; }
      if (styled) {
        const isSub = R > 0 && rows[R-1] && rows[R-1].__sub;
        cell.s = R === 0 ? headerStyle : {
          font: { sz: 10, bold: hasSubs && !isSub },
          alignment: { horizontal: isMoney ? "right" : (kind === "date" ? "center" : "left"), vertical: "center" },
          border: cellBorder,
        };
      }
    }
  }

  ws["!cols"] = cols.map((c) => {
    let w = c.label.length;
    rows.forEach(r => { const v = r[c.key]; const s = v == null ? "" : (c.kind === "date" ? toDMY(v) : String(c.kind === "money" || c.kind === "num" ? money(v) : v)); if (s.length > w) w = s.length; });
    return { wch: Math.min(Math.max(w + 2, 10), 42) };
  });
  ws["!autofilter"] = { ref: ws["!ref"] };
  ws["!rows"] = [{ hpt: 26 }];

  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Data");
  XLSX.writeFile(wb, filename + ".xlsx");
}

function buildHTML(title, cols, rows) {
  const head = cols.map(c => `<th>${c.label}</th>`).join("");
  const body = rows.map(r => "<tr>" + cols.map(c => {
    const cls = (c.kind === "money" || c.kind === "num") ? ' class="num"' : "";
    return `<td${cls}>${fmtCell(r[c.key], c.kind)}</td>`;
  }).join("") + "</tr>").join("");
  return `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title>
<style>
  body{font-family:Inter,Arial,sans-serif;margin:24px;color:#1e2733}
  h1{font-size:18px;margin:0 0 4px} .meta{color:#7b8696;font-size:12px;margin-bottom:16px}
  table{border-collapse:collapse;width:100%;font-size:12px}
  th{background:#2b3643;color:#fff;text-align:left;padding:8px 10px;font-size:10px;text-transform:uppercase;letter-spacing:.4px}
  td{padding:7px 10px;border-bottom:1px solid #e3e8f0}
  tr:nth-child(even) td{background:#f4f6f8}
  td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
</style></head><body>
<h1>${title}</h1><div class="meta">${rows.length} rows · generated ${new Date().toLocaleString("en-GB")}</div>
<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>
</body></html>`;
}

export function exportHTML(filename, title, cols, rows) {
  const html = buildHTML(title, cols, rows);
  const blob = new Blob([html], { type: "text/html" });
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = filename + ".html"; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

// PDF via the browser's print dialog on a clean popup (user picks "Save as PDF")
export function exportPDF(title, cols, rows) {
  const html = buildHTML(title, cols, rows);
  const w = window.open("", "_blank");
  if (!w) { alert("Popup blocked — allow popups to export PDF."); return; }
  w.document.write(html + "<script>window.onload=function(){window.print();}<\/script>");
  w.document.close();
}
