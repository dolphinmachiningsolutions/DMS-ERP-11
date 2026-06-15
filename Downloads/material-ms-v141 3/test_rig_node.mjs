#!/usr/bin/env node
/* =====================================================================
   DMS ERP — NODE TEST RUNNER
   Exercises the SAME Supabase RPCs the web app calls, end to end, and
   prints a maximum-detail PASS/FAIL report with a category breakdown
   and a final engine health / reconcile audit.

   RUN ON A SCRATCH SUPABASE PROJECT ONLY. It writes test rows and does
   not clean up, so never point it at a project with real data.

   Usage:
     SUPABASE_URL=... SUPABASE_ANON_KEY=... node test_rig_node.mjs
   (If env vars are omitted it falls back to the values in src/lib/config.js.)
   Requires: npm i @supabase/supabase-js
   ===================================================================== */
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";

// ---- resolve credentials (env first, else read from config.js) ----
function fromConfig(key) {
  try {
    const t = readFileSync(new URL("./src/lib/config.js", import.meta.url), "utf8");
    const m = t.match(new RegExp(key + '\\s*[:=]\\s*"([^"]+)"'));
    return m ? m[1] : null;
  } catch { return null; }
}
const URL_ = process.env.SUPABASE_URL || fromConfig("url") || fromConfig("SUPABASE_URL");
const KEY_ = process.env.SUPABASE_ANON_KEY || fromConfig("anonKey") || fromConfig("key");
if (!URL_ || !KEY_) { console.error("Missing SUPABASE_URL / SUPABASE_ANON_KEY (env or config.js)."); process.exit(2); }

const db = createClient(URL_, KEY_, { auth: { persistSession: false } });

// ---- tiny assertion framework ----
const R = [];
let CAT = "";
const cat = (c) => { CAT = c; };
function check(name, pass, expected, actual) {
  R.push({ cat: CAT, name, pass: !!pass, expected: String(expected), actual: String(actual) });
}
async function rpc(fn, args) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
async function stock(part, bucket) { return Number(await rpc("check_stock", { p_part: part, p_bucket: bucket })); }
// expect a call to THROW (a guardrail). returns the error message or null if it wrongly succeeded.
async function expectBlocked(fn, args) {
  try { await rpc(fn, args); return null; } catch (e) { return e.message; }
}

const today = new Date().toISOString().slice(0, 10);
const uniq = Date.now().toString().slice(-6);   // keep voucher numbers unique per run

