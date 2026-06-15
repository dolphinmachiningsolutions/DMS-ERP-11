import React, { useState, useEffect } from "react";
import { supabase, VOUCHERS, todayISO, toDMY, money } from "../lib/config";
import { Field, Msg, StockChip } from "../ui/primitives";

const COLS = {
  part: { th: "Part", w: "auto" }, ref: { th: "Ref", w: 150 }, lot: { th: "Lot", w: 160 },
  source_bucket: { th: "Source Bucket", w: 140 },
  qty: { th: "Qty", w: 100, num: true, key: "qty" }, invoice_qty: { th: "Invoice Qty", w: 110, num: true, key: "invoice_qty" },
  actual_qty: { th: "Actual Qty", w: 110, num: true, key: "actual_qty" }, uom: { th: "UOM", w: 70 },
  unit_price: { th: "Unit Price", w: 110, num: true, key: "unit_price" }, po_price: { th: "PO Price", w: 100, num: true, key: "po_price", ro: true },
  basic_value: { th: "Basic Value", w: 120, num: true, calc: true }, weight: { th: "Weight (kg)", w: 110, num: true, calc: true },
  defect_type: { th: "Defect Type", w: 130 }, root_cause: { th: "Root Cause", w: 150 }, narration: { th: "Remarks", w: "auto" },
  lb_value: { th: "LB Value", w: 110, num: true },
  disposition: { th: "Disposition", w: 150 }, return_bucket: { th: "Return To", w: 130 },
  pkg_count: { th: "No. of Packages", w: 130, num: true },
};

