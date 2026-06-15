import React, { useState, useEffect } from "react";
import { supabase, todayISO, toDMY, money } from "../lib/config";
import { Field, Msg } from "../ui/primitives";

// module-level field wrapper (defining inside render remounts inputs and drops focus)
function DsxField({ label, req, hint, children }) {
  return (<div className="dsx-fld"><label>{label}{req && <span className="req">*</span>}</label>{children}{hint && <span className="hint">{hint}</span>}</div>);
}

/* ===================== LEDGER (create + edit + delete) ===================== */
export function LedgerForm({ user }) {
  const blank = { id: null, ledger_type: "Customer", ledger_name: "", gst_no: "", contact_email: "", tax: "Local", status: "Active" };
  const [f, setF] = useState(blank); const [code, setCode] = useState("…"); const [msg, setMsg] = useState(null); const [touched, setTouched] = useState(false);
  const [list, setList] = useState([]); const isAdmin = user?.role === "admin";
  const set = (k, v) => setF(s => ({ ...s, [k]: v }));
  const gstOk = (g) => !g || /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}[Z]{1}[0-9A-Z]{1}$/.test(g);
  async function loadCode() { const { data } = await supabase.rpc("next_ledger_code", { p_type: f.ledger_type }); setCode(f.id ? "—" : (data || "…")); }
  async function loadList() { const { data } = await supabase.from("ledger").select("*").order("ledger_code"); setList(data || []); }
  useEffect(() => { loadCode(); }, [f.ledger_type, f.id]);
  useEffect(() => { loadList(); }, []);
  const errs = { ledger_name: !f.ledger_name.trim(), gst: !gstOk(f.gst_no) };
  async function save() {
    setTouched(true); setMsg(null);
    if (errs.ledger_name) return setMsg({ t: "err", m: "Ledger Name is required." });
    if (errs.gst) return setMsg({ t: "err", m: "GST No format invalid (e.g. 22AAAAA0000A1Z5)." });
    const { error } = await supabase.rpc("admin_save_ledger", { p_id: f.id, p_type: f.ledger_type, p_name: f.ledger_name, p_gst: f.gst_no, p_email: f.contact_email, p_tax: f.tax, p_status: f.status });
    if (error) return setMsg({ t: "err", m: error.message });
    setMsg({ t: "ok", m: f.id ? "Ledger updated." : "Ledger created." }); setF(blank); setTouched(false); loadList(); loadCode();
  }
  async function del(id) { if (!window.confirm("Delete this ledger?")) return;
    const { data, error } = await supabase.rpc("admin_delete_ledger", { p_id: id });
    if (error) return setMsg({ t: "err", m: error.message }); if (!data?.ok) return setMsg({ t: "err", m: data?.msg }); setMsg({ t: "ok", m: data.msg }); loadList(); }
  return (<div className="wrap"><Msg msg={msg} />
    <div className="card"><div className="card-h"><h2>{f.id ? "Edit Ledger" : "Ledger"}</h2></div>
      <div className="card-b"><div className="fg">
        <Field label="Ledger Type"><select className="ctl" value={f.ledger_type} disabled={!!f.id} onChange={e => set("ledger_type", e.target.value)}><option>Customer</option><option>Vendor RM</option><option>Vendor JW</option></select></Field>
        <Field label="Ledger Code" req={false}><input className="ctl mono" value={f.id ? "—" : code} disabled /></Field>
        <Field label="Status" req={false}><select className="ctl" value={f.status} onChange={e => set("status", e.target.value)}><option>Active</option><option>Inactive</option></select></Field>
        <Field label="Ledger Name" bad={touched && errs.ledger_name}><input className="ctl" value={f.ledger_name} onChange={e => set("ledger_name", e.target.value)} /></Field>
        <Field label="GST No" req={false} bad={touched && errs.gst} hint="NNAAAAANNNNANA(A/N)"><input className="ctl" value={f.gst_no} onChange={e => set("gst_no", e.target.value.toUpperCase())} maxLength={15} /></Field>
        <Field label="Contact Email" req={false}><input className="ctl" type="email" value={f.contact_email} onChange={e => set("contact_email", e.target.value)} /></Field>
        <Field label="Tax"><select className="ctl" value={f.tax} onChange={e => set("tax", e.target.value)}><option>Local</option><option>Interstate</option><option>Import / Export</option></select></Field>
      </div></div>
      <div className="row-actions"><button className="btn" onClick={save}>{f.id ? "Update" : "Save"} Ledger</button>{f.id && <button className="btn ghost" onClick={() => setF(blank)}>Cancel</button>}</div>
    </div>
    <div className="card"><div className="card-h"><h2>Ledgers</h2></div>
      <div className="card-b" style={{ padding: 0 }}>
        {list.length === 0 ? <div className="empty">No ledgers yet.</div>
          : <table className="dt"><thead><tr><th>Code</th><th>Type</th><th>Name</th><th>GST</th><th>Tax</th><th>Status</th>{isAdmin && <th></th>}</tr></thead>
            <tbody>{list.map(l => <tr key={l.id}><td className="mono">{l.ledger_code}</td><td>{l.ledger_type}</td><td>{l.ledger_name}</td><td>{l.gst_no || "—"}</td><td>{l.tax}</td><td><span className={"pill " + (l.status === "Active" ? "on" : "off")}>{l.status}</span></td>
              {isAdmin && <td><button className="btn ghost sm" onClick={() => setF({ id: l.id, ledger_type: l.ledger_type, ledger_name: l.ledger_name, gst_no: l.gst_no || "", contact_email: l.contact_email || "", tax: l.tax || "Local", status: l.status })}>Edit</button>{" "}<button className="btn ghost sm" onClick={() => del(l.id)}>Delete</button></td>}</tr>)}</tbody></table>}
      </div>
    </div>
  </div>);
}