async function main() {
  let venRm, venRm2, venJw, cust, pMain, pTwo, poNo, dcNo, soNo;

  // ---------------- SETUP ----------------
  cat("SETUP");
  try {
    venRm  = await rpc("admin_save_ledger", { p_id: null, p_type: "Vendor RM", p_name: "NODE RM A " + uniq, p_gst: null, p_email: null, p_tax: "Local", p_status: "Active" });
    venRm2 = await rpc("admin_save_ledger", { p_id: null, p_type: "Vendor RM", p_name: "NODE RM B " + uniq, p_gst: null, p_email: null, p_tax: "Local", p_status: "Active" });
    venJw  = await rpc("admin_save_ledger", { p_id: null, p_type: "Vendor JW", p_name: "NODE JW " + uniq, p_gst: null, p_email: null, p_tax: "Local", p_status: "Active" });
    cust   = await rpc("admin_save_ledger", { p_id: null, p_type: "Customer", p_name: "NODE CUST " + uniq, p_gst: null, p_email: null, p_tax: "Local", p_status: "Active" });
    pMain  = await rpc("admin_save_part", { p_id: null, p_name: "NODE MAIN " + uniq, p_number: "NM" + uniq, p_uom: "Nos", p_group: null, p_status: "Active" });
    pTwo   = await rpc("admin_save_part", { p_id: null, p_name: "NODE TWO " + uniq, p_number: "NT" + uniq, p_uom: "Nos", p_group: null, p_status: "Active" });
    await rpc("save_part_price", { p_id: null, p_part: pMain, p_ledger: venRm,  p_type: "purchase", p_price: 100, p_from: today, p_upto: "2027-12-31", p_inw: 1.2, p_outw: 1.0, p_allow: 5, p_qvar: 2 });
    await rpc("save_part_price", { p_id: null, p_part: pMain, p_ledger: venRm2, p_type: "purchase", p_price: 110, p_from: today, p_upto: "2027-12-31", p_inw: 1.4, p_outw: 1.2, p_allow: 7, p_qvar: 4 });
    await rpc("save_part_price", { p_id: null, p_part: pMain, p_ledger: cust,   p_type: "sale",     p_price: 250, p_from: today, p_upto: "2027-12-31", p_inw: 0, p_outw: 0, p_allow: 0, p_qvar: 0 });
    check("master data created", venRm && venJw && cust && pMain, "all non-null", "ok");
  } catch (e) { check("master data created", false, "no error", e.message); }

  // ---------------- FY & NUMBERING ----------------
  cat("FY & NUMBERING");
  try {
    check("fy_compact(Jun-2026)=2627", (await rpc("fy_compact", { p_date: "2026-06-15" })) === "2627", "2627", await rpc("fy_compact", { p_date: "2026-06-15" }));
    check("fy_dashed(Jun-2026)=26-27", (await rpc("fy_dashed", { p_date: "2026-06-15" })) === "26-27", "26-27", await rpc("fy_dashed", { p_date: "2026-06-15" }));
    check("DCJW Apr -> 01", (await rpc("next_dcjw_no", { p_date: "2026-04-05" })).startsWith("DCJ262701"), "DCJ262701..", await rpc("next_dcjw_no", { p_date: "2026-04-05" }));
    check("DCJW Jun -> 03", (await rpc("next_dcjw_no", { p_date: "2026-06-05" })).startsWith("DCJ262703"), "DCJ262703..", await rpc("next_dcjw_no", { p_date: "2026-06-05" }));
    check("DCJW Mar -> 12", (await rpc("next_dcjw_no", { p_date: "2027-03-05" })).startsWith("DCJ262712"), "DCJ262712..", await rpc("next_dcjw_no", { p_date: "2027-03-05" }));
    check("rcjw_no format", (await rpc("rcjw_no", { p_serial: "42", p_date: "2026-06-05" })) === "CST/00042/26-27", "CST/00042/26-27", await rpc("rcjw_no", { p_serial: "42", p_date: "2026-06-05" }));
    check("PO valid_thru 5th", (await rpc("valid_thru_5th", { p_date: "2026-06-20" })) === "2026-07-05", "2026-07-05", await rpc("valid_thru_5th", { p_date: "2026-06-20" }));
    check("SO valid_thru eom", (await rpc("valid_thru_eom", { p_date: "2026-06-10" })) === "2026-06-30", "2026-06-30", await rpc("valid_thru_eom", { p_date: "2026-06-10" }));
    check("DC due +3", (await rpc("due_date_3d", { p_date: "2026-06-10" })) === "2026-06-13", "2026-06-13", await rpc("due_date_3d", { p_date: "2026-06-10" }));
  } catch (e) { check("FY/numbering block", false, "no error", e.message); }

  // ---------------- WEIGHT PROFILE ----------------
  cat("WEIGHT PROFILE");
  try {
    const wp = (await rpc("avg_weight_profile", { p_part: pMain }))[0];
    check("avg input (1.2,1.4)->1.3", Math.abs(wp.input_weight_pc - 1.3) < 1e-6, "1.30", wp.input_weight_pc);
    check("avg output (1.0,1.2)->1.1", Math.abs(wp.output_weight_pc - 1.1) < 1e-6, "1.10", wp.output_weight_pc);
    check("avg allowance (5,7)->6", Math.abs(wp.allowance_pct - 6) < 1e-6, "6.00", wp.allowance_pct);
    check("avg qty var (2,4)->3", Math.abs(wp.qty_variation - 3) < 1e-6, "3.00", wp.qty_variation);
  } catch (e) { check("weight profile block", false, "no error", e.message); }

  // ---------------- STOCK FLOW (via post_voucher / post_production) ----------------
  cat("STOCK FLOW");
  try {
    poNo = "NODE-PO-" + uniq;
    await rpc("post_voucher", { p_type: "PURCHASE_ORDER", p_idcode: "PO", p_no: poNo, p_date: today, p_posting: today, p_valid: await rpc("valid_thru_5th", { p_date: today }), p_ledger: venRm, p_ref_voucher: null, p_ref_no: null, p_tax: 18, p_narration: "po", p_user: "node", p_lines: [{ part_id: pMain, qty: 1000, unit_price: 100, basic_value: 100000 }] });
    check("PO no stock", (await stock(pMain, "RC")) === 0, "RC=0", await stock(pMain, "RC"));

    await rpc("post_voucher", { p_type: "PURCHASE", p_idcode: "PUR", p_no: "NODE-PUR-" + uniq, p_date: today, p_posting: today, p_valid: null, p_ledger: venRm, p_ref_voucher: null, p_ref_no: poNo, p_tax: 18, p_narration: "pur", p_user: "node", p_lines: [{ part_id: pMain, ref_no: poNo, invoice_qty: 900, actual_qty: 900, qty: 900, unit_price: 100, po_price: 100, basic_value: 90000 }] });
    check("Purchase 900 -> RC=900", (await stock(pMain, "RC")) === 900, "900", await stock(pMain, "RC"));

    dcNo = await rpc("next_dcjw_no", { p_date: today });
    await rpc("post_voucher", { p_type: "DC_OUT_JW", p_idcode: "DCO", p_no: dcNo, p_date: today, p_posting: today, p_valid: await rpc("due_date_3d", { p_date: today }), p_ledger: venJw, p_ref_voucher: null, p_ref_no: null, p_tax: 18, p_narration: "dc", p_user: "node", p_lines: [{ part_id: pMain, qty: 400 }] });
    check("DC Out 400 -> RC=500/RCJW=400", (await stock(pMain, "RC")) === 500 && (await stock(pMain, "RCJW")) === 400, "500/400", (await stock(pMain, "RC")) + "/" + (await stock(pMain, "RCJW")));

    await rpc("post_voucher", { p_type: "RC_IN_JW", p_idcode: "RCI", p_no: await rpc("rcjw_no", { p_serial: uniq.slice(-4), p_date: today }), p_date: today, p_posting: today, p_valid: null, p_ledger: venJw, p_ref_voucher: null, p_ref_no: dcNo, p_tax: 18, p_narration: "rcin", p_user: "node", p_lines: [{ part_id: pMain, ref_no: dcNo, invoice_qty: 250, actual_qty: 250, qty: 250 }] });
    check("RC In 250 -> RCJW=150/CC=250", (await stock(pMain, "RCJW")) === 150 && (await stock(pMain, "CC")) === 250, "150/250", (await stock(pMain, "RCJW")) + "/" + (await stock(pMain, "CC")));

    await rpc("post_production", { p_date: today, p_shift: "Day", p_sup1: "Node Supervisor", p_sup2: null, p_user: "node", p_rows: [{ section: "NODE", machine_no: "M1", part_id: pMain, op10_actual: 200 }], p_downtime: [], p_quality: [] });
    check("Production 200 -> CC=50/MG=200", (await stock(pMain, "CC")) === 50 && (await stock(pMain, "MG")) === 200, "50/200", (await stock(pMain, "CC")) + "/" + (await stock(pMain, "MG")));

    soNo = "NODE-SO-" + uniq;
    await rpc("post_voucher", { p_type: "SALES_ORDER", p_idcode: "SO", p_no: soNo, p_date: today, p_posting: today, p_valid: await rpc("valid_thru_eom", { p_date: today }), p_ledger: cust, p_ref_voucher: null, p_ref_no: null, p_tax: 18, p_narration: "so", p_user: "node", p_lines: [{ part_id: pMain, qty: 120, unit_price: 250, basic_value: 30000 }] });
    await rpc("post_voucher", { p_type: "SALES_LOCAL", p_idcode: "SAL", p_no: "NODE-SAL-" + uniq, p_date: today, p_posting: today, p_valid: null, p_ledger: cust, p_ref_voucher: null, p_ref_no: soNo, p_tax: 18, p_narration: "sal", p_user: "node", p_lines: [{ part_id: pMain, ref_no: soNo, qty: 120, unit_price: 250, basic_value: 30000 }] });
    check("Sales 120 -> MG=80", (await stock(pMain, "MG")) === 80, "80", await stock(pMain, "MG"));
  } catch (e) { check("stock flow block", false, "no error", e.message); }

  // ---------------- GUARDRAILS ----------------
  cat("GUARDRAILS");
  {
    const m1 = await expectBlocked("post_voucher", { p_type: "DC_OUT_JW", p_idcode: "DCO", p_no: "NODE-DCBLOCK-" + uniq, p_date: today, p_posting: today, p_valid: await rpc("due_date_3d", { p_date: today }), p_ledger: venJw, p_ref_voucher: null, p_ref_no: null, p_tax: 18, p_narration: "x", p_user: "node", p_lines: [{ part_id: pMain, qty: 999999 }] });
    check("DC beyond RC blocked", m1 !== null, "blocked", m1 || "SUCCEEDED (hole!)");
    await rpc("set_voucher_enabled", { p_type: "PURCHASE", p_on: false });
    const m2 = await expectBlocked("post_voucher", { p_type: "PURCHASE", p_idcode: "PUR", p_no: "NODE-DIS-" + uniq, p_date: today, p_posting: today, p_valid: null, p_ledger: venRm, p_ref_voucher: null, p_ref_no: poNo, p_tax: 18, p_narration: "x", p_user: "node", p_lines: [{ part_id: pMain, ref_no: poNo, invoice_qty: 1, actual_qty: 1, qty: 1, unit_price: 100, po_price: 100, basic_value: 100 }] });
    check("disabled voucher blocked", m2 !== null, "blocked", m2 || "SUCCEEDED (hole!)");
    await rpc("set_voucher_enabled", { p_type: "PURCHASE", p_on: true });
  }

  // ---------------- PRICE PENDING ----------------
  cat("PRICE PENDING");
  try {
    const before = await stock(pMain, "RC");
    const pend = await rpc("post_voucher", { p_type: "PURCHASE", p_idcode: "PUR", p_no: "NODE-PP-" + uniq, p_date: today, p_posting: today, p_valid: null, p_ledger: venRm, p_ref_voucher: null, p_ref_no: poNo, p_tax: 18, p_narration: "pp", p_user: "node", p_lines: [{ part_id: pMain, ref_no: poNo, invoice_qty: 50, actual_qty: 50, qty: 50, unit_price: 95, po_price: 100, basic_value: 4750 }], p_price_pending: true });
    const vid = pend?.id;
    check("price-pending no stock", (await stock(pMain, "RC")) === before, "RC unchanged " + before, await stock(pMain, "RC"));
    const q = await rpc("price_pending_full", {});
    check("appears in approval queue", q.some(x => x.id === vid), "present", q.length + " pending");
    await rpc("approve_price_post", { p_id: vid, p_user: "node" });
    check("approve posts +50", (await stock(pMain, "RC")) === before + 50, String(before + 50), await stock(pMain, "RC"));
  } catch (e) { check("price pending block", false, "no error", e.message); }

  // ---------------- LEDGERS ----------------
  cat("LEDGERS");
  try {
    const pl = await rpc("part_ledger_full", { p_part: pMain, p_bucket: "RC", p_from: null, p_to: null });
    check("part ledger opening row first", pl[0]?.voucher_type === "OPENING BALANCE", "OPENING BALANCE", pl[0]?.voucher_type);
    check("part ledger has movements", pl.length > 1, ">1 row", pl.length);
    const sl = await rpc("stock_ledger_full", { p_part: pMain, p_bucket: null, p_vtype: null, p_from: null, p_to: null });
    check("stock ledger journal non-empty", sl.length > 0, ">0", sl.length);
  } catch (e) { check("ledgers block", false, "no error", e.message); }

  // ---------------- HEALTH AUDIT ----------------
  cat("HEALTH AUDIT");
  try {
    const h = await rpc("engine_health", {});
    for (const row of h) check("engine_health: " + row.check_name, row.status === "OK", "OK", row.status);
    const rec = await rpc("reconcile_stock", {});
    check("reconcile: zero drift", (rec?.length || 0) === 0, "0", (rec?.length || 0) + " drift rows");
  } catch (e) { check("health block", false, "no error", e.message); }

  report();
}