export function VoucherForm({ type, user, editId, onDone }) {
  const def = VOUCHERS[type];
  const today = todayISO();
  const isEdit = !!editId;
  // spec date defaults: today-3 for Purchase, Sales, Scrap Sales, Purchase Return (MR), RC In (JW); today for the rest
  const MINUS3 = ["PURCHASE","SALES_LOCAL","SCRAP_SALES","DEBIT_NOTE_DN","RC_IN_JW"];
  const defaultVDate = MINUS3.includes(type) ? new Date(Date.now() - 3 * 86400000).toISOString().slice(0, 10) : today;
  const blankH = { idcode: "", no: "", cst_mid: "", date: defaultVDate, posting_date: today, valid_thru: "", ledger_id: "", ref_no: "", narration: "", location_id: "", free_ledger: "" };
  const [hdr, setHdr] = useState(blankH);
  const [locations, setLocations] = useState([]);
  useEffect(() => { (async () => {
    const { data } = await supabase.rpc("list_locations", { p_active_only: true });
    setLocations(data || []);
    // default to the default location if none chosen
    const def0 = (data || []).find(l => l.is_default) || (data || [])[0];
    if (def0) setHdr(h => h.location_id ? h : { ...h, location_id: def0.id });
  })(); }, []);
  const [rcSerial, setRcSerial] = useState("");  // RC In (JW): manual 5-digit serial
  const [ledgers, setLedgers] = useState([]); const [parts, setParts] = useState([]); const [refs, setRefs] = useState([]); const [lots, setLots] = useState({});
  const [supers, setSupers] = useState([]); const [defects, setDefects] = useState([]); const [dcAlloc, setDcAlloc] = useState([]);
  const newLine = () => ({ part_id: "", lot_id: "", ref_no: "", source_bucket: "", qty: "", invoice_qty: "", actual_qty: "", uom: "Nos", unit_price: "", po_price: "", defect_type: "", defect_other: "", root_cause: "", line_note: "", disposition: "RESALE", return_bucket: "", pkg_count: "", _lb: 0, _mwt: 0, _iwt: 0, _allow: 0, _qvar: 0, _owt: 0, _avail: null, _pend: null, _refs: [], packages: [], _pkgOpen: false, lot_alloc: [], _lotOpen: false, _lotAvail: [] });
  const newPkg = () => ({ token_ref: "", net_weight: "", qty: "" });
  const [lines, setLines] = useState([newLine()]); const [msg, setMsg] = useState(null); const [touched, setTouched] = useState(false);
  const set = (k, v) => setHdr(s => ({ ...s, [k]: v }));

  // valid-through / due-date calculator by scheme. Build the date string from
  // local Y/M/D parts (NOT toISOString, which shifts to UTC and drops a day in IST).
  const ymd = (dt) => `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}-${String(dt.getDate()).padStart(2, "0")}`;
  function calcValidThru(dateStr) {
    if (!dateStr) return "";
    const [y, m, day] = dateStr.split("-").map(Number);
    let vt = null;
    if (def.validThru === "5th") vt = new Date(y, m, 5);          // m is 1-based here -> month+1, day 5
    else if (def.validThru === "eom") vt = new Date(y, m, 0);     // day 0 of next month = last day of this month
    else if (def.validThru === "due3") vt = new Date(y, m - 1, day + 3);
    return vt ? ymd(vt) : "";
  }
  // recompute when the voucher date changes
  useEffect(() => { const vt = calcValidThru(hdr.date); if (vt && vt !== hdr.valid_thru) set("valid_thru", vt); }, [hdr.date, type]);

  // DC allocation (RC In JW): reload whenever ledger OR the chosen part changes,
  // regardless of which the user picks first.
  useEffect(() => {
    if (!def.dcAllocation || editId) return;
    const partId = lines[0]?.part_id;
    if (!hdr.ledger_id || !partId) { setDcAlloc([]); return; }
    (async () => {
      const { data } = await supabase.rpc("open_dcs_for", { p_ledger: hdr.ledger_id, p_part: partId });
      setDcAlloc((data || []).map(d => ({ ...d, allocate: "" })));
    })();
  }, [hdr.ledger_id, lines[0]?.part_id, type]);

  // Item 7: RC In (variant) — list open DC Out (Ret/Replacement) to receive against
  const [variantDcs, setVariantDcs] = useState([]);
  useEffect(() => {
    if (!def.dcAllocationVariant || editId) { return; }
    (async () => {
      const kind = type === "RC_IN_REPLACE" ? "replace" : "ret";
      const { data } = await supabase.rpc("open_variant_dcs", { p_kind: kind });
      setVariantDcs(data || []);
    })();
  }, [type]);

  // auto voucher number for scheme-based types
  useEffect(() => { if (editId) return;
    (async () => {
      if (def.numberScheme === "dcjw" && hdr.date) { const { data } = await supabase.rpc("next_dcjw_no", { p_date: hdr.date }); if (data) set("no", data); }
      else if (def.numberScheme === "rcjw") { set("no", `CST/${(hdr.cst_mid || "").trim()}/${fyDash(hdr.date)}`); }
    })();
  }, [hdr.date, hdr.cst_mid, type]);

  useEffect(() => { (async () => {
    if (editId) return;
    setMsg(null); setTouched(false); setLines([newLine()]);
    const { data: ic } = await supabase.rpc("next_voucher_idcode", { p_type: type });
    // compute the scheme-based voucher number up-front so the reset doesn't clobber it
    let schemeNo = "";
    if (def.numberScheme === "dcjw") { const { data } = await supabase.rpc("next_dcjw_no", { p_date: defaultVDate }); schemeNo = data || ""; }
    else if (def.numberScheme === "rcjw") { schemeNo = ""; }
    setHdr({ ...blankH, idcode: ic || "", no: schemeNo, valid_thru: calcValidThru(defaultVDate) }); setRcSerial("");
    if (def.ledger) { const { data } = await supabase.from("ledger").select("*").eq("ledger_type", def.ledger).eq("status", "Active").order("ledger_code"); setLedgers(data || []); } else setLedgers([]);
    // all-parts vouchers (DC Out JW, RC In JW, rejections) + sourceBucket variants list every active part
    if (def.allParts || !def.ledger || def.sourceBucket) { const { data } = await supabase.from("part").select("*").eq("status", "Active").order("part_code"); setParts(data || []); }
    if (def.defectDropdown) { const { data } = await supabase.rpc("list_defect_types"); setDefects(data || []); }
    if (def.ref && !def.refChained) { const view = (def.ref === "DC_OUT_JW") ? "open_dcs" : "open_orders";
      const { data } = await supabase.from(view).select("*").eq("voucher_type", def.ref);
      const byNo = {}; (data || []).forEach(r => { if (!byNo[r.voucher_no]) byNo[r.voucher_no] = { voucher_no: r.voucher_no, ledger_id: r.ledger_id, pending: 0 }; byNo[r.voucher_no].pending += +(r.pending_qty || 0); });
      setRefs(Object.values(byNo)); }
  })(); }, [type]);

  // chained parts by chosen ledger (Purchase=by vendor, Sales=by customer); else keep all-parts
  useEffect(() => { (async () => {
    if (def.allParts || def.sourceBucket) return;
    if (!def.ledger) return;
    if (!hdr.ledger_id) { setParts([]); return; }
    if (def.partsByVendor) { const { data } = await supabase.rpc("parts_for_vendor", { p_ledger: hdr.ledger_id }); setParts((data || []).map(r => ({ id: r.part_id, part_code: r.part_code, part_name: r.part_name }))); return; }
    if (def.partsByCustomer) { const { data } = await supabase.rpc("parts_for_customer", { p_ledger: hdr.ledger_id }); setParts((data || []).map(r => ({ id: r.part_id, part_code: r.part_code, part_name: r.part_name }))); return; }
    const ptype = def.priceType || (def.ledger === "Customer" ? "sale" : "purchase");
    const { data } = await supabase.from("part_price").select("part_id, part(*)").eq("ledger_id", hdr.ledger_id).eq("price_type", ptype);
    const uniq = {}; (data || []).forEach(r => { if (r.part) uniq[r.part.id] = r.part; });
    setParts(Object.values(uniq).sort((a, b) => a.part_code.localeCompare(b.part_code)));
  })(); }, [hdr.ledger_id, type]);

  // load existing voucher when editing
  useEffect(() => { if (!editId) return; (async () => {
    const { data } = await supabase.rpc("get_voucher", { p_id: editId });
    if (!data || !data.header) return;
    const h = data.header;
    setHdr({ idcode: h.voucher_id_code || "", no: h.voucher_no || "", date: h.voucher_date || today,
      posting_date: h.posting_date || today, valid_thru: h.valid_thru || "", ledger_id: h.ledger_id || "",
      ref_no: h.ref_no || "", narration: h.narration || "",
      vehicle: h.vehicle_no || "", slip_wt: h.scrap_slip_wt != null ? String(h.scrap_slip_wt) : "",
      cst_mid: (h.voucher_no || "").startsWith("CST/") ? ((h.voucher_no || "").split("/")[1] || "") : "" });
    const ls = (data.lines || []).map(l => ({ part_id: l.part_id || "", lot_id: l.lot_id || "", ref_no: l.ref_no || "",
      source_bucket: l.source_bucket || "", qty: l.qty ?? "", invoice_qty: l.invoice_qty ?? "", actual_qty: l.actual_qty ?? "",
      uom: l.uom || "Nos", unit_price: l.unit_price ?? "", po_price: l.po_price ?? "", defect_type: l.defect_type || "",
      root_cause: l.root_cause || "", line_note: l.line_note || "", _mwt: 0, _iwt: 0, _allow: 0, _qvar: 0,
      packages: Array.isArray(l.packages) ? l.packages.map(p => ({ token_ref: p.token_ref ?? "", net_weight: p.net_weight ?? "", qty: p.qty ?? "" })) : [], _pkgOpen: false,
      lot_alloc: Array.isArray(l.lot_alloc) ? l.lot_alloc.map(a => ({ lot_id: a.lot_id || "", lot_no: a.lot_no || "", qty: a.qty ?? "" })) : [], _lotOpen: false, _lotAvail: [] }));
    if (ls.length) setLines(ls);
  })(); }, [editId]);

  const INT_FIELDS = new Set(["qty","invoice_qty","actual_qty","pkg_count"]);
  const setLine = (i, k, v) => { if (INT_FIELDS.has(k)) v = String(v).replace(/[^0-9]/g, ""); setLines(rs => rs.map((r, j) => j === i ? { ...r, [k]: v } : r)); };
  async function onPart(i, partId) {
    setLine(i, "part_id", partId);
    const p = parts.find(x => x.id === partId); if (p) { setLine(i, "uom", p.uom || "Nos"); }
    // live available-stock indicator: source bucket balance (for outflow vouchers)
    if (partId && def.from && !["VENDOR", "CUSTOMER", null].includes(def.from)) {
      const { data } = await supabase.rpc("check_stock", { p_part: partId, p_bucket: def.from }); setLine(i, "_avail", data ?? 0);
    }
    // packages need weights: Purchase uses chosen vendor; DC/RC use AVERAGED RM profile
    if (def.packages && partId) {
      if (def.partsByVendor && hdr.ledger_id) {
        const { data } = await supabase.rpc("get_weight_profile", { p_part: partId, p_ledger: hdr.ledger_id, p_date: hdr.date });
        const wp = data && data[0]; if (wp) { setLine(i, "_iwt", wp.input_weight_pc || 0); setLine(i, "_allow", wp.allowance_pct || 0); setLine(i, "_qvar", wp.qty_variation || 0); }
      } else {
        const { data } = await supabase.rpc("avg_weight_profile", { p_part: partId });
        const wp = data && data[0]; if (wp) { setLine(i, "_iwt", wp.input_weight_pc || 0); setLine(i, "_allow", wp.allowance_pct || 0); setLine(i, "_qvar", wp.qty_variation || 0); }
      }
    }
    // rejection weight: averaged output weight across RM vendors
    if (def.autoWeightOut && partId) {
      const { data } = await supabase.rpc("avg_weight_profile", { p_part: partId });
      const wp = data && data[0]; if (wp) setLine(i, "_owt", wp.output_weight_pc || 0);
    }
    // price: locked types from pricing; manual purchase leaves blank
    if (def.priceFromRef) { /* set when ref chosen */ }
    else if (hdr.ledger_id && partId && !def.priceManual) { const { data } = await supabase.rpc("price_for_voucher", { p_part: partId, p_ledger: hdr.ledger_id, p_vtype: type, p_date: hdr.date }); if (data != null) { setLine(i, "unit_price", +data > 0 ? data : ""); } }
    // chained Ref: POs (purchase) / SOs (sales) by ledger+part
    if (def.refChained && hdr.ledger_id && partId) {
      const fn = def.ref === "PURCHASE_ORDER" ? "open_pos_for" : "open_sos_for";
      const { data } = await supabase.rpc(fn, { p_ledger: hdr.ledger_id, p_part: partId });
      setLine(i, "_refs", data || []);
    }
    // DC allocation for RC In (JW)
    if (def.dcAllocation && hdr.ledger_id && partId) {
      const { data } = await supabase.rpc("open_dcs_for", { p_ledger: hdr.ledger_id, p_part: partId });
      setDcAlloc((data || []).map(d => ({ ...d, allocate: "" })));
    }
    if (type === "SALES_LOCAL" && partId) {
      const { data: pl } = await supabase.from("part").select("lb_price").eq("id", partId).single();
      setLine(i, "_lb", (pl && +pl.lb_price) || 0);
    }
    if (def.autoWeight && partId) {
      const { data: wp } = await supabase.rpc("avg_weight_profile", { p_part: partId });
      const w = wp && wp[0] ? +wp[0].scrap_weight_pc || 0 : 0;
      setLine(i, "_mwt", w || (p && +p.scrap_weight_pc) || 0);
    }
    if (def.cols.includes("lot") && def.from && !["VENDOR", "CUSTOMER"].includes(def.from) && partId) { const { data } = await supabase.rpc("available_lots", { p_part: partId, p_bucket: def.from }); setLots(prev => ({ ...prev, [partId]: data || [] })); }
  }
  async function onRef(i, refNo) {
    setLine(i, "ref_no", refNo);
    setLines(rs => {
      const r = rs[i]; const list = (r && r._refs) || [];
      const hit = list.find(x => x.voucher_no === refNo);
      if (!hit) return rs;
      const price = hit.po_price ?? hit.so_price ?? 0;
      return rs.map((x, j) => j === i ? {
        ...x, ref_no: refNo,
        unit_price: def.priceFromRef ? price : x.unit_price,
        po_price: def.priceCheck ? price : x.po_price,
        _pend: hit.pending_qty,
      } : x);
    });
  }
  const qtyOf = r => r[def.qtyField || "qty"];
  const basicOf = r => { const q = parseFloat(qtyOf(r) || r.qty), p = parseFloat(r.unit_price); return (isNaN(q) || isNaN(p)) ? 0 : +(q * p).toFixed(2); };
  const weightOf = r => { const q = parseFloat(qtyOf(r) || r.qty); const w = def.autoWeightOut ? parseFloat(r._owt) : parseFloat(r._mwt); return (isNaN(q) || isNaN(w)) ? 0 : +(q * w).toFixed(3); };
  const total = lines.reduce((s, r) => s + basicOf(r), 0);
  const totalQty = lines.reduce((s, r) => s + (+(qtyOf(r) || r.qty) || 0), 0);
  const totalWt = lines.reduce((s, r) => s + weightOf(r), 0);
  const maxLines = def.maxLines || 999;

  // ---- packages (Purchase) ----
  const setPkg = (li, pi, k, v) => setLines(rs => rs.map((r, j) => j === li ? { ...r, packages: r.packages.map((p, m) => m === pi ? { ...p, [k]: v } : p) } : r));
  const addPkg = (li) => setLines(rs => rs.map((r, j) => j === li ? { ...r, packages: [...r.packages, newPkg()] } : r));
  const delPkg = (li, pi) => setLines(rs => rs.map((r, j) => j === li ? { ...r, packages: r.packages.filter((_, m) => m !== pi) } : r));
  const togglePkg = (li) => setLines(rs => rs.map((r, j) => j === li ? { ...r, _pkgOpen: !r._pkgOpen } : r));

  // ── multi-lot allocation (vendor-wise) ──
  const [lotCfg, setLotCfg] = useState({ enabled: false, mandatory: false });
  const [fieldRules, setFieldRules] = useState({});   // {TYPE:{field:bool}} from Settings (admin micro-manage)
  const fieldRule = (field, dflt) => { const t = fieldRules[type]; if (t && field in t) return !!t[field]; return dflt; };
  useEffect(() => { (async () => { const { data } = await supabase.rpc("get_settings"); const o = {}; (data || []).forEach(x => o[x.key] = x.value);
    setLotCfg({ enabled: o.lot_enabled === "true", mandatory: o.lot_mandatory === "true" });
    try { setFieldRules(JSON.parse(o.field_rules || "{}")); } catch (e) {} })(); }, []);
  const lotBucket = (r) => (def.from && !["VENDOR", "CUSTOMER"].includes(def.from)) ? def.from : (r.source_bucket || null);
  const lotOK = (r) => lotCfg.enabled && !def.dcAllocation && def.from !== "VENDOR" && !!lotBucket(r);
  const toggleLot = async (li) => {
    const r = lines[li]; const open = !r._lotOpen;
    setLines(rs => rs.map((x, j) => j === li ? { ...x, _lotOpen: open } : x));
    if (open && r.part_id && lotBucket(r)) {
      const { data } = await supabase.rpc("available_lots", { p_part: r.part_id, p_bucket: lotBucket(r) });
      setLines(rs => rs.map((x, j) => j === li ? { ...x, _lotAvail: data || [] } : x));
    }
  };
  const setLotA = (li, ai, k, v) => setLines(rs => rs.map((r, j) => j === li ? { ...r, lot_alloc: r.lot_alloc.map((a, m) => m === ai ? { ...a, [k]: v } : a) } : r));
  const addLotA = (li) => setLines(rs => rs.map((r, j) => j === li ? { ...r, lot_alloc: [...r.lot_alloc, { lot_id: "", lot_no: "", qty: "" }] } : r));
  const delLotA = (li, ai) => setLines(rs => rs.map((r, j) => j === li ? { ...r, lot_alloc: r.lot_alloc.filter((_, m) => m !== ai) } : r));
  // expected net weight band for a package qty: qty * input_weight ± allowance%
  function pkgWeightBand(r, pkgQty) {
    const iw = +r._iwt || 0; const a = (+r._allow || 0) / 100;
    const base = pkgQty * iw; return { lo: +(base * (1 - a)).toFixed(3), hi: +(base * (1 + a)).toFixed(3), base: +base.toFixed(3) };
  }
  function pkgIssues(r) {
    if (!def.packages || !r.packages.length) return [];
    const pkgQtyField = def.pkgQtyField || "actual_qty";
    const out = []; const actual = +r[pkgQtyField] || 0; let sumQty = 0, sumWt = 0; let incomplete = false, wtBad = false;
    r.packages.forEach((p) => {
      const q = parseFloat(p.qty), w = parseFloat(p.net_weight);
      if (p.token_ref === "" || isNaN(q) || isNaN(w)) { incomplete = true; return; }
      sumQty += q; sumWt += w;
      const band = pkgWeightBand(r, q);
      if (band.base > 0 && (w < band.lo || w > band.hi)) wtBad = true;
    });
    if (incomplete) out.push("Package: fill token, weight & qty for every package.");
    const qv = +r._qvar || 0;
    if (actual > 0 && (sumQty < actual - qv || sumQty > actual + qv)) out.push("Package > Qty total not matching.");
    if (wtBad) out.push("Package > Weight not matching.");
    return out;
  }

  const lineBad = r => { const q = qtyOf(r) == null ? r.qty : qtyOf(r); return !r.part_id || q === "" || isNaN(+q)
    || (def.simplePackages && !(+r.pkg_count > 0))
    || (type === "CREDIT_NOTE" && (r.unit_price === "" || isNaN(+r.unit_price))) || (def.sourceBucket && !r.source_bucket) || (def.defectDropdown && !r.defect_type) || (def.defectDropdown && r.defect_type === "__other" && !r.defect_other.trim()) || (def.ref === "PURCHASE_ORDER" && def.refChained && !r.ref_no) || (def.ref === "SALES_ORDER" && def.refChained && !r.ref_no); };
  const VEHICLE_TYPES = ["DEBIT_NOTE_RC","DC_OUT_JW","SALES_LOCAL","SCRAP_SALES","DEBIT_NOTE_DN"];
  const hasVehicle = VEHICLE_TYPES.includes(type);
  const VEHICLE_MAND = ["DEBIT_NOTE_RC","DC_OUT_JW","SALES_LOCAL","SCRAP_SALES","DEBIT_NOTE_DN"];
  const vehicleRequired = VEHICLE_MAND.includes(type) && fieldRule("vehicle", true);
  const narrationRequired = fieldRule("narration", false);
  const fyDash = (d) => { const dt = d ? new Date(d + "T00:00:00") : new Date(); const y = dt.getFullYear() % 100, m = dt.getMonth() + 1; const a = m >= 4 ? y : y - 1; return `${String(a).padStart(2, "0")}-${String((a + 1) % 100).padStart(2, "0")}`; };
  const headerBad = (!def.noNumber && !def.numberScheme && !hdr.no.trim()) || (def.numberScheme === "rcjw" && !(hdr.cst_mid || "").trim()) || (def.ledger && !def.sourceBucket && !hdr.ledger_id)
    || (vehicleRequired && !(hdr.vehicle||"").trim()) || (narrationRequired && !(hdr.narration||"").trim());

  useEffect(() => { const onKey = (e) => { if (e.ctrlKey && e.key === "Enter") { e.preventDefault(); save(); } };
    window.addEventListener("keydown", onKey); return () => window.removeEventListener("keydown", onKey); });
  const sumWeights = lines.reduce((t, r) => t + (r.part_id ? weightOf(r) : 0), 0);
  async function save() {
    setTouched(true); setMsg(null);
    if (type === "SCRAP_SALES") {
      const slip = +String(hdr.slip_wt || "").replace(/[^0-9.]/g, "") || 0;
      if (!slip) return setMsg({ t: "err", m: "Enter Nett Weight as per slip (Scrap Weight Slip Details)." });
      const lo = sumWeights * 0.95, hi = sumWeights * 1.05;
      if (slip < lo || slip > hi) { set("slip_wt", ""); return setMsg({ t: "err", m: `Slip weight ${slip.toFixed(2)} not within ±5% of sum of weights (${sumWeights.toFixed(2)}).` }); }
    }
    // ── SINGLE VALIDATION GATE — every condition checked here, BEFORE we
    //    decide price-pending or anything else. Nothing reaches save/approval
    //    until all of these pass. Applies to every module uniformly.
    if (headerBad || lines.some(lineBad)) return setMsg({ t: "err", m: "Complete the header and all required line fields (incl. Ref where mandatory)." });

    // packages: each line needs >=1 fully-filled row when driving qty>0; weight band; qty within ±qvar
    if (def.packages) {
      const pkgQtyField = def.pkgQtyField || "actual_qty";
      for (const r of lines) {
        if (!r.part_id) continue;
        const np = (+r[pkgQtyField] || 0);
        if (np > 0 && r.packages.length === 0) return setMsg({ t: "err", m: "At least one complete package row is required (token, weight, qty)." });
        const iss = pkgIssues(r); if (iss.length) return setMsg({ t: "err", m: iss[0] });
      }
    }
    // simple packages (Sales Local): a count > 0 required
    if (def.simplePackages) { const bad = lines.find(r => r.part_id && !(+r.pkg_count > 0)); if (bad) return setMsg({ t: "err", m: "No. of packages is required." }); }
    // DC allocation (RC In JW): each allocate <= pending, total allocate must equal Actual Qty
    if (def.dcAllocation) {
      const actual = +lines[0]?.actual_qty || 0;
      const allocTotal = dcAlloc.reduce((s, d) => s + (+d.allocate || 0), 0);
      const over = dcAlloc.find(d => (+d.allocate || 0) > (+d.pending_qty || 0));
      if (over) return setMsg({ t: "err", m: `Allocation for DC ${over.voucher_no} exceeds its pending ${(+over.pending_qty).toFixed(0)}.` });
      if (actual > 0 && allocTotal !== actual) return setMsg({ t: "err", m: `Total DC allocation (${allocTotal}) must equal Actual Qty (${actual}).` });
    }
    // weight sanity: any line that carries a weight must have a positive, numeric value
    for (const r of lines) {
      if (!r.part_id) continue;
      const wRaw = r.weight;
      if (wRaw !== undefined && wRaw !== "" && wRaw !== null) {
        const w = parseFloat(wRaw);
        if (isNaN(w) || w < 0) return setMsg({ t: "err", m: "Weight is invalid. Enter a valid (non-negative) weight before submitting." });
      }
    }

    // ── only AFTER all validations pass do we evaluate price-pending routing ──
    let pricePending = false;
    if (def.priceCheck) { const bad = lines.find(r => r.po_price && +r.unit_price !== +r.po_price); if (bad) pricePending = true; }
    // multi-lot validation: allocations must equal line qty; mandatory per admin setting
    for (const r of lines) {
      if (!r.part_id || !lotOK(r)) continue;
      const alloc = (r.lot_alloc || []).filter(a => a.lot_id && +a.qty > 0);
      const lq = +(qtyOf(r) || r.qty) || 0;
      if (alloc.length) {
        const tot = alloc.reduce((t, a) => t + (+a.qty || 0), 0);
        if (tot !== lq) return setMsg({ t: "err", m: `Lot allocation total (${tot}) must equal line qty (${lq}).` });
        const dup = new Set(); for (const a of alloc) { if (dup.has(a.lot_id)) return setMsg({ t: "err", m: "Same lot selected twice in one line." }); dup.add(a.lot_id); }
      } else if (lotCfg.mandatory && !r.lot_id && lq > 0) {
        return setMsg({ t: "err", m: "Lot allocation is mandatory (admin setting). Use the Lots panel on each line." });
      }
    }
    let payload = lines.map(r => ({ part_id: r.part_id, lot_id: r.lot_id || null, ref_no: r.ref_no || null, source_bucket: r.source_bucket || null,
      qty: +(qtyOf(r) || r.qty) || 0, invoice_qty: +r.invoice_qty || 0, actual_qty: +r.actual_qty || 0, uom: r.uom || "Nos",
      unit_price: +r.unit_price || 0, po_price: +r.po_price || 0, basic_value: basicOf(r), weight: (def.autoWeight || def.autoWeightOut) ? weightOf(r) : 0,
      defect_type: def.defectDropdown ? (r.defect_type === "__other" ? r.defect_other : r.defect_type) : (r.defect_type || null), root_cause: r.root_cause || null,
      line_note: def.simplePackages ? `Packages: ${r.pkg_count || 0}` + (r.line_note ? " | " + r.line_note : "") : (r.line_note || null),
      disposition: r.disposition || null, return_bucket: r.return_bucket || null, pkg_count: +r.pkg_count || 0,
      lot_alloc: (r.lot_alloc || []).filter(a => a.lot_id && +a.qty > 0).length ? r.lot_alloc.filter(a => a.lot_id && +a.qty > 0).map(a => ({ lot_id: a.lot_id, lot_no: a.lot_no || null, qty: +a.qty })) : null,
      packages: (def.packages && r.packages.length) ? r.packages.map((p, n) => ({ pkg: n + 1, token_ref: +p.token_ref || 0, net_weight: +p.net_weight || 0, qty: +p.qty || 0 })) : null }));
    // RC In (JW): expand the single line into one line per allocated DC so each DC's pending reduces correctly
    if (def.dcAllocation) {
      const base = payload[0]; const allocated = dcAlloc.filter(d => +d.allocate > 0);
      payload = allocated.map((d, n) => ({ ...base, ref_no: d.voucher_no, qty: +d.allocate, actual_qty: +d.allocate,
        invoice_qty: n === 0 ? base.invoice_qty : 0,
        packages: n === 0 ? base.packages : null }));  // packages attach to first split line
    }
    const { data, error } = isEdit
      ? await supabase.rpc("edit_voucher", {
          p_id: editId, p_no: (hdr.no||"").trim() || hdr.idcode, p_vehicle: hdr.vehicle || null, p_slip: type==="SCRAP_SALES" ? (+hdr.slip_wt || null) : null, p_date: hdr.date, p_posting: hdr.posting_date || null, p_valid: hdr.valid_thru || null,
          p_ledger: hdr.ledger_id || null, p_ref_no: hdr.ref_no || null, p_tax: 18, p_narration: hdr.narration || null,
          p_user: user?.username || "system", p_role: user?.role || "user", p_lines: payload, p_location: hdr.location_id || null }).then(r => ({ data: r.data, error: r.error || (r.data && !r.data.ok ? { message: r.data.msg } : null) }))
      : await supabase.rpc("post_voucher", {
          p_type: type, p_idcode: hdr.idcode, p_no: (hdr.no||"").trim() || hdr.idcode, p_vehicle: hdr.vehicle || null, p_slip: type==="SCRAP_SALES" ? (+hdr.slip_wt || null) : null, p_date: hdr.date, p_posting: hdr.posting_date || null,
          p_valid: hdr.valid_thru || null, p_ledger: hdr.ledger_id || null, p_ref_voucher: null, p_ref_no: hdr.ref_no || null,
          p_tax: 18, p_narration: hdr.narration || null, p_user: user?.username || "system", p_lines: payload, p_price_pending: pricePending, p_location: hdr.location_id || null, p_free_ledger: hdr.free_ledger || null });
    if (error) { const m = /duplicate key|vouchers_voucher_type_voucher_no_key|unique constraint/i.test(error.message) ? "Duplicate Value found — this voucher number already exists." : error.message; return setMsg({ t: "err", m }); }
    if (isEdit) { setMsg({ t: "ok", m: def.label + " " + hdr.no + " updated." }); if (onDone) setTimeout(onDone, 700); return; }
    if (data && data.rec_hold) { setMsg({ t: "warn", m: "An earlier document is past 2 days without a Received Copy, so this " + def.label + " is held in Rec Copy Approval. Stock will post only after an admin approves it." }); }
    else if (pricePending) { setMsg({ t: "ok", m: "Unit price ≠ PO price — saved to Price Approval. Stock will post only after admin approval." }); }
    else
    setMsg({ t: "ok", m: def.label + " " + hdr.no + " posted." });
    const { data: ic } = await supabase.rpc("next_voucher_idcode", { p_type: type });
    setHdr({ ...blankH, idcode: ic || "" }); setLines([newLine()]); setTouched(false);
  }

  const cols = def.cols;
  return (<div className="wrap"><Msg msg={msg} />
    <div className="card"><div className="card-h"><h2>{def.label} <StockChip from={def.from} to={def.to} /></h2><div className="voucher-id-badge">ID: {hdr.idcode || "—"}</div></div>
      <div className="card-b"><div className="fg">
        {!def.noNumber && (def.numberScheme === "rcjw"
          ? <Field label="Voucher Number" req bad={touched && !(hdr.cst_mid || "").trim()}>
              <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
                <span className="ctl" style={{ width: 58, textAlign: "center", background: "#eef1f4", flex: "0 0 auto" }}>CST/</span>
                <input className="ctl" style={{ flex: 1, minWidth: 60 }} inputMode="numeric" placeholder="numbers"
                  value={hdr.cst_mid || ""} onChange={e => set("cst_mid", e.target.value.replace(/\D/g, ""))} />
                <span className="ctl" style={{ width: 76, textAlign: "center", background: "#eef1f4", flex: "0 0 auto" }}>/{fyDash(hdr.date)}</span>
              </div>
            </Field>
          : <Field label="Voucher Number" req={!def.numberScheme} bad={touched && !def.numberScheme && !hdr.no.trim()}><input className="ctl" value={hdr.no} onChange={e => set("no", e.target.value)} disabled={!!def.numberScheme} /></Field>)}
        {hasVehicle && <Field label="Vehicle Number" req={vehicleRequired} bad={touched && vehicleRequired && !(hdr.vehicle||"").trim()}><input className="ctl" placeholder="e.g. TN 09 AB 1234" value={hdr.vehicle || ""} onChange={e => set("vehicle", e.target.value.toUpperCase())} /></Field>}
        <Field label="Voucher Date"><input className="ctl" type="date" value={hdr.date}
          max={def.dateTodayOnly ? today : (def.date2back ? today : undefined)}
          min={def.date2back && user?.role !== "admin" ? new Date(Date.now() - 2 * 86400000).toISOString().slice(0, 10) : undefined}
          disabled={def.dateTodayOnly} onChange={e => set("date", e.target.value)} /></Field>
        {def.header && def.header.includes("posting_date") && <Field label="Posting Date"><input className="ctl" type="date" value={hdr.posting_date} onChange={e => set("posting_date", e.target.value)} /></Field>}
        {def.header && def.header.includes("valid_thru") && <Field label={def.validThruLabel || "Valid Through"} req={false} hint={def.validThru === "due3" ? "date + 3 days" : def.validThru === "eom" ? "end of month" : "5th of next month"}><input className="ctl" type="date" value={hdr.valid_thru} disabled onChange={e => set("valid_thru", e.target.value)} /></Field>}
        {def.ledgerFreeText && <Field label="Ledger Name" req={false}><input className="ctl" placeholder="type vendor / party name" value={hdr.free_ledger || ""} onChange={e => set("free_ledger", e.target.value)} /></Field>}
        {def.ledger && <Field label={"Ledger (" + def.ledger + ")"} req={!def.sourceBucket} bad={touched && !def.sourceBucket && !hdr.ledger_id}><select className="ctl" value={hdr.ledger_id} onChange={e => set("ledger_id", e.target.value)}><option value="">— select —</option>{ledgers.map(l => <option key={l.id} value={l.id}>{l.ledger_code} · {l.ledger_name}</option>)}</select></Field>}
      </div>
      {def.ledger && !def.sourceBucket && !hdr.ledger_id && <div className="hint" style={{ marginTop: 10 }}>Select a ledger to load its mapped parts.</div>}</div>
    </div>
    <div className="card"><div className="card-h"><h2>Items</h2>{!def.single && <button className="btn ghost sm" onClick={() => setLines(r => [...r, newLine()])} disabled={lines.length >= maxLines}>+ Add Row</button>}</div>
      <div className="card-b" style={{ padding: 0, overflowX: "auto" }}><div className="lines-wrap">
        <table className="lines"><thead><tr><th className="sno">#</th>
          {cols.map(c => <th key={c} className={COLS[c].num ? "num" : ""} style={COLS[c].w !== "auto" ? { width: COLS[c].w } : null}>{COLS[c].th}</th>)}
          {!def.single && <th style={{ width: 36 }}></th>}</tr></thead>
          <tbody>{lines.map((r, i) => <React.Fragment key={i}>
            <tr className={touched && lineBad(r) ? "badrow" : ""}>
            <td className="sno">{i + 1}</td>
            {cols.map(c => <td key={c} className={COLS[c].num ? "num" : ""}>{cell(c, r, i)}</td>)}
            {!def.single && <td className="del">{lines.length > 1 && <button onClick={() => setLines(rs => rs.filter((_, j) => j !== i))}>✕</button>}</td>}
          </tr>
            {lotOK(r) && r.part_id && <tr className="pkg-row"><td></td><td colSpan={cols.length + (def.single ? 0 : 1)}>
              <div className="pkg-panel">
              <div className="pkg-head">
                <button type="button" className="pkg-toggle" onClick={() => toggleLot(i)}>{r._lotOpen ? "▾" : "▸"} Lots (vendor allocation) <span className="pkg-count">{(r.lot_alloc||[]).filter(a=>a.lot_id).length}</span></button>
                {r._lotOpen && <button type="button" className="btn ghost sm" onClick={() => addLotA(i)} disabled={(r.lot_alloc||[]).length >= 10}>+ Add Lot</button>}
              </div>
              {r._lotOpen && <>
                {(r._lotAvail||[]).length === 0 && <div className="pkg-hint" style={{padding:"4px 2px"}}>No open lots for this part in {lotBucket(r)}.</div>}
                {(r.lot_alloc||[]).length > 0 && <table className="pkg-table"><thead><tr><th>Lot</th><th className="num">Allocate Qty</th><th className="num">Available</th><th className="c-del"></th></tr></thead>
                <tbody>{r.lot_alloc.map((a, ai) => { const av = (r._lotAvail||[]).find(x => x.lot_id === a.lot_id);
                  return <tr key={ai}>
                    <td><select value={a.lot_id} onChange={e => { const lid = e.target.value; const hit = (r._lotAvail||[]).find(x => x.lot_id === lid);
                        setLotA(i, ai, "lot_id", lid); setLotA(i, ai, "lot_no", hit ? hit.lot_no : ""); }}>
                      <option value="">— select lot —</option>
                      {(r._lotAvail||[]).map(l => <option key={l.lot_id} value={l.lot_id}>{l.lot_no} · {l.ledger || ""} · avail {(+l.available).toFixed(0)}</option>)}
                    </select></td>
                    <td><input className="num" type="number" value={a.qty} onChange={e => setLotA(i, ai, "qty", e.target.value)} placeholder="qty" /></td>
                    <td className="num">{av ? (+av.available).toFixed(0) : "—"}</td>
                    <td className="c-del"><button onClick={() => delLotA(i, ai)}>✕</button></td>
                  </tr>; })}</tbody></table>}
              </>}
              </div>
            </td></tr>}
            {def.packages && r.part_id && <tr className="pkg-row"><td></td><td colSpan={cols.length + (def.single ? 0 : 1)}>
              <div className="pkg-panel">
              <div className="pkg-head">
                <button type="button" className="pkg-toggle" onClick={() => togglePkg(i)}>{r._pkgOpen ? "▾" : "▸"} Packages <span className="pkg-count">{r.packages.length}</span></button>
                {(+r[def.pkgQtyField || "actual_qty"] > 0 && r.packages.length === 0) && <span className="pkg-warn">required when quantity &gt; 0</span>}
                {r._pkgOpen && <button type="button" className="btn ghost sm" onClick={() => addPkg(i)} disabled={r.packages.length >= 10}>+ Add Package</button>}
              </div>
              {r._pkgOpen && r.packages.length > 0 && <table className="pkg-table"><thead><tr><th className="c-pkg">Pkg #</th><th>Token Ref No.</th><th className="num">Quantity</th><th className="num">Net Weight (kg)</th><th className="c-del"></th></tr></thead>
                <tbody>{r.packages.map((p, pi) => { const qNum = parseFloat(p.qty);
                  return <tr key={pi}>
                    <td className="c-pkg">{pi + 1}</td>
                    <td><input type="text" inputMode="numeric" value={p.token_ref} onChange={e => setPkg(i, pi, "token_ref", e.target.value.replace(/\D/g, "").slice(0, 6))} placeholder="6-digit token" /></td>
                    <td><input className="num" type="text" inputMode="numeric" value={p.qty} onChange={e => setPkg(i, pi, "qty", e.target.value.replace(/\D/g, "").slice(0, 5))} placeholder="qty" /></td>
                    <td><input className="num" type="text" inputMode="decimal" value={p.net_weight} onChange={e => setPkg(i, pi, "net_weight", e.target.value.replace(/[^\d.]/g, ""))} placeholder="kg" disabled={!(qNum > 0)} />
                      {!(qNum > 0) && <div className="pkg-hint">enter qty first</div>}</td>
                    <td className="c-del"><button type="button" onClick={() => delPkg(i, pi)}>✕</button></td>
                  </tr>; })}</tbody>
                <tfoot><tr><td className="c-pkg"></td><td style={{ textAlign: "right", fontWeight: 700 }}>Totals</td>
                  <td className="num">{r.packages.reduce((s, p) => s + (+p.qty || 0), 0)}</td>
                  <td className="num">{r.packages.reduce((s, p) => s + (+p.net_weight || 0), 0).toFixed(3)}</td><td className="c-del"></td></tr></tfoot></table>}
              </div>
            </td></tr>}
          </React.Fragment>)}</tbody>
          {cols.includes("basic_value") && <tfoot><tr><td colSpan={cols.indexOf("basic_value") + 1} style={{ textAlign: "right", border: "none" }}>Total</td><td className="num">{money(total)}</td><td style={{ border: "none" }} colSpan={cols.length - cols.indexOf("basic_value") - 1 + (def.single ? 0 : 1)}></td></tr></tfoot>}
          {def.totalsRow && <tfoot><tr className="ex-sumrow">
            {cols.map((c, ci) => <td key={c} className={COLS[c].num ? "num" : ""}>{c === "part" ? "TOTAL" : c === "qty" ? money(totalQty) : c === "weight" ? totalWt.toFixed(3) : ""}</td>)}
            {!def.single && <td></td>}</tr></tfoot>}
        </table></div>
        {def.priceCheck && <div style={{ padding: "8px 14px", color: "var(--muted)", fontSize: 11 }}>If Unit Price &gt; PO Price, submission is blocked — route via Price Approval.</div>}
      </div>
      {def.dcAllocation && <div className="card"><div className="card-h"><h2>DC Allocation</h2><span className="hint">DCs for this vendor &amp; part, pending &gt; 0</span></div>
        <div className="card-b" style={{ padding: 0 }}>
          {dcAlloc.length === 0 ? <div className="empty">Pick a ledger &amp; part to load open DCs.</div>
            : <table className="dt"><thead><tr><th>DC Number</th><th>DC Date</th><th>Due Date</th><th className="num">Pending Qty</th><th className="num">Allocate Qty</th></tr></thead>
              <tbody>{dcAlloc.map((d, i) => <tr key={d.voucher_no}><td className="mono">{d.voucher_no}</td><td>{toDMY(d.voucher_date)}</td><td>{toDMY(d.due_date)}</td><td className="num">{(+d.pending_qty).toFixed(0)}</td>
                <td className="num"><input className="num" type="number" max={d.pending_qty} value={d.allocate} onChange={e => setDcAlloc(a => a.map((x, j) => j === i ? { ...x, allocate: e.target.value } : x))} style={{ width: 90 }} /></td></tr>)}
                <tr className="ex-sumrow"><td colSpan={4} style={{ textAlign: "right" }}>Allocated Total</td><td className="num">{dcAlloc.reduce((s, d) => s + (+d.allocate || 0), 0).toFixed(0)}</td></tr></tbody></table>}
        </div>
      </div>}
      {def.dcAllocationVariant && <div className="card"><div className="card-h"><h2>DC Allocation</h2><span className="hint">Receive against an open DC Out — picks the party</span></div>
        <div className="card-b">
          <div className="fg">
            <Field label="Against DC" req={false}><select className="ctl" value={hdr.ref_no || ""} onChange={e => { const dc = variantDcs.find(d => d.voucher_no === e.target.value); set("ref_no", e.target.value); if (dc) set("free_ledger", dc.party); }}>
              <option value="">— select open DC —</option>
              {variantDcs.map(d => <option key={d.voucher_no} value={d.voucher_no}>{d.voucher_no} · {d.party} · {toDMY(d.voucher_date)} ({(+d.qty).toFixed(0)})</option>)}
            </select></Field>
            <Field label="Party (from DC)" req={false}><input className="ctl" value={hdr.free_ledger || ""} readOnly placeholder="set from DC above" /></Field>
          </div>
          {variantDcs.length === 0 && <div className="hint">No open DC Out of this type yet.</div>}
        </div>
      </div>}
      <div className="card"><div className="card-b"><div className="fg">
        {type === "SCRAP_SALES" && <Field label="Scrap Weight Slip Details — Nett Weight as per slip (kg)" req bad={touched && !(+hdr.slip_wt)}>
          <input className="ctl" inputMode="decimal" placeholder="0.00"
            value={hdr.slip_wt || ""} onChange={e => set("slip_wt", e.target.value.replace(/[^0-9.]/g, ""))} />
          <div className="hint">Sum of line weights: {sumWeights.toFixed(2)} kg · slip must be within ±5%</div>
        </Field>}
        {["PROCESS_REJECTION","MATERIAL_REJECTION","DEBIT_NOTE_DN"].includes(type) &&
          <Field label="Sum of weights" req={false}><input className="ctl num" value={sumWeights.toFixed(2) + " kg"} disabled /></Field>}
        <Field label="Narration" req={narrationRequired} bad={touched && narrationRequired && !(hdr.narration||"").trim()} wide>
          <input className="ctl" value={hdr.narration} onChange={e => set("narration", e.target.value)} /></Field>
      </div></div></div>
      <div className="row-actions"><button className="btn" onClick={save}>Post {def.label}</button></div>
    </div>
  </div>);

  function cell(c, r, i) {
    const m = COLS[c];
    if (c === "part") return <select value={r.part_id} onChange={e => onPart(i, e.target.value)}><option value="">— part —</option>{parts.map(p => <option key={p.id} value={p.id}>{p.part_code} · {p.part_name}</option>)}</select>;
    if (c === "ref") {
      if (def.refChained) { const list = r._refs || []; return <select value={r.ref_no} onChange={e => onRef(i, e.target.value)} disabled={!r.part_id}><option value="">— ref —</option>{list.map(v => <option key={v.voucher_no} value={v.voucher_no}>{v.voucher_no} · pend {(+v.pending_qty).toFixed(0)}</option>)}</select>; }
      return <select value={r.ref_no} onChange={e => setLine(i, "ref_no", e.target.value)}><option value="">— ref —</option>{refs.filter(v => !hdr.ledger_id || v.ledger_id === hdr.ledger_id).map(v => <option key={v.voucher_no} value={v.voucher_no}>{v.voucher_no} · pend {(+v.pending).toFixed(0)}</option>)}</select>;
    }
    if (c === "lot") return <select value={r.lot_id} onChange={e => setLine(i, "lot_id", e.target.value)}><option value="">— none —</option>{(lots[r.part_id] || []).map(l => <option key={l.lot_id} value={l.lot_id}>{l.lot_no} · {(+l.available).toFixed(0)}</option>)}</select>;
    if (c === "source_bucket") return <select value={r.source_bucket} onChange={e => setLine(i, "source_bucket", e.target.value)}><option value="">— bucket —</option>{["RC", "RCJW", "CC", "MG", "PR", "MR", "JOBOUT"].map(b => <option key={b} value={b}>{b}</option>)}</select>;
    if (c === "disposition") return <select value={r.disposition} onChange={e => setLine(i, "disposition", e.target.value)}><option value="RESALE">Resale → MG</option><option value="PROCESS">Process Issue → PR</option><option value="MATERIAL">Material Issue → MR</option></select>;
    if (c === "return_bucket") return <select value={r.return_bucket} onChange={e => setLine(i, "return_bucket", e.target.value)}><option value="">— same as source —</option>{["RC", "RCJW", "CC", "MG", "PR", "MR"].map(b => <option key={b} value={b}>{b}</option>)}</select>;
    if (c === "defect_type" && def.defectDropdown) return <div style={{ display: "flex", gap: 4 }}>
      <select value={r.defect_type} onChange={e => { if (e.target.value === "__create") { const n = window.prompt("New defect type:"); if (n) supabase.rpc("create_defect_type", { p_name: n }).then(() => supabase.rpc("list_defect_types").then(({ data }) => { setDefects(data || []); setLine(i, "defect_type", n); })); return; } setLine(i, "defect_type", e.target.value); }}>
        <option value="">— defect —</option>{defects.map(d => <option key={d.id} value={d.name}>{d.name}</option>)}<option value="__other">Others…</option><option value="__create">+ Create new</option></select>
      {r.defect_type === "__other" && <input placeholder="specify" value={r.defect_other} onChange={e => setLine(i, "defect_other", e.target.value)} />}</div>;
    if (c === "uom") return <input value={r.uom} disabled />;
    if (c === "basic_value") return <input className="num" value={money(basicOf(r))} disabled />;
    if (c === "lb_value") return <input className="num" value={money((+(qtyOf(r) ?? r.qty) || 0) * (+r._lb || 0))} disabled title="Qty × LB price (display only)" />;
    if (c === "weight") return <input className="num" value={weightOf(r).toFixed(3)} disabled />;
    if (c === "po_price") return <input className="num" value={r.po_price || ""} disabled />;
    if (c === "pkg_count") return <input className="num" type="number" value={r.pkg_count || ""} onChange={e => setLine(i, "pkg_count", e.target.value)} placeholder="count" />;
    if (c === "unit_price" && (def.priceLocked || def.priceFromRef)) return <input className="num" value={r.unit_price || ""} disabled />;
    // actual_qty: drives packages (auto-open) + live availability vs PO pending
    if (c === "actual_qty") return <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
      <input className="num" type="number" value={r.actual_qty} onChange={e => { const v = e.target.value; setLine(i, "actual_qty", v); if (def.packages && +v > 0 && (!r.packages || r.packages.length === 0)) setLines(rs => rs.map((x, j) => j === i ? { ...x, packages: [newPkg()], _pkgOpen: true } : x)); }} />
      {def.ref && r._pend != null && +r.actual_qty > +r._pend && <span className="cell-warn">PO pending {(+r._pend).toFixed(0)}</span>}
    </div>;
    // qty: live availability for stock-out vouchers; auto-open packages if qty drives packages (DC Out JW)
    if (c === "qty" && def.from && !["VENDOR", "CUSTOMER", null].includes(def.from)) { const av = r._avail;
      return <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
      <input className="num" type="text" inputMode="numeric" value={r.qty} onChange={e => {
        let v = e.target.value.replace(/[^\d.]/g, "");
        if (av != null && +v > +av) {
          // do NOT clamp: alert the user and clear the field
          setMsg({ t: "err", m: `Entered quantity (${v}) exceeds available stock (${(+av).toFixed(0)}). Field cleared.` });
          setLine(i, "qty", "");
          return;
        }
        setMsg(null);
        setLine(i, "qty", v);
        if (def.packages && def.pkgQtyField === "qty" && +v > 0 && (!r.packages || r.packages.length === 0)) setLines(rs => rs.map((x, j) => j === i ? { ...x, packages: [newPkg()], _pkgOpen: true } : x));
      }} />
      {av != null && <span className="cell-avail">available: {(+av).toFixed(0)}</span>}
    </div>; }
    if (m.ro) return <input className="num" value={r[m.key] || ""} disabled />;
    if (m.num) { const k = m.key || c; return <input className="num" type="number" value={r[k]} onChange={e => setLine(i, k, e.target.value)} />; }
    const k = c === "narration" ? "line_note" : c;
    return <input value={r[k] || ""} onChange={e => setLine(i, k, e.target.value)} />;
  }
}