/* ===================== PART (General fixed + Customers / Vendors tabs) ===================== */
export function PartForm({ user }) {
  const [code, setCode] = useState("…"); const [editId, setEditId] = useState(null); const [touched, setTouched] = useState(false); const [msg, setMsg] = useState(null); const [tab, setTab] = useState("customers");
  const [g, setG] = useState({ part_name: "", part_number: "", uom: "Nos", part_group_id: "", status: "Active", reorder_level: "", reorder_bucket: "MG", monthly_target: "", cumulative_group: "", lb_price: "" });
  const [cumGroups, setCumGroups] = useState([]);
  const [groups, setGroups] = useState([]); const [vendors, setVendors] = useState([]); const [customers, setCustomers] = useState([]); const [list, setList] = useState([]);
  const isAdmin = user?.role === "admin";
  // customer price rows: ledger, price, from, upto
  const newC = () => ({ id: null, ledger_id: "", unit_price: "", valid_from: todayISO(), valid_upto: "" });
  // vendor rows: ledger, price, from, upto + weights
  const newV = () => ({ id: null, ledger_id: "", unit_price: "", valid_from: todayISO(), valid_upto: "", input_weight_pc: "", output_weight_pc: "", allowance_pct: "", qty_variation: "" });
  const [cRows, setCRows] = useState([newC()]); const [vRows, setVRows] = useState([newV()]);

  async function loadGroups() { const { data } = await supabase.rpc("list_part_groups"); setGroups(data || []); const { data: cg } = await supabase.rpc("cumulative_groups"); setCumGroups((cg||[]).map(x=>x.grp)); }
  async function loadList() { const { data } = await supabase.from("part").select("*").order("part_code"); setList(data || []); }
  async function createGroup() { const name = window.prompt("New Part Group name:"); if (!name) return; const { data, error } = await supabase.rpc("create_part_group", { p_name: name }); if (error) return setMsg({ t: "err", m: error.message }); await loadGroups(); setG(s => ({ ...s, part_group_id: data })); }
  useEffect(() => { (async () => {
    const { data } = await supabase.rpc("next_part_code"); setCode(data || "…");
    const { data: v } = await supabase.from("ledger").select("id,ledger_code,ledger_name").eq("ledger_type", "Vendor RM").eq("status", "Active").order("ledger_code"); setVendors(v || []);
    const { data: c } = await supabase.from("ledger").select("id,ledger_code,ledger_name").eq("ledger_type", "Customer").eq("status", "Active").order("ledger_code"); setCustomers(c || []);
    loadGroups(); loadList();
  })(); }, []);
  const setVR = (i, k, v) => setVRows(rs => rs.map((r, j) => j === i ? { ...r, [k]: v } : r));
  const setCR = (i, k, v) => setCRows(rs => rs.map((r, j) => j === i ? { ...r, [k]: v } : r));
  const genBad = !g.part_name.trim();
  const vC = r => r.ledger_id && r.unit_price !== ""; const cC = r => r.ledger_id && r.unit_price !== "";

  async function loadForEdit(p) {
    setEditId(p.id); setTab("customers");
    setG({ part_name: p.part_name, part_number: p.part_number || "", uom: p.uom || "Nos", part_group_id: p.part_group_id || "", status: p.status, reorder_level: p.reorder_level || "", reorder_bucket: p.reorder_bucket || "MG", monthly_target: p.monthly_target || "", cumulative_group: p.cumulative_group || "", lb_price: p.lb_price || "" });
    const { data: pr } = await supabase.from("part_price").select("*").eq("part_id", p.id);
    const cs = (pr || []).filter(x => x.price_type === "sale").map(x => ({ id: x.id, ledger_id: x.ledger_id, unit_price: x.unit_price, valid_from: x.valid_from || "", valid_upto: x.valid_upto || "" }));
    const vs = (pr || []).filter(x => x.price_type === "purchase").map(x => ({ id: x.id, ledger_id: x.ledger_id, unit_price: x.unit_price, valid_from: x.valid_from || "", valid_upto: x.valid_upto || "", input_weight_pc: x.input_weight_pc || "", output_weight_pc: x.output_weight_pc || "", allowance_pct: x.allowance_pct || "", qty_variation: x.qty_variation || "" }));
    setCRows(cs.length ? cs : [newC()]); setVRows(vs.length ? vs : [newV()]);
    window.scrollTo(0, 0);
  }
  function resetForm() { setEditId(null); setG({ part_name: "", part_number: "", uom: "Nos", part_group_id: "", status: "Active", reorder_level: "", reorder_bucket: "MG", monthly_target: "", cumulative_group: "", lb_price: "" }); setCRows([newC()]); setVRows([newV()]); setTouched(false); }

  async function save() {
    setTouched(true); setMsg(null);
    if (genBad) return setMsg({ t: "err", m: "Part Name is required." });
    if (!vRows.some(vC) && !cRows.some(cC)) return setMsg({ t: "err", m: "Add at least one Customer or Vendor row." });
    const pid = await supabase.rpc("admin_save_part", { p_id: editId, p_name: g.part_name, p_number: g.part_number, p_uom: g.uom, p_group: g.part_group_id || null, p_status: g.status, p_cumulative: g.cumulative_group || null, p_lb: +g.lb_price || 0 });
    if (pid.error) return setMsg({ t: "err", m: pid.error.message });
    const part_id = pid.data;
    // save reorder level / target settings
    await supabase.rpc("save_part_reorder", { p_part: part_id, p_level: +g.reorder_level || 0, p_bucket: g.reorder_bucket || "MG", p_target: +g.monthly_target || 0 });
    // save customer (sale) rows
    for (const r of cRows.filter(cC)) {
      const { error } = await supabase.rpc("save_part_price", { p_id: r.id, p_part: part_id, p_ledger: r.ledger_id, p_type: "sale", p_price: +r.unit_price, p_from: r.valid_from || null, p_upto: r.valid_upto || null, p_inw: 0, p_outw: 0, p_allow: 0, p_qvar: 0 });
      if (error) return setMsg({ t: "err", m: error.message });
    }
    // save vendor (purchase) rows with weights
    for (const r of vRows.filter(vC)) {
      const { error } = await supabase.rpc("save_part_price", { p_id: r.id, p_part: part_id, p_ledger: r.ledger_id, p_type: "purchase", p_price: +r.unit_price, p_from: r.valid_from || null, p_upto: r.valid_upto || null, p_inw: +r.input_weight_pc || 0, p_outw: +r.output_weight_pc || 0, p_allow: +r.allowance_pct || 0, p_qvar: +r.qty_variation || 0 });
      if (error) return setMsg({ t: "err", m: error.message });
    }
    setMsg({ t: "ok", m: editId ? "Part updated." : "Part created." }); resetForm(); loadList();
    const { data } = await supabase.rpc("next_part_code"); setCode(data);
  }
  async function del(id) { if (!window.confirm("Delete this part?")) return;
    const { data, error } = await supabase.rpc("admin_delete_part", { p_id: id });
    if (error) return setMsg({ t: "err", m: error.message }); if (!data?.ok) return setMsg({ t: "err", m: data?.msg }); setMsg({ t: "ok", m: data.msg }); loadList(); }

  return (<div className="wrap"><Msg msg={msg} />
    {/* General Data — fixed (always visible) */}
    <div className="card"><div className="card-h"><h2>{editId ? "Edit Part" : "Part"} — General Data</h2></div>
      <div className="card-b"><div className="fg">
        <Field label="Part ID" req={false}><input className="ctl mono" value={editId ? "—" : code} disabled /></Field>
        <Field label="Part Name" bad={touched && genBad}><input className="ctl" value={g.part_name} onChange={e => setG(s => ({ ...s, part_name: e.target.value }))} /></Field>
        <Field label="Part Number" req={false}><input className="ctl" value={g.part_number} onChange={e => setG(s => ({ ...s, part_number: e.target.value }))} /></Field>
        <Field label="LB Price" req={false}><input className="ctl" type="number" placeholder="0.00" value={g.lb_price} onChange={e => setG(s => ({ ...s, lb_price: e.target.value }))} /></Field>
        <Field label="UOM" req={false}><input className="ctl" value={g.uom} onChange={e => setG(s => ({ ...s, uom: e.target.value }))} /></Field>
        <Field label="Part Group" req={false}><div style={{ display: "flex", gap: 8 }}>
          <select className="ctl" value={g.part_group_id} onChange={e => setG(s => ({ ...s, part_group_id: e.target.value }))}><option value="">— none —</option>{groups.map(gr => <option key={gr.id} value={gr.id}>{gr.group_name}</option>)}</select>
          <button type="button" className="btn ghost sm" onClick={createGroup}>+ Create</button></div></Field>
        <Field label="Status" req={false}><select className="ctl" value={g.status} onChange={e => setG(s => ({ ...s, status: e.target.value }))}><option>Active</option><option>Inactive</option></select></Field>
        <Field label="Reorder Level" req={false}><input className="ctl num" type="text" inputMode="decimal" placeholder="0 = no alert" value={g.reorder_level} onChange={e => setG(s => ({ ...s, reorder_level: e.target.value.replace(/[^\d.]/g, "") }))} /></Field>
        <Field label="Reorder Bucket" req={false}><select className="ctl" value={g.reorder_bucket} onChange={e => setG(s => ({ ...s, reorder_bucket: e.target.value }))}>{["RC","RCJW","CC","MG","PR","MR","JOBOUT"].map(b => <option key={b} value={b}>{b}</option>)}</select></Field>
        <Field label="Monthly Target" req={false}><input className="ctl num" type="text" inputMode="decimal" placeholder="0" value={g.monthly_target} onChange={e => setG(s => ({ ...s, monthly_target: e.target.value.replace(/[^\d.]/g, "") }))} /></Field>
        <Field label="Cumulative Group" req={false}>
          <input className="ctl" list="cumgroups" placeholder="e.g. SP2i — type new or pick" value={g.cumulative_group} onChange={e => setG(s => ({ ...s, cumulative_group: e.target.value }))} />
          <datalist id="cumgroups">{cumGroups.map(cg => <option key={cg} value={cg} />)}</datalist>
        </Field>
      </div>
      <div className="hint" style={{ marginTop: 8 }}>Cumulative Group is for the Stock overview only — it lets you see the same part bought from different vendors (e.g. SP2i NMC, SP2i SF, SP2i ILJIN) combined as one. It does not affect stock, vouchers, or balances.</div>
      </div>
    </div>
    {/* Two tabs below general: Customers / Vendors */}
    <div className="tabs">
      <button className={tab === "customers" ? "active" : ""} onClick={() => setTab("customers")}>Customers</button>
      <button className={tab === "vendors" ? "active" : ""} onClick={() => setTab("vendors")}>Vendors</button>
    </div>
    <div className="card" style={{ borderTopLeftRadius: 0 }}>
      {tab === "customers" && <div className="card-b" style={{ padding: 0 }}>
        <div style={{ padding: "10px 14px" }}><button className="btn ghost sm" onClick={() => setCRows(r => [...r, newC()])}>+ Add Customer</button></div>
        <div className="lines-wrap"><table className="lines"><thead><tr><th>Customer (Ledger)</th><th className="num">Unit Price</th><th>Valid From</th><th>Valid Upto</th><th></th></tr></thead>
          <tbody>{cRows.map((r, i) => <tr key={i}>
            <td><select value={r.ledger_id} onChange={e => setCR(i, "ledger_id", e.target.value)}><option value="">— select —</option>{customers.map(x => <option key={x.id} value={x.id}>{x.ledger_code} · {x.ledger_name}</option>)}</select></td>
            <td><input className="num" type="number" value={r.unit_price} onChange={e => setCR(i, "unit_price", e.target.value)} /></td>
            <td><input type="date" value={r.valid_from} onChange={e => setCR(i, "valid_from", e.target.value)} /></td>
            <td><input type="date" value={r.valid_upto} onChange={e => setCR(i, "valid_upto", e.target.value)} /></td>
            <td className="del">{cRows.length > 1 && <button onClick={() => setCRows(rs => rs.filter((_, j) => j !== i))}>✕</button>}</td>
          </tr>)}</tbody></table></div>
      </div>}
      {tab === "vendors" && <div className="card-b" style={{ padding: 0 }}>
        <div style={{ padding: "10px 14px" }}><button className="btn ghost sm" onClick={() => setVRows(r => [...r, newV()])}>+ Add Vendor</button>
          <span className="hint" style={{ marginLeft: 12 }}>Weights & allowance are per-vendor.</span></div>
        <div className="lines-wrap" style={{ overflowX: "auto" }}><table className="lines"><thead><tr><th>Vendor RM (Ledger)</th><th className="num">Unit Price</th><th>Valid From</th><th>Valid Upto</th><th className="num">Input Wt/Pc</th><th className="num">Output Wt/Pc</th><th className="num">Scrap Wt/Pc</th><th className="num">Allow %</th><th className="num">Qty Var</th><th></th></tr></thead>
          <tbody>{vRows.map((r, i) => { const scrap = (parseFloat(r.input_weight_pc) - parseFloat(r.output_weight_pc)); return <tr key={i}>
            <td><select value={r.ledger_id} onChange={e => setVR(i, "ledger_id", e.target.value)}><option value="">— select —</option>{vendors.map(x => <option key={x.id} value={x.id}>{x.ledger_code} · {x.ledger_name}</option>)}</select></td>
            <td><input className="num" type="number" value={r.unit_price} onChange={e => setVR(i, "unit_price", e.target.value)} /></td>
            <td><input type="date" value={r.valid_from} onChange={e => setVR(i, "valid_from", e.target.value)} /></td>
            <td><input type="date" value={r.valid_upto} onChange={e => setVR(i, "valid_upto", e.target.value)} /></td>
            <td><input className="num" type="number" value={r.input_weight_pc} onChange={e => setVR(i, "input_weight_pc", e.target.value)} /></td>
            <td><input className="num" type="number" value={r.output_weight_pc} onChange={e => setVR(i, "output_weight_pc", e.target.value)} /></td>
            <td><input className="num" value={isNaN(scrap) ? "" : scrap.toFixed(3)} disabled /></td>
            <td><input className="num" type="number" value={r.allowance_pct} onChange={e => setVR(i, "allowance_pct", e.target.value)} /></td>
            <td><input className="num" type="number" value={r.qty_variation} onChange={e => setVR(i, "qty_variation", e.target.value)} /></td>
            <td className="del">{vRows.length > 1 && <button onClick={() => setVRows(rs => rs.filter((_, j) => j !== i))}>✕</button>}</td>
          </tr>; })}</tbody></table></div>
      </div>}
      <div className="row-actions"><button className="btn" onClick={save}>{editId ? "Update" : "Save"} Part</button>{editId && <button className="btn ghost" onClick={resetForm}>Cancel</button>}</div>
    </div>
    {/* Part list with edit/delete */}
    <div className="card"><div className="card-h"><h2>Parts</h2></div>
      <div className="card-b" style={{ padding: 0 }}>
        {list.length === 0 ? <div className="empty">No parts yet.</div>
          : <table className="dt"><thead><tr><th>Code</th><th>Name</th><th>Number</th><th>UOM</th><th>Status</th>{isAdmin && <th></th>}</tr></thead>
            <tbody>{list.map(p => <tr key={p.id}><td className="mono">{p.part_code}</td><td>{p.part_name}</td><td>{p.part_number || "—"}</td><td>{p.uom}</td><td><span className={"pill " + (p.status === "Active" ? "on" : "off")}>{p.status}</span></td>
              {isAdmin && <td><button className="btn ghost sm" onClick={() => loadForEdit(p)}>Edit</button>{" "}<button className="btn ghost sm" onClick={() => del(p.id)}>Delete</button></td>}</tr>)}</tbody></table>}
      </div>
    </div>
  </div>);
}