function report() {
  const pad = (s, n) => String(s).padEnd(n).slice(0, n);
  console.log("\n================ DMS ERP — NODE TEST REPORT ================\n");
  console.log("---- DETAIL ----");
  console.log(pad("CATEGORY", 16), pad("TEST", 42), "RESULT");
  let seq = 0;
  for (const r of R) console.log(pad(r.cat, 16), pad(r.name, 42), r.pass ? "PASS" : "FAIL", r.pass ? "" : ` | exp:${r.expected} got:${r.actual}`);
  console.log("\n---- CATEGORY BREAKDOWN ----");
  const cats = [...new Set(R.map(r => r.cat))];
  for (const c of cats) { const rows = R.filter(r => r.cat === c); const p = rows.filter(r => r.pass).length; console.log(pad(c, 16), `${p}/${rows.length} passed`); }
  const fails = R.filter(r => !r.pass);
  if (fails.length) { console.log("\n---- FAILURES ----"); for (const r of fails) console.log(`  [${r.cat}] ${r.name}  exp:${r.expected}  got:${r.actual}`); }
  const passed = R.filter(r => r.pass).length;
  console.log("\n---- GRAND TOTAL ----");
  console.log(`  ${passed} / ${R.length} passed  (${(100 * passed / R.length).toFixed(1)}%)`);
  process.exit(fails.length ? 1 : 0);
}

main().catch(e => { console.error("FATAL:", e.message); process.exit(2); });
