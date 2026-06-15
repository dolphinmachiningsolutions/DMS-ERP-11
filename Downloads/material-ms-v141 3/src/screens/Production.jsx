import React, { useState, useEffect } from "react";
import { supabase, todayISO, toDMY } from "../lib/config";
import { Msg } from "../ui/primitives";

export function Production({ user }) {
  const today = todayISO();
  const [logDate, setLogDate] = useState(today);
  const [shift, setShift] = useState("Day");
  const [sup1, setSup1] = useState(""); const [sup2, setSup2] = useState("");
  const [users, setUsers] = useState([]);
  const [layout, setLayout] = useState([]);   // [{group_id, group_name, machines:[{machine_id,machine,operation}]}]
  const [activeTab, setActiveTab] = useState(null);
  const [parts, setParts] = useState([]); const [lots, setLots] = useState({});
  const [supers, setSupers] = useState([]);
  const [rows, setRows] = useState({});       // key machine_id -> {operator, part_id, lot_id, op10,op20,op30,set,tool,bd,idle,remarks}
  const [msg, setMsg] = useState(null);
  const id = 1000 + Math.floor(Math.random() * 9000); // display-only ticket number
  const isAdmin = user?.role === "admin";
  const minDate = isAdmin ? undefined : new Date(Date.now() - 2 * 86400000).toISOString().slice(0, 10);

  const newDt = () => ({ machine: "", start_time: "", end_time: "", duration_min: "", reason: "", action_taken: "" });
  const newQl = () => ({ machine: "", part_id: "", qty_rejected: "", rejection_type: "Process", defect_type: "", root_cause: "", corrective_action: "" });
  const [downtime, setDowntime] = useState([newDt()]); const [quality, setQuality] = useState([newQl()]);

  useEffect(() => { (async () => {
    const { data: sup } = await supabase.rpc("list_supervisors"); setSupers(sup || []);
    const { data: p } = await supabase.from("part").select("id,part_code,part_name").eq("status", "Active").order("part_code"); setParts(p || []);
    const { data: lay } = await supabase.rpc("production_layout");
    const groups = {};
    (lay || []).forEach(r => {
      if (!groups[r.group_id]) groups[r.group_id] = { group_id: r.group_id, group_name: r.group_name, machines: [] };
      if (r.machine_id) groups[r.group_id].machines.push({ machine_id: r.machine_id, machine: r.machine, operation: r.operation, op10: r.op10_enabled, op20: r.op20_enabled, op30: r.op30_enabled });
    });
    const arr = Object.values(groups); setLayout(arr); if (arr.length) setActiveTab(arr[0].group_id);
  })(); }, []);
  async function createSupervisor() { const n = window.prompt("New supervisor name:"); if (!n) return; await supabase.rpc("create_supervisor", { p_name: n }); const { data } = await supabase.rpc("list_supervisors"); setSupers(data || []); }

  const blankRow = () => ({ operator: "", part_id: "", lot_id: "", lot_alloc: [], op10: "", op20: "", op30: "", set: "", tool: "", bd: "", idle: "", remarks: "" });
  const rowsOf = (mid) => { const a = rows[mid]; return Array.isArray(a) && a.length ? a : [blankRow()]; };
  const rowOf = (mid) => rowsOf(mid)[0];
  const setRowAt = (mid, ri, k, v) => setRows(rs => { const a = [...(Array.isArray(rs[mid]) && rs[mid].length ? rs[mid] : [blankRow()])]; a[ri] = { ...a[ri], [k]: v }; return { ...rs, [mid]: a }; });
  const addSub = (mid) => setRows(rs => { const a = [...(Array.isArray(rs[mid]) && rs[mid].length ? rs[mid] : [blankRow()])]; if (a.length >= 5) return rs; a.push(blankRow()); return { ...rs, [mid]: a }; });
  const delSub = (mid, ri) => setRows(rs => { const a = [...(Array.isArray(rs[mid]) && rs[mid].length ? rs[mid] : [blankRow()])]; if (ri === 0) return rs; a.splice(ri, 1); return { ...rs, [mid]: a }; });
  const setAlloc = (mid, ri, fn) => setRows(rs => { const a = [...(Array.isArray(rs[mid]) && rs[mid].length ? rs[mid] : [blankRow()])]; a[ri] = { ...a[ri], lot_alloc: fn(a[ri].lot_alloc || []) }; return { ...rs, [mid]: a }; });
  const setRow = (mid, k, v) => setRows(s => ({ ...s, [mid]: { ...rowOf(mid), [k]: v } }));
  async function onRowPart(mid, ri, partId) {
    setRowAt(mid, ri, "part_id", partId);
    if (partId) { const { data } = await supabase.rpc("available_lots", { p_part: partId, p_bucket: "CC" }); setLots(prev => ({ ...prev, [partId]: data || [] })); }
  }

  async function save() {
    setMsg(null);
    if (!sup1) return setMsg({ t: "err", m: "Supervisor 1 is required." });
    const rowPayload = [];
    let allocErr = null;
    layout.forEach(g => g.machines.forEach(m => {
      const subs = rowsOf(m.machine_id);
      subs.forEach((r, ri) => {
        if (!r.part_id) return;
        const alloc = (r.lot_alloc || []).filter(a => a.lot_id && +a.qty > 0);
        if (alloc.length) { const tot = alloc.reduce((t, a) => t + (+a.qty || 0), 0); const need = +r.op10 || 0;
          if (tot !== need) { allocErr = `${m.machine}: lot allocation total (${tot}) must equal OP10 (${need}).`; return; } }
        rowPayload.push({ section: g.group_name, machine_no: m.machine, operator: subs[0].operator, part_id: r.part_id,
          lot_id: alloc.length ? null : (r.lot_id || null),
          lot_alloc: alloc.length ? alloc.map(a => ({ lot_id: a.lot_id, lot_no: a.lot_no || null, qty: +a.qty })) : null,
          op10_actual: +r.op10 || 0, op20_actual: +r.op20 || 0, op30_actual: +r.op30 || 0,
          setting_time: ri === 0 ? (+r.set || 0) : 0, tool_change_time: ri === 0 ? (+r.tool || 0) : 0,
          breakdown_time: ri === 0 ? (+r.bd || 0) : 0, idle_time: ri === 0 ? (+r.idle || 0) : 0, remarks: r.remarks || null });
      });
    }));
    if (allocErr) return setMsg({ t: "err", m: allocErr });
    if (!rowPayload.length) return setMsg({ t: "err", m: "Enter at least one machine row with a part." });
    if (!rowPayload.some(r => (r.op10_actual + r.op20_actual + r.op30_actual) > 0)) return setMsg({ t: "err", m: "At least one machine row needs a production quantity (#10/#20/#30)." });
    const dtPayload = downtime.filter(d => d.machine || d.reason).map(d => ({ section: "", machine_no: d.machine, start_time: d.start_time, end_time: d.end_time, duration_min: +d.duration_min || 0, reason: d.reason, action_taken: d.action_taken }));
    const qlPayload = quality.filter(q => q.part_id).map(q => ({ section: "", machine_no: q.machine, part_id: q.part_id, qty_rejected: +q.qty_rejected || 0, rejection_type: q.rejection_type, defect_type: q.defect_type, root_cause: q.root_cause, corrective_action: q.corrective_action }));
    const { error } = await supabase.rpc("post_production", { p_date: logDate, p_shift: shift, p_sup1: sup1, p_sup2: sup2 || null, p_user: user?.username || "system", p_rows: rowPayload, p_downtime: dtPayload, p_quality: qlPayload });
    if (error) return setMsg({ t: "err", m: error.message });
    setMsg({ t: "ok", m: `Production log saved · ${rowPayload.length} machine row(s). OP10 posted to MG.` });
    setRows({}); setDowntime([newDt()]); setQuality([newQl()]); setSup1(""); setSup2("");
  }

  const tab = layout.find(g => g.group_id === activeTab);
  const partOpts = <>{parts.map(p => <option key={p.id} value={p.id}>{p.part_code} · {p.part_name}</option>)}</>;

  return (<div className="wrap prod"><Msg msg={msg} />
    <div className="prod-head">
      <div className="prod-title">▣ Production Log</div>
      <div className="prod-id">ID: {id}</div>
    </div>
    <div className="prod-hdrbar">
      <div className="fld"><label>Log Date <span className="req">*</span></label><input className="ctl" type="date" value={logDate} max={today} min={minDate} onChange={e => setLogDate(e.target.value)} /></div>
      <div className="fld"><label>Shift <span className="req">*</span></label>
        <div className="radios"><label className={shift === "Day" ? "on" : ""}><input type="radio" checked={shift === "Day"} onChange={() => setShift("Day")} />Day</label>
          <label className={shift === "Night" ? "on" : ""}><input type="radio" checked={shift === "Night"} onChange={() => setShift("Night")} />Night</label></div></div>
      <div className="fld"><label>Supervisor 1 <span className="req">*</span></label><div style={{ display: "flex", gap: 6 }}><select className="ctl" value={sup1} onChange={e => setSup1(e.target.value)}><option value="">-- Select --</option>{supers.map(u => <option key={u.id} value={u.name}>{u.name}</option>)}</select><button type="button" className="btn ghost sm" onClick={createSupervisor}>+</button></div></div>
      <div className="fld"><label>Supervisor 2</label><select className="ctl" value={sup2} onChange={e => setSup2(e.target.value)}><option value="">-- Select --</option>{supers.map(u => <option key={u.id} value={u.name}>{u.name}</option>)}</select></div>
      <div style={{ marginLeft: "auto", alignSelf: "flex-end" }}><button className="btn" onClick={save}>✓ Submit</button></div>
    </div>

    {layout.length === 0
      ? <div className="card"><div className="empty">No Production layout yet. Set it up in Administration → Machine Config (create Part Groups + machines).</div></div>
      : <>
        <div className="prod-tabs">{layout.map(g => <button key={g.group_id} className={g.group_id === activeTab ? "active" : ""} onClick={() => setActiveTab(g.group_id)}>{g.group_name}</button>)}</div>
        <div className="prod-gridwrap">
          {!tab || tab.machines.length === 0 ? <div className="empty">No machines configured for this group.</div>
            : <table className="prod-grid"><thead><tr>
              <th>M/C</th><th>Operator</th><th>Part</th><th>Lot (CC)</th>
              <th>#10</th><th>#20</th><th>#30</th><th>Set time</th><th>Tool time</th><th>B/D time</th><th>Idle time</th><th>Remarks</th>
            </tr></thead>
              <tbody>{tab.machines.map(m => { const subs = rowsOf(m.machine_id); return subs.map((r, ri) => (
                <tr key={m.machine_id + "-" + ri}>
                  {ri === 0 && <th className="mc" rowSpan={subs.length}>{m.machine}
                    {subs.length < 5 && <div><button type="button" className="btn ghost sm" style={{ marginTop: 4 }} onClick={() => addSub(m.machine_id)}>+ part</button></div>}
                  </th>}
                  <td>{ri === 0
                    ? <input value={r.operator} onChange={e => setRowAt(m.machine_id, 0, "operator", e.target.value)} />
                    : <span className="muted" style={{ paddingLeft: 6 }}>〃</span>}</td>
                  <td style={{ display: "flex", gap: 4, alignItems: "center" }}>
                    <select value={r.part_id} onChange={e => onRowPart(m.machine_id, ri, e.target.value)}><option value="">--</option>{partOpts}</select>
                    {ri > 0 && <button type="button" title="Remove part row" onClick={() => delSub(m.machine_id, ri)}>✕</button>}
                  </td>
                  <td>
                    {(r.lot_alloc || []).length === 0 && <select value={r.lot_id} onChange={e => setRowAt(m.machine_id, ri, "lot_id", e.target.value)}><option value="">-- Lot --</option>{(lots[r.part_id] || []).map(l => <option key={l.lot_id} value={l.lot_id}>{l.lot_no} ({(+l.available).toFixed(0)})</option>)}</select>}
                    {(r.lot_alloc || []).map((a, ai) => <div key={ai} style={{display:"flex",gap:4,marginTop:2}}>
                      <select value={a.lot_id} onChange={e => { const v = e.target.value; const hit = (lots[r.part_id]||[]).find(x=>x.lot_id===v);
                        setAlloc(m.machine_id, ri, al => al.map((x,mi)=>mi===ai?{...x,lot_id:v,lot_no:hit?hit.lot_no:""}:x)); }}>
                        <option value="">-- Lot --</option>{(lots[r.part_id] || []).map(l => <option key={l.lot_id} value={l.lot_id}>{l.lot_no} ({(+l.available).toFixed(0)})</option>)}</select>
                      <input style={{width:56}} type="number" placeholder="qty" value={a.qty} onChange={e => setAlloc(m.machine_id, ri, al => al.map((x,mi)=>mi===ai?{...x,qty:e.target.value}:x))} />
                      <button type="button" onClick={() => setAlloc(m.machine_id, ri, al => al.filter((_,mi)=>mi!==ai))}>✕</button>
                    </div>)}
                    {r.part_id && <button type="button" className="btn ghost sm" style={{marginTop:2}} onClick={() => { if (!(r.lot_alloc||[]).length && r.lot_id) setRowAt(m.machine_id, ri, "lot_id", ""); setAlloc(m.machine_id, ri, al => [...al, { lot_id: "", lot_no: "", qty: "" }]); }}>+ split lots</button>}
                  </td>
                  <td><input className="num" type="number" value={r.op10} disabled={!m.op10} style={!m.op10 ? { background: "#e9edf2" } : null} onChange={e => setRowAt(m.machine_id, ri, "op10", e.target.value)} /></td>
                  <td><input className="num" type="number" value={r.op20} disabled={!m.op20} style={!m.op20 ? { background: "#e9edf2" } : null} onChange={e => setRowAt(m.machine_id, ri, "op20", e.target.value)} /></td>
                  <td><input className="num" type="number" value={r.op30} disabled={!m.op30} style={!m.op30 ? { background: "#e9edf2" } : null} onChange={e => setRowAt(m.machine_id, ri, "op30", e.target.value)} /></td>
                  <td>{ri === 0 ? <input className="num" type="number" value={r.set} onChange={e => setRowAt(m.machine_id, 0, "set", e.target.value)} /> : <span className="muted">—</span>}</td>
                  <td>{ri === 0 ? <input className="num" type="number" value={r.tool} onChange={e => setRowAt(m.machine_id, 0, "tool", e.target.value)} /> : <span className="muted">—</span>}</td>
                  <td>{ri === 0 ? <input className="num" type="number" value={r.bd} onChange={e => setRowAt(m.machine_id, 0, "bd", e.target.value)} /> : <span className="muted">—</span>}</td>
                  <td>{ri === 0 ? <input className="num" type="number" value={r.idle} onChange={e => setRowAt(m.machine_id, 0, "idle", e.target.value)} /> : <span className="muted">—</span>}</td>
                  <td><input value={r.remarks} onChange={e => setRowAt(m.machine_id, ri, "remarks", e.target.value)} /></td>
                </tr>)); })}</tbody></table>}
        </div>
      </>}

    <div className="prod-sublog">
      <div className="sublog-h dt">⚠ DOWNTIME / BREAKDOWN LOG</div>
      <table className="prod-grid sub"><thead><tr><th>M/C</th><th>Start Time</th><th>End Time</th><th>Duration (Min)</th><th>Reason</th><th>Action Taken</th><th></th></tr></thead>
        <tbody>{downtime.map((d, i) => <tr key={i}>
          <td><input value={d.machine} onChange={e => setDowntime(x => x.map((y, j) => j === i ? { ...y, machine: e.target.value } : y))} /></td>
          <td><input value={d.start_time} onChange={e => setDowntime(x => x.map((y, j) => j === i ? { ...y, start_time: e.target.value } : y))} placeholder="--:--" /></td>
          <td><input value={d.end_time} onChange={e => setDowntime(x => x.map((y, j) => j === i ? { ...y, end_time: e.target.value } : y))} placeholder="--:--" /></td>
          <td><input className="num" type="number" value={d.duration_min} onChange={e => setDowntime(x => x.map((y, j) => j === i ? { ...y, duration_min: e.target.value } : y))} /></td>
          <td><input value={d.reason} onChange={e => setDowntime(x => x.map((y, j) => j === i ? { ...y, reason: e.target.value } : y))} /></td>
          <td><input value={d.action_taken} onChange={e => setDowntime(x => x.map((y, j) => j === i ? { ...y, action_taken: e.target.value } : y))} /></td>
          <td className="del">{downtime.length > 1 && <button onClick={() => setDowntime(x => x.filter((_, j) => j !== i))}>✕</button>}</td>
        </tr>)}</tbody></table>
      <button className="btn ghost sm" style={{ marginTop: 10 }} onClick={() => setDowntime(d => [...d, newDt()])}>+ Add Row</button>
    </div>

    <div className="prod-sublog">
      <div className="sublog-h ql">⊗ QUALITY ISSUES / REJECTIONS LOG</div>
      <table className="prod-grid sub"><thead><tr><th>M/C</th><th>Part Name</th><th>Qty Rej</th><th>Rej Type</th><th>Defect Type</th><th>Root Cause</th><th>Corrective Action</th><th></th></tr></thead>
        <tbody>{quality.map((q, i) => <tr key={i}>
          <td><input value={q.machine} onChange={e => setQuality(x => x.map((y, j) => j === i ? { ...y, machine: e.target.value } : y))} /></td>
          <td><select value={q.part_id} onChange={e => setQuality(x => x.map((y, j) => j === i ? { ...y, part_id: e.target.value } : y))}><option value="">--</option>{partOpts}</select></td>
          <td><input className="num" type="number" value={q.qty_rejected} onChange={e => setQuality(x => x.map((y, j) => j === i ? { ...y, qty_rejected: e.target.value } : y))} /></td>
          <td><select value={q.rejection_type} onChange={e => setQuality(x => x.map((y, j) => j === i ? { ...y, rejection_type: e.target.value } : y))}><option>Process</option><option>Material</option></select></td>
          <td><input value={q.defect_type} onChange={e => setQuality(x => x.map((y, j) => j === i ? { ...y, defect_type: e.target.value } : y))} /></td>
          <td><input value={q.root_cause} onChange={e => setQuality(x => x.map((y, j) => j === i ? { ...y, root_cause: e.target.value } : y))} /></td>
          <td><input value={q.corrective_action} onChange={e => setQuality(x => x.map((y, j) => j === i ? { ...y, corrective_action: e.target.value } : y))} /></td>
          <td className="del">{quality.length > 1 && <button onClick={() => setQuality(x => x.filter((_, j) => j !== i))}>✕</button>}</td>
        </tr>)}</tbody></table>
      <button className="btn ghost sm" style={{ marginTop: 10 }} onClick={() => setQuality(q => [...q, newQl()])}>+ Add Row</button>
    </div>
  </div>);
}