/* ===================== PART PRICING (editable, 2 sub-forms) ===================== */
export function PartPricing() {
  const [tab, setTab] = useState("purchase");
  return (<div className="dsx">
    <div className="dsx-head">
      <div><h1>Part Pricing</h1><div className="sub">Vendor and customer prices with validity windows and weight profiles.</div></div>
      <div className="dsx-seg">
        <button className={tab === "purchase" ? "on" : ""} onClick={() => setTab("purchase")}>Purchase Prices</button>
        <button className={tab === "sale" ? "on" : ""} onClick={() => setTab("sale")}>Sales Prices</button>
      </div>
    </div>
    <PriceTable kind={tab} key={tab} />
  </div>);
}
function PriceTable({ kind }) {
  const [rows, setRows] = useState([]); const [parts, setParts] = useState([]); const [ledgers, setLedgers] = useState([]); const [msg, setMsg] = useState(null);
  const blank = { id: null, part_id: "", ledger_id: "", unit_price: "", lb_price: "", valid_from: todayISO(), valid_upto: "", input_weight_pc: "", output_weight_pc: "", allowance_pct: "", qty_variation: "" };
  const [f, setF] = useState(blank); const set = (k, v) => setF(s => ({ ...s, [k]: v }));
  const ledType = kind === "purchase" ? "Vendor RM" : "Customer";
  async function load() {
    const { data } = await supabase.rpc("list_part_prices", { p_type: kind }); setRows(data || []);
    const { data: p } = await supabase.from("part").select("id,part_code,part_name").eq("status", "Active").order("part_code"); setParts(p || []);
    const { data: l } = await supabase.from("ledger").select("id,ledger_code,ledger_name").eq("ledger_type", ledType).eq("status", "Active").order("ledger_code"); setLedgers(l || []);
  }
  useEffect(() => { load(); }, [kind]);
  async function save() {
    if (!f.part_id || !f.ledger_id || f.unit_price === "") return setMsg({ t: "err", m: "Part, Ledger and Price are required." });
    const { error } = await supabase.rpc("save_part_price", { p_id: f.id, p_part: f.part_id, p_ledger: f.ledger_id, p_type: kind, p_price: +f.unit_price, p_from: f.valid_from || null, p_upto: f.valid_upto || null, p_inw: +f.input_weight_pc || 0, p_outw: +f.output_weight_pc || 0, p_allow: +f.allowance_pct || 0, p_qvar: +f.qty_variation || 0, p_lb: +f.lb_price || 0 });
    if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: `${kind === "purchase" ? "Purchase" : "Sales"} price saved.` }); setF(blank); load();
  }
  async function del(id) { if (!window.confirm("Delete this price row?")) return; const { error } = await supabase.rpc("delete_part_price", { p_id: id }); if (error) return setMsg({ t: "err", m: error.message }); load(); }
  const F = DsxField;
  return (<><Msg msg={msg} />
    <div className="dsx-card">
      <div className="dsx-card-h"><h2>{f.id ? "Edit price" : "Add a price"}</h2><span className="sub">{kind === "purchase" ? "Vendor purchase rate" : "Customer sales rate"}</span></div>
      <div className="dsx-card-b"><div className="dsx-form">
        <F label="Part" req><select className="dsx-select" value={f.part_id} onChange={e => set("part_id", e.target.value)}><option value="">Select part…</option>{parts.map(p => <option key={p.id} value={p.id}>{p.part_code} · {p.part_name}</option>)}</select></F>
        <F label={kind === "purchase" ? "Vendor" : "Customer"} req><select className="dsx-select" value={f.ledger_id} onChange={e => set("ledger_id", e.target.value)}><option value="">Select {kind === "purchase" ? "vendor" : "customer"}…</option>{ledgers.map(l => <option key={l.id} value={l.id}>{l.ledger_code} · {l.ledger_name}</option>)}</select></F>
        <F label={kind === "sale" ? "FG price / unit (actual)" : "Basic price / unit"} req><input className="dsx-input" type="number" placeholder="0.00" value={f.unit_price} onChange={e => set("unit_price", e.target.value)} /></F>
        {kind === "sale" && <F label="LB price / unit" hint="What you actually receive — shown in Sales (Local) books"><input className="dsx-input" type="number" placeholder="0.00" value={f.lb_price} onChange={e => set("lb_price", e.target.value)} /></F>}
        <F label="Valid from"><input className="dsx-input" type="date" value={f.valid_from} onChange={e => set("valid_from", e.target.value)} /></F>
        <F label="Valid thru" hint="Leave blank for open-ended"><input className="dsx-input" type="date" value={f.valid_upto} onChange={e => set("valid_upto", e.target.value)} /></F>
        {kind === "purchase" && <>
          <F label="Input weight / pc" hint="Enables weight checks"><input className="dsx-input" type="number" placeholder="0.000" value={f.input_weight_pc} onChange={e => set("input_weight_pc", e.target.value)} /></F>
          <F label="Output weight / pc"><input className="dsx-input" type="number" placeholder="0.000" value={f.output_weight_pc} onChange={e => set("output_weight_pc", e.target.value)} /></F>
          <F label="Allowance %"><input className="dsx-input" type="number" placeholder="0.00" value={f.allowance_pct} onChange={e => set("allowance_pct", e.target.value)} /></F>
          <F label="Qty variation"><input className="dsx-input" type="number" placeholder="0" value={f.qty_variation} onChange={e => set("qty_variation", e.target.value)} /></F>
        </>}
      </div>
      <div style={{ display: "flex", gap: 9, marginTop: 20 }}><button className="dsx-btn primary" onClick={save}>{f.id ? "Update price" : "Add price"}</button>{f.id && <button className="dsx-btn ghost" onClick={() => setF(blank)}>Cancel</button>}</div>
      </div>
    </div>
    <div className="dsx-card">
      <div className="dsx-card-h"><h2>{kind === "purchase" ? "Purchase" : "Sales"} prices</h2><span className="sub">{rows.length} {rows.length === 1 ? "row" : "rows"}</span></div>
      <div className="dsx-card-b flush"><div className="dsx-table-wrap">
        {rows.length === 0 ? <div className="dsx-empty"><div className="big">No {kind} prices yet</div>Add one above to get started.</div>
          : <table className="dsx-table"><thead><tr><th>Part</th><th>{kind === "purchase" ? "Vendor" : "Customer"}</th><th className="num">{kind === "sale" ? "FG Price" : "Price"}</th>{kind === "sale" && <th className="num">LB Price</th>}<th>Valid from</th><th>Valid thru</th><th className="c">Status</th>{kind === "purchase" && <><th className="num">In wt</th><th className="num">Allow %</th></>}<th className="r">Actions</th></tr></thead>
            <tbody>{rows.map(r => <tr key={r.id}>
              <td><span className="dsx-strong">{r.part_code}</span> · {r.part_name}</td>
              <td>{r.ledger_name}</td>
              <td className="num dsx-strong">{money(r.unit_price)}</td>
              {kind === "sale" && <td className="num">{money(r.lb_price)}</td>}
              <td className="dsx-muted">{toDMY(r.valid_from)}</td>
              <td className="dsx-muted">{r.valid_upto ? toDMY(r.valid_upto) : "—"}</td>
              <td className="c">{r.active_now ? <span className="dsx-badge ok"><span className="dot" />Active</span> : <span className="dsx-badge off">Inactive</span>}</td>
              {kind === "purchase" && <><td className="num">{(+r.input_weight_pc).toFixed(3)}</td><td className="num">{(+r.allowance_pct).toFixed(2)}</td></>}
              <td className="r"><button className="dsx-btn ghost sm" onClick={() => setF({ id: r.id, part_id: r.part_id, ledger_id: r.ledger_id, unit_price: r.unit_price, lb_price: r.lb_price || "", valid_from: r.valid_from || "", valid_upto: r.valid_upto || "", input_weight_pc: r.input_weight_pc || "", output_weight_pc: r.output_weight_pc || "", allowance_pct: r.allowance_pct || "", qty_variation: r.qty_variation || "" })}>Edit</button>{" "}<button className="dsx-btn danger sm" onClick={() => del(r.id)}>Delete</button></td></tr>)}</tbody></table>}
      </div></div>
    </div>
  </>);
}

/* ===================== BURR ===================== */
export function BurrReport() {
  const [from, setFrom] = useState(""); const [to, setTo] = useState(todayISO()); const [rows, setRows] = useState([]); const [loaded, setLoaded] = useState(false);
  async function run() { const { data } = await supabase.rpc("scrap_report", { p_from: from || null, p_to: to || null }); setRows(data || []); setLoaded(true); }
  const total = rows.reduce((s, r) => s + (+r.total_scrap), 0);
  return (<div className="wrap">
    <div className="card"><div className="card-h"><h2>Burr Generation Report</h2>
      <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
        <input className="ctl" style={{ width: 140 }} type="date" value={from} onChange={e => setFrom(e.target.value)} /><span style={{ color: "var(--muted)" }}>to</span>
        <input className="ctl" style={{ width: 140 }} type="date" value={to} onChange={e => setTo(e.target.value)} /><button className="btn sm" onClick={run}>Run</button></div></div>
      <div className="card-b" style={{ padding: 0 }}>
        {!loaded ? <div className="empty">Set a range and Run.</div> : rows.length === 0 ? <div className="empty">No production in range.</div>
          : <table className="dt"><thead><tr><th>Part</th><th className="num">Produced (OP10)</th><th className="num">Scrap Wt/Pc</th><th className="num">Total Burr (kg)</th></tr></thead>
            <tbody>{rows.map((r, i) => <tr key={i}><td>{r.part_code} · {r.part_name}</td><td className="num">{r.produced}</td><td className="num">{(+r.scrap_wt_pc).toFixed(3)}</td><td className="num"><b>{money(r.total_scrap)}</b></td></tr>)}
              <tr><td colSpan={3} style={{ textAlign: "right", fontWeight: 700 }}>Total</td><td className="num"><b>{money(total)}</b></td></tr></tbody></table>}
      </div>
    </div>
  </div>);
}
