import React, { useState, useEffect, useMemo, useRef } from "react";
import { supabase, VOUCHERS, toDMY, money } from "../lib/config";
import { Msg } from "../ui/primitives";
import { exportXLSX, exportHTML, exportPDF } from "../lib/exporters";
import "../ui/books2.css";

const FLAGS = [
  ["generated", "Generated"], ["cancelled", "Cancelled"], ["rec_copy", "Received Copy"], ["grn", "GRN"],
  ["gstr1", "GSTR 1"], ["gstr2b", "GSTR 2B"], ["price_approved", "Price Approved"],
];
const ALL_COLS = [
  ["voucher_id_code", "ID", "text"], ["voucher_no", "Voucher Number", "text"], ["voucher_period", "Voucher Period", "text"],
  ["voucher_date", "Voucher Date", "date"], ["posting_period", "Posting Period", "text"], ["posting_date", "Posting Date", "date"],
  ["ledger_name", "Party Name", "text"], ["line_count", "No. of Line Items", "num"], ["total_qty", "Qty", "num"], ["total_value", "Basic Value", "money"], ["status", "Status", "text"],
];
const OPS_BY_KIND = {
  text: [["contains", "contains"], ["eq", "equals"], ["neq", "not equals"], ["starts", "starts with"]],
  num: [["eq", "="], ["gt", ">"], ["lt", "<"], ["gte", "≥"], ["lte", "≤"]],
  money: [["eq", "="], ["gt", ">"], ["lt", "<"], ["gte", "≥"], ["lte", "≤"]],
  date: [["eq", "on"], ["gt", "after"], ["lt", "before"]],
};


export function Books(props) {
  return props.type === "PRODUCTION" ? <ProductionBooks {...props} /> : <BooksInner {...props} />;
}

/* ── Production logs in Books: Log / Summary toggle ── */
function ProductionBooks() {
  const [view, setView] = useState("log");            // log | summary
  const [rows, setRows] = useState([]); const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState(""); const [openId, setOpenId] = useState(null);
  // summary state
  const [sumBy, setSumBy] = useState("part");          // part | machine
  const [sFrom, setSFrom] = useState(""); const [sTo, setSTo] = useState("");
  const [sumRows, setSumRows] = useState([]); const [sumMach, setSumMach] = useState([]); const [sumLoad, setSumLoad] = useState(false);
  const [sumQ, setSumQ] = useState("");
  const [mSort, setMSort] = useState({ k: "machine_no", dir: "asc" });

  useEffect(() => { (async () => { setLoading(true);
    const { data } = await supabase.rpc("list_production_books"); setRows(data || []); setLoading(false); })(); }, []);
  useEffect(() => { if (view!=="summary") return; (async () => { setSumLoad(true);
    const args = { p_from: sFrom || null, p_to: sTo || null };
    const [{ data: a }, { data: m }] = await Promise.all([
      supabase.rpc("production_summary", args), supabase.rpc("production_summary_machines", args)]);
    setSumRows(a || []); setSumMach(m || []); setSumLoad(false); })(); }, [view, sFrom, sTo]);

  const filtered = useMemo(() => { const q = search.trim().toLowerCase(); if (!q) return rows;
    return rows.filter(r => [r.shift, r.supervisor_1, r.supervisor_2, r.created_by, toDMY(r.log_date), r.log_period]
      .some(x => (x || "").toLowerCase().includes(q))); }, [rows, search]);
  const idx = filtered.findIndex(x => x.id === openId); const cur = filtered[idx];

  useEffect(() => { const onKey = (e) => { const tag = (e.target.tagName||"").toLowerCase();
    if (tag==="input"||tag==="select"||tag==="textarea") return;
    if (openId!=null) { if (e.key==="Escape") setOpenId(null);
      else if (e.key==="ArrowLeft" && idx>0) setOpenId(filtered[idx-1].id);
      else if (e.key==="ArrowRight" && idx>=0 && idx<filtered.length-1) setOpenId(filtered[idx+1].id); } };
    window.addEventListener("keydown", onKey); return () => window.removeEventListener("keydown", onKey); });

  const mkCols = a => a.map(([key,label,kind])=>({key,label,kind}));
  const doExport = () => {
    if (view==="log") return exportXLSX("production_logs", mkCols([["log_code","Voucher ID","text"],["log_date","Date","date"],["log_period","Period","text"],["shift","Shift","text"],
      ["supervisor_1","Supervisor 1","text"],["supervisor_2","Supervisor 2","text"],["machine_count","Machines","num"],
      ["total_op10","OP10","num"],["total_op20","OP20","num"],["total_op30","OP30","num"],
      ["downtime_min","Downtime (min)","num"],["rejected_qty","Rejected","num"],["created_by","By","text"]]), filtered);
    if (sumBy==="part") return exportXLSX("production_summary_by_part", mkCols([["part_code","Part Code","text"],["part_name","Part Name","text"],
      ["section","Section","text"],["machine_no","Machine","text"],["op10","OP10","num"],["op20","OP20","num"],["op30","OP30","num"],
      ["days","Days","num"],["rejected","Rejected","num"]]), sumRows);
    return exportXLSX("production_summary_by_machine", mkCols([["section","Section","text"],["machine_no","Machine","text"],["parts","Parts","num"],
      ["op10","OP10","num"],["op20","OP20","num"],["op30","OP30","num"],["downtime_min","Downtime (min)","num"],["rejected","Rejected","num"],["days","Days","num"]]), sumMach);
  };

  /* ── detail page (Log view) ── */
  if (openId!=null && cur) { const ls = Array.isArray(cur.rows)?cur.rows:[];
    const dts = Array.isArray(cur.downtime)?cur.downtime:[]; const qls = Array.isArray(cur.quality)?cur.quality:[];
    return (<div className="bk2"><div className="bk2-full">
      <div className="bk2-full-bar">
        <button className="bk2-back" onClick={()=>setOpenId(null)}>← Back to list</button>
        <div className="bk2-nav">
          <button className="bk2-navbtn" disabled={idx<=0} onClick={()=>setOpenId(filtered[idx-1].id)}>‹ Prev</button>
          <span className="bk2-navpos">{idx+1} / {filtered.length}</span>
          <button className="bk2-navbtn" disabled={idx>=filtered.length-1} onClick={()=>setOpenId(filtered[idx+1].id)}>Next ›</button>
        </div>
        <div className="bk2-full-title"><b>Production · {toDMY(cur.log_date)}</b><span className="sub">{cur.shift||"—"} shift · {cur.supervisor_1}{cur.supervisor_2?` + ${cur.supervisor_2}`:""}</span></div>
      </div>
      <div className="bk2-fields">
        <div className="f"><span className="k">Voucher ID</span><span className="v mono">{cur.log_code||"—"}</span></div>
        <div className="f"><span className="k">Date</span><span className="v">{toDMY(cur.log_date)}</span></div>
        <div className="f"><span className="k">Period</span><span className="v">{cur.log_period||"—"}</span></div>
        <div className="f"><span className="k">Shift</span><span className="v">{cur.shift||"—"}</span></div>
        <div className="f"><span className="k">Entered By</span><span className="v">{cur.created_by||"—"}</span></div>
        <div className="f"><span className="k">Supervisor 1</span><span className="v">{cur.supervisor_1||"—"}</span></div>
        <div className="f"><span className="k">Supervisor 2</span><span className="v">{cur.supervisor_2||"—"}</span></div>
        <div className="f"><span className="k">Machines</span><span className="v mono">{cur.machine_count}</span></div>
        <div className="f"><span className="k">OP10 / OP20 / OP30</span><span className="v mono">{money(cur.total_op10)} / {money(cur.total_op20)} / {money(cur.total_op30)}</span></div>
        <div className="f"><span className="k">Downtime</span><span className="v mono">{money(cur.downtime_min)} min</span></div>
        <div className="f"><span className="k">Rejected</span><span className="v mono">{money(cur.rejected_qty)}</span></div>
      </div>
      <div className="bk2-pbody-full">
        <div className="bk2-licap">Machine rows</div>
        <table className="bk2-det"><thead><tr>
          <th className="l">Section</th><th className="c">Machine</th><th className="l">Operator</th><th className="l">Part</th><th className="l">Lot(s)</th>
          <th>OP10</th><th>OP20</th><th>OP30</th><th>Set time</th><th>Tool time</th><th>B/D time</th><th>Idle time</th><th className="l">Remarks</th>
        </tr></thead><tbody>
          {ls.length===0 ? <tr><td colSpan={13} className="c muted">No machine rows.</td></tr> : ls.map((m,i)=>(
            <tr key={i}>
              <td className="l">{m.section||"—"}</td><td className="c">{m.machine_no||"—"}</td><td className="l">{m.operator||"—"}</td>
              <td className="l name">{m.part_name||m.part_code||"—"}</td>
              <td className="l muted">{Array.isArray(m.lot_alloc)&&m.lot_alloc.length?m.lot_alloc.map(a=>`${a.lot_no||"lot"}×${a.qty}`).join(", "):(m.lot_no||"—")}</td>
              <td>{money(m.op10)}</td><td>{money(m.op20)}</td><td>{money(m.op30)}</td>
              <td>{money(m.setting_time)}</td><td>{money(m.tool_change_time)}</td><td>{money(m.breakdown_time)}</td><td>{money(m.idle_time)}</td>
              <td className="l muted">{m.remarks||"—"}</td>
            </tr>))}
        </tbody></table>
        {dts.length>0 && <><div className="bk2-licap" style={{marginTop:18}}>Downtime</div>
        <table className="bk2-det"><thead><tr>
          <th className="l">Section</th><th className="c">Machine</th><th className="c">Start</th><th className="c">End</th><th>Minutes</th><th className="l">Reason</th><th className="l">Action Taken</th>
        </tr></thead><tbody>
          {dts.map((d,i)=>(<tr key={i}>
            <td className="l">{d.section||"—"}</td><td className="c">{d.machine_no||"—"}</td><td className="c">{d.start_time||"—"}</td><td className="c">{d.end_time||"—"}</td>
            <td>{money(d.duration_min)}</td><td className="l">{d.reason||"—"}</td><td className="l muted">{d.action_taken||"—"}</td>
          </tr>))}
        </tbody></table></>}
        {qls.length>0 && <><div className="bk2-licap" style={{marginTop:18}}>Quality issues</div>
        <table className="bk2-det"><thead><tr>
          <th className="l">Section</th><th className="c">Machine</th><th className="l">Part</th><th>Qty Rejected</th><th className="l">Type</th><th className="l">Defect</th><th className="l">Root Cause</th><th className="l">Corrective Action</th>
        </tr></thead><tbody>
          {qls.map((q,i)=>(<tr key={i}>
            <td className="l">{q.section||"—"}</td><td className="c">{q.machine_no||"—"}</td><td className="l name">{q.part_name||q.part_code||"—"}</td>
            <td>{money(q.qty_rejected)}</td><td className="l">{q.rejection_type||"—"}</td><td className="l">{q.defect_type||"—"}</td>
            <td className="l muted">{q.root_cause||"—"}</td><td className="l muted">{q.corrective_action||"—"}</td>
          </tr>))}
        </tbody></table></>}
      </div>
    </div></div>);
  }

  /* ── toolbar shared ── */
  const Toolbar = (
    <div className="controls">
      <div className="bk2-toggle">
        <button className={view==="log"?"on":""} onClick={()=>setView("log")}>Log</button>
        <button className={view==="summary"?"on":""} onClick={()=>setView("summary")}>Summary</button>
      </div>
      {view==="log" ? (
        <div className="search">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>
          <input placeholder="Search date, shift, supervisor…" value={search} onChange={e=>setSearch(e.target.value)} />
        </div>
      ) : (<>
        <div className="bk2-toggle">
          <button className={sumBy==="part"?"on":""} onClick={()=>setSumBy("part")}>By Part</button>
          <button className={sumBy==="machine"?"on":""} onClick={()=>setSumBy("machine")}>By Machine</button>
        </div>
        <label className="bk2-range">From <input type="date" value={sFrom} onChange={e=>setSFrom(e.target.value)} /></label>
        <label className="bk2-range">To <input type="date" value={sTo} onChange={e=>setSTo(e.target.value)} /></label>
      </>)}
      <button className="btn ghost sm" onClick={doExport}>Export ⤓</button>
    </div>);

  /* ── SUMMARY view ── */
  if (view==="summary") {
    const k = sumMach.reduce((a,m)=>({ op10:a.op10+(+m.op10||0), op20:a.op20+(+m.op20||0), op30:a.op30+(+m.op30||0),
      dt:a.dt+(+m.downtime_min||0), rej:a.rej+(+m.rejected||0) }), {op10:0,op20:0,op30:0,dt:0,rej:0});
    const sq = sumQ.trim().toLowerCase();
    // By Part: filter + group
    const partRows = sumRows.filter(r => !sq || [r.part_code,r.part_name,r.machine_no,r.section].some(x=>(x||"").toLowerCase().includes(sq)));
    const groups = []; let curKey=null;
    partRows.forEach(r=>{ if (r.part_code!==curKey){ groups.push({part_code:r.part_code, part_name:r.part_name, items:[]}); curKey=r.part_code; }
      groups[groups.length-1].items.push(r); });
    // By Machine: filter + sort
    const machRows = [...sumMach.filter(m => !sq || [m.machine_no,m.section].some(x=>(x||"").toLowerCase().includes(sq)))]
      .sort((x,y)=>{ const d=mSort.dir==="asc"?1:-1; let xv=x[mSort.k], yv=y[mSort.k];
        if(["parts","op10","op20","op30","downtime_min","rejected","days"].includes(mSort.k)){xv=+xv||0;yv=+yv||0;}
        else {xv=(xv||"").toString().toLowerCase();yv=(yv||"").toString().toLowerCase();}
        return xv<yv?-d:xv>yv?d:0; });
    const MTh = ({k:kk,label,cls}) => <th className={cls} style={{cursor:"pointer",whiteSpace:"nowrap"}}
      onClick={()=>setMSort(s=>s.k===kk?{k:kk,dir:s.dir==="asc"?"desc":"asc"}:{k:kk,dir:"asc"})}>{label}{mSort.k===kk?(mSort.dir==="asc"?" ▲":" ▼"):""}</th>;
    return (<div className="bk2">{Toolbar}
      <div className="bk2-kpis">
        <div className="kpi"><div className="k">OP10 Machined</div><div className="v">{money(k.op10)}</div></div>
        <div className="kpi"><div className="k">OP20 Machined</div><div className="v">{money(k.op20)}</div></div>
        <div className="kpi"><div className="k">OP30 Machined</div><div className="v">{money(k.op30)}</div></div>
        <div className="kpi"><div className="k">Downtime (min)</div><div className="v warn">{money(k.dt)}</div></div>
        <div className="kpi"><div className="k">Rejected</div><div className="v err">{money(k.rej)}</div></div>
      </div>
      <div className="controls" style={{paddingTop:0}}>
        <div className="search">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>
          <input placeholder="Query: part, machine or section…" value={sumQ} onChange={e=>setSumQ(e.target.value)} />
        </div>
      </div>
      {sumLoad ? <div className="empty">Loading…</div> : sumBy==="part" ? (
        groups.length===0 ? <div className="empty">No production in this range.</div> :
        <div className="tblwrap"><table><thead><tr>
          <th>Part</th><th>Section</th><th className="c">Machine</th><th className="r">OP10</th><th className="r">OP20</th><th className="r">OP30</th><th className="c">Days</th><th className="r">Rejected</th>
        </tr></thead><tbody>
          {groups.map(g=>{ const t=g.items.reduce((a,r)=>({op10:a.op10+(+r.op10||0),op20:a.op20+(+r.op20||0),op30:a.op30+(+r.op30||0),rej:a.rej+(+r.rejected||0)}),{op10:0,op20:0,op30:0,rej:0});
            return (<React.Fragment key={g.part_code}>
              <tr className="bk2-grp"><td colSpan={3}>{g.part_name} <span className="muted">({g.part_code})</span></td>
                <td className="num">{money(t.op10)}</td><td className="num">{money(t.op20)}</td><td className="num">{money(t.op30)}</td><td></td><td className="num">{money(t.rej)}</td></tr>
              {g.items.map((r,ii)=>(<tr key={ii}>
                <td></td><td className="muted">{r.section||"—"}</td><td className="c">{r.machine_no||"—"}</td>
                <td className="num">{money(r.op10)}</td><td className="num">{money(r.op20)}</td><td className="num">{money(r.op30)}</td>
                <td className="c">{r.days}</td><td className="num">{money(r.rejected)}</td></tr>))}
            </React.Fragment>); })}
        </tbody></table></div>
      ) : (
        machRows.length===0 ? <div className="empty">No production in this range.</div> :
        <div className="tblwrap"><table><thead><tr>
          <MTh k="section" label="Section" /><MTh k="machine_no" label="Machine" cls="c" /><MTh k="parts" label="Parts" cls="c" /><MTh k="op10" label="OP10" cls="r" /><MTh k="op20" label="OP20" cls="r" /><MTh k="op30" label="OP30" cls="r" /><MTh k="downtime_min" label="Downtime (min)" cls="r" /><MTh k="rejected" label="Rejected" cls="r" /><MTh k="days" label="Days" cls="c" />
        </tr></thead><tbody>
          {machRows.map((m,ii)=>(<tr key={ii}>
            <td>{m.section||"—"}</td><td className="c">{m.machine_no||"—"}</td><td className="c">{m.parts}</td>
            <td className="num">{money(m.op10)}</td><td className="num">{money(m.op20)}</td><td className="num">{money(m.op30)}</td>
            <td className="num">{money(m.downtime_min)}</td><td className="num">{money(m.rejected)}</td><td className="c">{m.days}</td></tr>))}
        </tbody></table></div>)}
    </div>);
  }

  /* ── LOG view ── */
  return (<div className="bk2">{Toolbar}
    {loading ? <div className="empty">Loading…</div> : filtered.length===0 ? <div className="empty">No production logs.</div> : (
    <div className="tblwrap"><table className="bk2-outer"><thead><tr>
      <th>Voucher ID</th><th>Voucher Period</th><th>Voucher Date</th><th className="c">No. of Line Items</th>
    </tr></thead><tbody>
      {filtered.map(r=>(
        <tr key={r.id} className="vrow" onClick={()=>setOpenId(r.id)}>
          <td className="id">{r.log_code||"—"}</td>
          <td className="muted">{r.log_period||"—"}</td>
          <td>{toDMY(r.log_date)}</td>
          <td className="c"><span className="badge-n">{r.machine_count}</span></td>
        </tr>))}
    </tbody></table></div>)}
  </div>);
}

function BooksInner({ type, user, onEdit }) {
  const def = VOUCHERS[type];
  const [rows, setRows] = useState([]); const [loading, setLoading] = useState(true); const [msg, setMsg] = useState(null);
  const [cfg, setCfg] = useState(null);            // column config from settings (null=all)
  const [search, setSearch] = useState("");
  const [sortKey, setSortKey] = useState("voucher_date"); const [sortDir, setSortDir] = useState("desc");
  const [hidden, setHidden] = useState({}); const [showCols, setShowCols] = useState(false);
  const [picks, setPicks] = useState({});          // {colKey: Set(selected values)} — excel funnel
  const [openFunnel, setOpenFunnel] = useState(null);
  const [conds, setConds] = useState([]); const [showQuery, setShowQuery] = useState(false);
  const [openId, setOpenId] = useState(null); const [detail, setDetail] = useState(null); const [loadingD, setLoadingD] = useState(false);
  const [fulfil, setFulfil] = useState([]);   // PO/SO/DC received/pending for the open record
  const [selIdx, setSelIdx] = useState(-1); // keyboard-highlighted row in the list
  const [showExport, setShowExport] = useState(false);
  const canMark = user?.role === "admin" || user?.role === "can_edit";
  const [rights, setRights] = useState(null); // {can_edit, can_markdel, can_markedit} for Books
  useEffect(() => { (async () => {
    if (!user?.id) { setRights(null); return; }
    if (user.role === "admin") { setRights({ can_edit: true, can_markdel: true, can_markedit: true }); return; }
    const { data } = await supabase.rpc("get_module_rights", { p_user: user.id });
    const b = (data || []).find(r => r.module === "Books");
    setRights(b ? { can_edit: !!b.can_edit, can_markdel: !!b.can_markdel, can_markedit: !!b.can_markedit }
                : { can_edit: canMark, can_markdel: canMark, can_markedit: canMark });
  })(); }, [user?.id, user?.role]);
  const allowEdit = (user?.role === "admin");          // spec: Edit only by admin
  const allowMarkDel = true;                            // spec: Mark for Cancellation by all users
  const allowMarkEdit = true;                           // spec: Mark for Edit by all users

  async function load() { setLoading(true); const { data } = await supabase.rpc("list_vouchers_full", { p_type: type }); setRows(data || []); setLoading(false); }
  useEffect(() => { load(); setOpenId(null); setDetail(null); setPicks({}); setConds([]); setSearch(""); }, [type]);
  useEffect(() => { (async () => {
    const { data } = await supabase.rpc("get_column_config", { p_type: type });
    if (data && data.length) { const h = {}; data.forEach(c => { if (!c.visible) h[c.col_key] = true; }); setHidden(h); setCfg(data); } else setCfg([]);
  })(); }, [type]);

  // columns to use (respect config order if present)
  const COLS = useMemo(() => {
    if (cfg && cfg.length) {
      const known = Object.fromEntries(ALL_COLS.map(c => [c[0], c]));
      return cfg.filter(c => known[c.col_key]).sort((a,b)=>a.sort_order-b.sort_order).map(c => known[c.col_key]);
    }
    return ALL_COLS;
  }, [cfg]);

  async function toggle(id, field, val) {
    if (field==="cancelled" && val && !window.confirm("Cancel this voucher? This CANNOT be undone.")) return;
    const { error } = await supabase.rpc("set_doc_flag", { p_id: id, p_field: field, p_val: val, p_user: user?.username || null });
    if (error) return setMsg({ t: "err", m: error.message });
    setRows(rs => rs.map(r => r.id === id ? { ...r, [field]: field === "approved_mgmt" ? (val ? "APPROVED" : "PENDING") : val } : r));
  }
  async function mark(id, markType) {
    const reason = window.prompt(`Reason for ${markType} request:`); if (!reason) return;
    const { data, error } = await supabase.rpc("mark_record", { p_id: id, p_mark: markType, p_reason: reason, p_user: user?.username, p_role: user?.role || "user" });
    if (error) return setMsg({ t: "err", m: error.message }); if (!data?.ok) return setMsg({ t: "err", m: data?.msg }); setMsg({ t: "ok", m: data.msg }); load();
  }
  async function openRow(id) {
    if (openId === id) { setOpenId(null); setDetail(null); return; }
    setOpenId(id); setLoadingD(true);
    const { data } = await supabase.rpc("voucher_detail", { p_id: id }); setDetail(data); setLoadingD(false);
    if (["PURCHASE_ORDER","SALES_ORDER","DC_OUT_JW","DC_OUT_RET","DC_OUT_REPLACE","DC_OUT_NONRET"].includes(type)) {
      const vno = (rows.find(x=>x.id===id)||{}).voucher_no;
      const { data: od } = await supabase.rpc("open_documents");
      setFulfil((od||[]).filter(d=>d.voucher_no===vno));
    } else setFulfil([]);
  }

  const cellRaw = (r, k) => { const kind = (ALL_COLS.find(c=>c[0]===k)||[])[2]; if (kind==="date") return toDMY(r[k]); return r[k]; };
  const distinctVals = (k) => {
    const set = new Set(); rows.forEach(r => set.add(String(cellRaw(r,k) ?? ""))); return [...set].sort();
  };
  function condMatch(r, c) {
    let v = r[c.field]; const kind = c.kind;
    if (kind === "num" || kind === "money") { const a=+v||0,b=+c.value||0; return c.op==="eq"?a===b:c.op==="gt"?a>b:c.op==="lt"?a<b:c.op==="gte"?a>=b:a<=b; }
    if (kind === "date") { const a=v?new Date(v).getTime():0,b=c.value?new Date(c.value).getTime():0; return c.op==="eq"?a===b:c.op==="gt"?a>b:a<b; }
    const s=String(v??"").toLowerCase(), t=String(c.value).toLowerCase();
    return c.op==="contains"?s.includes(t):c.op==="eq"?s===t:c.op==="neq"?s!==t:s.startsWith(t);
  }

  const filtered = useMemo(() => {
    let r = [...rows];
    // search across visible cols
    if (search.trim()) { const q=search.toLowerCase(); r=r.filter(x=>COLS.some(([k])=>String(cellRaw(x,k)??"").toLowerCase().includes(q))); }
    // excel funnel picks
    Object.entries(picks).forEach(([k,set]) => { if (set && set.size) r = r.filter(x => set.has(String(cellRaw(x,k)??""))); });
    // advanced query (AND)
    conds.filter(c=>c.value!=="").forEach(c => { r = r.filter(x => condMatch(x,c)); });
    r.sort((a,b)=>{ const av=a[sortKey],bv=b[sortKey]; if(av==null)return 1; if(bv==null)return -1; const c=av>bv?1:av<bv?-1:0; return sortDir==="asc"?c:-c; });
    return r;
  }, [rows, search, picks, conds, sortKey, sortDir, COLS]);

  const sumQty = filtered.reduce((s,r)=>s+(+r.total_qty||0),0);
  const sumVal = filtered.reduce((s,r)=>s+(+r.total_value||0),0);
  const visCols = COLS.filter(([k])=>!hidden[k]);
  const visFlags = FLAGS.filter(([k])=>!hidden[k]);
  function sortBy(k){ if(sortKey===k) setSortDir(d=>d==="asc"?"desc":"asc"); else {setSortKey(k);setSortDir("asc");} }

  // per-line package aggregate (No. of Packages / Token list / Weighted Qty / Net Wt)
  const pkgAgg = (l) => { const pk = Array.isArray(l.packages)?l.packages:[];
    return { count: pk.length, tokens: pk.map(p=>p.token_ref).filter(t=>t!==""&&t!=null).join(", "),
      wqty: pk.reduce((s,p)=>s+(+p.qty||0),0), nwt: pk.reduce((s,p)=>s+(+p.net_weight||0),0) }; };
  // voucher-level package aggregate across all its lines
  const vPkg = (r) => { const ls = Array.isArray(r.lines)?r.lines:[]; let c=0,wq=0,nw=0; const toks=[];
    ls.forEach(l=>{ const a=pkgAgg(l); c+=a.count; wq+=a.wqty; nw+=a.nwt; if(a.tokens) toks.push(a.tokens); });
    return { count:c, tokens:toks.join(", "), wqty:wq, nwt:nw }; };
  const SINGLE_TYPES = ["SALES_LOCAL", "DC_OUT_JW", "RC_IN_JW"];
  const isSingle = SINGLE_TYPES.includes(type);
  const single = isSingle ? filtered : [];
  const multi = isSingle ? [] : filtered;
  // ── per-voucher-type column & flag analysis ──
  const FIN_TYPES = ["PURCHASE_ORDER","PURCHASE","SALES_ORDER","SALES_LOCAL","CREDIT_NOTE","DEBIT_NOTE_RC","DEBIT_NOTE_DN","SCRAP_SALES"];
  const GST_TYPES = ["PURCHASE","SALES_LOCAL","SCRAP_SALES","CREDIT_NOTE","DEBIT_NOTE_RC","DEBIT_NOTE_DN"];
  const REC_TYPES = ["SALES_LOCAL","SCRAP_SALES","DEBIT_NOTE_RC","DEBIT_NOTE_DN","DC_OUT_JW"];
  const isFin = FIN_TYPES.includes(type);
  const hasParty = !!def.ledger;
  const isLB = type === "SALES_LOCAL";
  const NO_STATUS = ["PROCESS_REJECTION","MATERIAL_REJECTION"].includes(type);
  // spec: Status derived from checkboxes — Cancelled > Alert (not generated within 24h) > Closed > Generated > Open
  const statusChip = (r) => {
    if (r.cancelled) return <span className="st cancel"><span className="bar"></span>Cancelled</span>;
    if (!r.generated && r.created_at && (Date.now() - new Date(r.created_at).getTime()) > 24*3600*1000)
      return <span className="st alert"><span className="bar"></span>Alert</span>;
    if (type==="SALES_LOCAL" && !r.grn && r.voucher_date) {
      const vd = new Date(r.voucher_date); const dl = new Date(vd.getFullYear(), vd.getMonth()+1, 20); // 20th of next month
      if (new Date() > dl) return <span className="st alert"><span className="bar"></span>Alert</span>;
    }
    if (r.status === "CLOSED") return <span className="st closed"><span className="bar"></span>Closed</span>;
    if (r.generated) return <span className="st gen"><span className="bar"></span>Generated</span>;
    return <span className="st open"><span className="bar"></span>Open</span>;
  };
  const TYPE_FLAGS = FLAGS.filter(([k]) => {
    if (k==="grn") return type==="SALES_LOCAL";   // spec: GRN for Sales only
    if (k==="gstr1" || k==="gstr2b") return GST_TYPES.includes(type);
    if (k==="rec_copy") return REC_TYPES.includes(type);
    if (k==="price_approved") return isFin;
    return true;
  });

  // ── keyboard shortcuts: Esc back · ←/→ prev/next · ↑/↓ select · Enter open · Ctrl+E export ──
  useEffect(() => {
    const onKey = (e) => {
      const tag = (e.target.tagName||"").toLowerCase();
      if (tag==="input" || tag==="select" || tag==="textarea") return;
      if (e.ctrlKey && (e.key==="e"||e.key==="E")) { e.preventDefault(); doExport("xlsx","shown"); return; }
      const navL = filtered;
      if (openId!=null) { // detail view
        const idx = navL.findIndex(x=>x.id===openId);
        if (e.ctrlKey && e.shiftKey && (e.key==="c"||e.key==="C")) { e.preventDefault();
          const r = navL[idx]; if (r && !r.cancelled) mark(r.id, "delete"); return; }
        const rr = navL[idx];
        if (rr && e.ctrlKey && !e.shiftKey && !e.metaKey && (e.key==="g"||e.key==="G")) { e.preventDefault(); if (!rr.cancelled && canMark) toggle(rr.id, "generated", !rr.generated); return; }
        if (rr && e.ctrlKey && !e.shiftKey && !e.metaKey && (e.key==="d"||e.key==="D")) { e.preventDefault(); if (!rr.cancelled) toggle(rr.id, "cancelled", true); return; }
        if (e.key==="Escape") { setOpenId(null); setDetail(null); }
        else if (e.key==="ArrowLeft" && idx>0) openRow(navL[idx-1].id);
        else if (e.key==="ArrowRight" && idx>=0 && idx<navL.length-1) openRow(navL[idx+1].id);
        return;
      }
      if (e.key==="ArrowDown") { e.preventDefault(); setSelIdx(i=>Math.min((i<0?-1:i)+1, navL.length-1)); }
      else if (e.key==="ArrowUp") { e.preventDefault(); setSelIdx(i=>Math.max(i-1, 0)); }
      else if (e.key==="Enter" && selIdx>=0 && navL[selIdx]) openRow(navL[selIdx].id);
      else if (e.key==="Escape") setSelIdx(-1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const flagCell = (r,k) => k==="price_approved"
    ? (r.price_approved==="PENDING" ? <span className="dash" style={{color:"var(--warn,#c80)"}}>● pending</span> : <span className="tick">✓</span>)
    : (k==="approved_mgmt" ? r.approved_mgmt==="APPROVED" : !!r[k]) ? <span className="tick">✓</span> : <span className="dash">–</span>;
  const partyLabel = (def.ledger||"").startsWith("Vendor") ? "Vendor Name" : def.ledger==="Customer" ? "Customer Name" : "Party Name";
  const hasPosting = Array.isArray(def.header) && def.header.includes("posting_date");
  // mockup-style flag cell: price_approved → read-only OK/PEND pill; others → clickable square check
  const bk2Flag = (r,k) => {
    if(k==="price_approved") return r.price_approved==="PENDING" ? <span className="pa pending">PEND</span> : <span className="pa ok">OK</span>;
    const on = k==="approved_mgmt" ? r.approved_mgmt==="APPROVED" : !!r[k];
    let editable = !r.cancelled && canMark;
    if (k==="cancelled") editable = !r.cancelled;       // anyone may ATTEMPT; engine enforces allowed users; once on, locked forever
    if (k==="generated" && r.cancelled) editable = false;
    return <span className={"ck"+(on?" on":"")+(editable?" ckbtn":"")}
      onClick={editable ? (e)=>{ e.stopPropagation(); toggle(r.id, k, !on); } : undefined}
      role={editable?"button":undefined} title={editable?"Click to toggle":undefined}></span>;
  };
  // header cell with sort + excel-style funnel popup
  const Th = ({ col, label, cls }) => (
    <th className={cls||""}>
      <div className="bk2-th">
        <span className="bk2-thlbl" onClick={()=>sortBy(col)}>{label}{sortKey===col?(sortDir==="asc"?" ▲":" ▼"):""}</span>
        <span className={"bk2-fn"+(picks[col]&&picks[col].size?" on":"")} onClick={(e)=>{e.stopPropagation();setOpenFunnel(openFunnel===col?null:col);}}>▾</span>
      </div>
      {openFunnel===col && <FunnelMenu values={distinctVals(col)} selected={picks[col]}
        onApply={(set)=>{setPicks(p=>({...p,[col]:set}));setOpenFunnel(null);}}
        onClear={()=>{setPicks(p=>{const n={...p};delete n[col];return n;});setOpenFunnel(null);}}
        onClose={()=>setOpenFunnel(null)} />}
    </th>);

  // export
  function doExport(fmt, scope) {
    const base = scope==="full" ? [...ALL_COLS, ...TYPE_FLAGS.map(f=>[f[0],f[1],"bool"])] : [...visCols, ...visFlags.map(f=>[f[0],f[1],"bool"])];
    const baseCols = [...base, ["remarks","Remarks","text"]].map(c=>c[0]==="price_approved"?[c[0],c[1],"text"]:c);
    const data = scope==="full" ? rows : filtered;
    const fmtRow = (r)=>{ const o={...r};
      if(o.approved_mgmt!==undefined) o.approved_mgmt = o.approved_mgmt==="APPROVED";
      if(o.price_approved!==undefined) o.price_approved = o.price_approved==="PENDING" ? "Pending" : "Approved";
      return o; };
    let ecols, erows;
    if (scope==="full") {
      // include line items in full: main row, then one row per line item beneath
      const liCols = [
        ["li_sno","  Line #","text"],["li_part","  Part Name","text"],["li_ref","  Ref No","text"],
        ["li_invqty","  Inv Qty","num"],["li_actqty","  Act Qty","num"],["li_uom","  UOM","text"],
        ["li_unit","  Unit Price","money"],["li_po","  PO Price","money"],["li_value","  Basic Value","money"],
        ["li_pkgs","  No. of Packages","num"],["li_tokens","  Token Ref. No.","text"],["li_wqty","  Weighted Qty","num"],["li_nwt","  Net Wt","num"],
      ];
      ecols = [...baseCols, ...liCols].map(c=>({key:c[0],label:c[1],kind:c[2]}));
      erows = [];
      data.forEach(r=>{
        erows.push(fmtRow(r));
        const ls = Array.isArray(r.lines)?r.lines:[];
        // single-line types already show their one line on the main row; only expand true multi-line
        if (!SINGLE_TYPES.includes(type) && ls.length>0) {
          ls.forEach(l=>{ const a=pkgAgg(l);
            erows.push({ __sub:true, li_sno:l.sno, li_part:l.part_name||l.part_code, li_ref:l.ref_no,
              li_invqty:l.invoice_qty, li_actqty:l.actual_qty, li_uom:l.uom, li_unit:l.unit_price, li_po:l.po_price, li_value:l.basic_value,
              li_pkgs:a.count, li_tokens:a.tokens, li_wqty:a.wqty, li_nwt:a.nwt }); });
        }
      });
    } else {
      ecols = baseCols.map(c=>({key:c[0],label:c[1],kind:c[2]}));
      erows = data.map(fmtRow);
    }
    const title = "Books — " + def.label;
    const fname = "books_" + type.toLowerCase();
    if (fmt==="xlsx") exportXLSX(fname, ecols, erows);
    else if (fmt==="html") exportHTML(fname, title, ecols, erows);
    else exportPDF(title, ecols, erows);
    setShowExport(false);
  }

  const addCond=()=>setConds(cs=>[...cs,{field:"voucher_no",kind:"text",op:"contains",value:""}]);
  const setCond=(i,p)=>setConds(cs=>cs.map((c,j)=>j===i?{...c,...p}:c));
  const colSpan = visCols.length + visFlags.length + 2;
  const activeFilters = Object.values(picks).filter(s=>s&&s.size).length + conds.filter(c=>c.value!=="").length + (search?1:0);
  const pendingCount = filtered.filter(r=>r.price_approved==="PENDING").length;

  return (<div className="bk2"><Msg msg={msg} />
    {openId==null && <div className="controls">
      <div className="search">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>
        <input placeholder="Search voucher, party or part…" value={search} onChange={e=>setSearch(e.target.value)} />
      </div>
      <span className="lnk" onClick={()=>setShowQuery(s=>!s)}>Advanced Query{conds.length?` (${conds.length})`:""}</span>
      {activeFilters>0 && <span className="lnk" onClick={()=>{setPicks({});setConds([]);setSearch("");}}>Clear {activeFilters}</span>}
      <div style={{position:"relative"}}>
        <span className="lnk dark" onClick={()=>setShowExport(s=>!s)}>Export</span>
        {showExport && <div className="bk2-menu">
          <div className="grp">As shown ({filtered.length})</div>
          <button onClick={()=>doExport("xlsx","shown")}>Excel (.xlsx)</button>
          <button onClick={()=>doExport("html","shown")}>HTML</button>
          <button onClick={()=>doExport("pdf","shown")}>PDF</button>
          <div className="grp">Full + line items ({rows.length})</div>
          <button onClick={()=>doExport("xlsx","full")}>Excel (.xlsx)</button>
          <button onClick={()=>doExport("html","full")}>HTML</button>
          <button onClick={()=>doExport("pdf","full")}>PDF</button>
        </div>}
      </div>
    </div>}

    {openId==null && showQuery && <div className="bk2-query">
      {conds.length===0 && <div className="muted" style={{padding:"4px 0"}}>No conditions. All conditions are combined with AND.</div>}
      {conds.map((c,i)=>{ const ops=OPS_BY_KIND[c.kind]||OPS_BY_KIND.text;
        return <div className="bk2-cond" key={i}>
          <select value={c.field} onChange={e=>{const nf=ALL_COLS.find(f=>f[0]===e.target.value); setCond(i,{field:nf[0],kind:nf[2],op:OPS_BY_KIND[nf[2]][0][0],value:""});}}>
            {ALL_COLS.map(f=><option key={f[0]} value={f[0]}>{f[1]}</option>)}</select>
          <select value={c.op} onChange={e=>setCond(i,{op:e.target.value})}>{ops.map(o=><option key={o[0]} value={o[0]}>{o[1]}</option>)}</select>
          <input type={c.kind==="date"?"date":(c.kind==="num"||c.kind==="money")?"number":"text"} value={c.value} onChange={e=>setCond(i,{value:e.target.value})}/>
          <span className="lnk" onClick={()=>setConds(cs=>cs.filter((_,j)=>j!==i))}>✕</span>
        </div>; })}
      <span className="lnk" onClick={addCond}>+ Add condition</span>
    </div>}

    {loading ? <div className="empty">Loading…</div> : filtered.length===0 ? <div className="empty">No vouchers.</div> : openId!=null ? (()=>{ const navList = filtered; const idx = navList.findIndex(x=>x.id===openId); const r = navList[idx] || {}; const lines=(detail&&detail.lines)||r.lines||[]; const vp=vPkg(r);
      const goPrev = ()=>{ if(idx>0) openRow(navList[idx-1].id); };
      const goNext = ()=>{ if(idx>=0 && idx<navList.length-1) openRow(navList[idx+1].id); };
      return (
      <div className="bk2-full">
        <div className="bk2-full-bar">
          <button className="bk2-back" onClick={()=>{setOpenId(null);setDetail(null);}}>← Back to list</button>
          <div className="bk2-nav">
            <button className="bk2-navbtn" disabled={idx<=0} onClick={goPrev}>‹ Prev</button>
            <span className="bk2-navpos">{idx>=0?idx+1:"–"} / {navList.length}</span>
            <button className="bk2-navbtn" disabled={idx<0||idx>=navList.length-1} onClick={goNext}>Next ›</button>
          </div>
          <div className="bk2-full-title"><b>{r.voucher_no}</b><span className="sub">{def.label} · {r.ledger_name||"—"} · {toDMY(r.voucher_date)}</span></div>
          <div className="bk2-full-acts">
            {allowEdit && <button onClick={()=>onEdit&&onEdit(r.id)}>✎ Edit</button>}
            {!r.cancelled && allowMarkEdit && <button onClick={()=>mark(r.id,"modify")}>✐ Mark for Edit</button>}
            {!r.cancelled && allowMarkDel && <button onClick={()=>mark(r.id,"delete")}>🗑 Mark for Cancellation</button>}
          </div>
        </div>

        <div className="bk2-fields">
          <div className="f"><span className="k">ID</span><span className="v mono">{r.voucher_id_code}</span></div>
          <div className="f"><span className="k">Voucher No</span><span className="v">{r.voucher_no}</span></div>
          <div className="f"><span className="k">Voucher Period</span><span className="v">{r.voucher_period||"—"}</span></div>
          <div className="f"><span className="k">Voucher Date</span><span className="v">{toDMY(r.voucher_date)}</span></div>
          <div className="f"><span className="k">Vehicle Number</span><span className="v">{r.vehicle_no||"—"}</span></div>
          {["PURCHASE_ORDER","SALES_ORDER","DC_OUT_JW","DC_OUT_RET","DC_OUT_REPLACE","DC_OUT_NONRET"].includes(type) &&
            <div className="f"><span className="k">{["DC_OUT_JW","DC_OUT_RET","DC_OUT_REPLACE","DC_OUT_NONRET"].includes(type)?"Due Date":"Valid Through"}</span><span className="v">{r.valid_thru?toDMY(r.valid_thru):"—"}</span></div>}
          {hasPosting && <div className="f"><span className="k">Posting Period</span><span className="v">{r.posting_period||"—"}</span></div>}
          {hasPosting && <div className="f"><span className="k">Posting Date</span><span className="v">{r.posting_date?toDMY(r.posting_date):"—"}</span></div>}
          {hasParty && <div className="f"><span className="k">{partyLabel}</span><span className="v">{r.ledger_name||"—"}</span></div>}
          <div className="f"><span className="k">No. of Line Items</span><span className="v">{r.line_count??0}</span></div>
          <div className="f"><span className="k">Sum Qty</span><span className="v mono">{money(r.total_qty)}</span></div>
          {isFin && <div className="f"><span className="k">Basic Value</span><span className="v mono">₹ {money(r.total_value)}</span></div>}
          <div className="f"><span className="k">Status</span><span className="v">{statusChip(r)}</span></div>
          <div className="f"><span className="k">No. of Packages</span><span className="v mono">{vp.count||0}</span></div>
          <div className="f wide"><span className="k">Remarks</span><span className="v">{r.remarks||"—"}</span></div>
        </div>

        <div className="bk2-flags">
          {TYPE_FLAGS.map(([k,l])=>(
            <label key={k} className="bk2-flag">{bk2Flag(r,k)}<span>{l}</span></label>
          ))}
        </div>

        <div className="bk2-pbody-full">
          <div className="bk2-licap">Line items</div>
          {loadingD ? <div className="empty">Loading…</div> : <PanelLineItems lines={lines} pkgAgg={pkgAgg} vtype={type} />}
          {["PURCHASE_ORDER","SALES_ORDER","DC_OUT_JW","DC_OUT_RET","DC_OUT_REPLACE","DC_OUT_NONRET"].includes(type) && fulfil.length>0 && <>
            <div className="bk2-licap" style={{marginTop:18}}>Fulfilment</div>
            <table className="bk2-det"><thead><tr><th className="l">Part</th><th>Order Qty</th><th>Received</th><th>Pending</th><th>Completion %</th></tr></thead>
            <tbody>{fulfil.map((d,di)=>(<tr key={di}>
              <td className="l name">{d.part_code||"—"}</td><td>{money(d.order_qty)}</td><td>{money(d.received)}</td>
              <td>{money(d.pending)}</td><td>{d.completion_pct!=null?(+d.completion_pct).toFixed(1)+"%":"—"}</td>
            </tr>))}</tbody></table>
          </>}
        </div>
      </div>
      ); })() : (<>
      {/* ════ OUTER PAGE (spec): one uniform single-page grid ════ */}
      <div className="tblwrap">
        <table className="bk2-outer"><thead><tr>
          <Th col="voucher_id_code" label="Voucher ID" />
          {!NO_STATUS && <Th col="voucher_no" label="Voucher Number" />}
          <Th col="voucher_period" label="Voucher Period" />
          <Th col="voucher_date" label="Voucher Date" />
          {hasParty && <Th col="ledger_name" label={partyLabel} />}
          <Th col="line_count" label="No. of Line Items" cls="c" />
          {!NO_STATUS && <th className="c">Status</th>}
        </tr></thead><tbody>
          {filtered.map((r,i)=>(
            <tr key={r.id} className={"vrow"+(i===selIdx?" ksel":"")} onClick={()=>openRow(r.id)}>
              <td className="id">{r.voucher_id_code}</td>
              {!NO_STATUS && <td className="vno">{r.voucher_no}</td>}
              <td className="muted">{r.voucher_period||"—"}</td>
              <td>{toDMY(r.voucher_date)}</td>
              {hasParty && <td>{r.ledger_name||"—"}</td>}
              <td className="c"><span className="badge-n">{r.line_count??0}</span></td>
              {!NO_STATUS && <td className="c">{statusChip(r)}</td>}
            </tr>))}
        </tbody></table>
      </div>
    </>)}
  </div>);
}

/* line items table inside the detail panel */
function PanelLineItems({ lines, pkgAgg, vtype }) {
  const ls = Array.isArray(lines) ? lines : [];
  const lotsTxt = (l) => Array.isArray(l.lot_alloc) && l.lot_alloc.length ? l.lot_alloc.map(a=>`${a.lot_no||"lot"}×${a.qty}`).join(", ") : "—";
  const FIN_SET = new Set(["PURCHASE_ORDER","PURCHASE","SALES_ORDER","SALES_LOCAL","CREDIT_NOTE","DEBIT_NOTE_RC","DEBIT_NOTE_DN","SCRAP_SALES"]);
  let tQ=0,tV=0,tP=0,tW=0,tN=0,tWt=0;
  let tIQ=0;
  ls.forEach(l=>{ const a=pkgAgg(l); tQ+=(+l.actual_qty||+l.qty||0); tIQ+=(+l.invoice_qty||+l.qty||0); tV+=(+l.basic_value||0); tP+=a.count; tW+=a.wqty; tN+=a.nwt; tWt+=(+l.weight||0); });
  return (<table className="bk2-det"><thead><tr>
    <th className="c">Line</th><th className="l">Part Name</th><th className="l">Ref No</th>
    {vtype==="PURCHASE" ? <><th>Inv Qty</th><th>Act Qty</th></> : <th>Qty</th>}
    <th className="c">UOM</th>
    {["PROCESS_REJECTION","MATERIAL_REJECTION"].includes(vtype) && <><th>Weight</th><th className="l">Defect</th></>}
    {FIN_SET.has(vtype) && <><th>Unit Price</th><th>PO Price</th><th>Basic Value</th></>}
    <th className="c">Pkgs</th><th className="c">Token</th><th>Wt Qty</th><th>Net Wt</th><th className="l">Lots</th>
  </tr></thead><tbody>
    {ls.length===0 ? <tr><td colSpan={18} className="c muted">No line items.</td></tr>
      : ls.map((l,i)=>{ const a=pkgAgg(l); return (<tr key={i}>
        <td className="c">{l.sno||i+1}</td><td className="name">{l.part_name||l.part_code||"—"}</td><td className="l muted">{l.ref_no||"—"}</td>
        {vtype==="PURCHASE" ? <><td>{money(+l.invoice_qty||+l.qty||0)}</td><td>{money(+l.actual_qty||+l.qty||0)}</td></> : <td>{money(+l.qty||+l.actual_qty||0)}</td>}
        <td className="c muted">{l.uom||"—"}</td>
        {["PROCESS_REJECTION","MATERIAL_REJECTION"].includes(vtype) && <><td>{money(l.weight)}</td><td className="l muted">{l.defect_type||"—"}</td></>}
        {FIN_SET.has(vtype) && <><td>{money(l.unit_price)}</td><td>{money(l.po_price)}</td><td>{money(l.basic_value)}</td></>}
        <td className="c">{a.count||(+l.pkg_count||0)||"—"}</td><td className="c muted">{a.tokens||"—"}</td><td>{a.count?money(a.wqty):"—"}</td><td>{a.count?a.nwt.toFixed(3):"—"}</td><td className="l muted">{lotsTxt(l)}</td>
      </tr>); })}
  </tbody>
    {ls.length>0 && <tfoot><tr><td className="l" colSpan={3}>Total</td>
      {vtype==="PURCHASE" ? <><td>{money(tIQ)}</td><td>{money(tQ)}</td></> : <td>{money(tQ)}</td>}
      <td></td>
      {["PROCESS_REJECTION","MATERIAL_REJECTION"].includes(vtype) && <><td>{money(tWt)}</td><td></td></>}
      {FIN_SET.has(vtype) && <><td></td><td></td><td>{money(tV)}</td></>}
      <td className="c">{money(tP)}</td><td></td><td>{money(tW)}</td><td>{tN.toFixed(3)}</td><td></td></tr></tfoot>}
  </table>);
}

/* Excel-style funnel: distinct values with checkboxes */
function FunnelMenu({ values, selected, onApply, onClear, onClose }) {
  const [sel, setSel] = useState(() => new Set(selected && selected.size ? selected : values));
  const [q, setQ] = useState("");
  const ref = useRef(null);
  useEffect(()=>{ function out(e){ if(ref.current && !ref.current.contains(e.target)) onClose && onClose(); } document.addEventListener("mousedown",out); return ()=>document.removeEventListener("mousedown",out); },[]);
  const shown = values.filter(v => !q || v.toLowerCase().includes(q.toLowerCase()));
  const allOn = shown.every(v=>sel.has(v));
  return (<div className="funnel-menu" ref={ref} onClick={e=>e.stopPropagation()}>
    <input className="fm-search" placeholder="Search values…" value={q} onChange={e=>setQ(e.target.value)} />
    <label className="fm-all"><input type="checkbox" checked={allOn} onChange={e=>{const n=new Set(sel); shown.forEach(v=>e.target.checked?n.add(v):n.delete(v)); setSel(n);}} />(Select all)</label>
    <div className="fm-list">{shown.map(v=><label key={v}><input type="checkbox" checked={sel.has(v)} onChange={e=>{const n=new Set(sel); e.target.checked?n.add(v):n.delete(v); setSel(n);}} />{v===""?"(blank)":v}</label>)}</div>
    <div className="fm-actions"><button className="db-tbtn" onClick={onClear}>Clear</button><button className="db-tbtn primary" onClick={()=>onApply(new Set(sel))}>Apply</button></div>
  </div>);
}

/* drill-down: clean header + totals + line items + packages + status */
function VoucherDetail({ d, type, user, canMark, onEdit, onToggle, onMark, row }) {
  if (!d || !d.header) return <div className="empty">No detail.</div>;
  const lines = d.lines || [];
  const flagState = (k) => k==="approved_mgmt" ? row.approved_mgmt==="APPROVED" : !!row[k];
  const totVal = lines.reduce((s,l)=>s+(+l.basic_value||0),0);
  // per-line package aggregates (per the spec / PDF):
  //  No. of Packages = count of package rows
  //  Token Ref. No.  = comma list of token refs
  //  Weighted Qty.   = sum of package qty
  //  Net Wt.         = sum of package net_weight
  const pkgAgg = (l) => {
    const pk = Array.isArray(l.packages) ? l.packages : [];
    return {
      count: pk.length,
      tokens: pk.map(p => p.token_ref).filter(t => t !== "" && t != null).join(", "),
      wqty: pk.reduce((s, p) => s + (+p.qty || 0), 0),
      nwt: pk.reduce((s, p) => s + (+p.net_weight || 0), 0),
    };
  };
  const anyPkg = lines.some(l => Array.isArray(l.packages) && l.packages.length > 0);

  return (<div className="vdx">
    <div className="vdx-card">
      <div className="vdx-scroll"><table className="vdx-tbl"><thead><tr>
        <th className="vdx-sno">Line Item No.</th><th className="vdx-l">Part Name</th><th className="vdx-l">Ref. No.</th>
        <th className="vdx-r">Inv Qty.</th><th className="vdx-r">Actual Qty.</th><th className="vdx-c">UOM</th>
        <th className="vdx-r">Unit Price</th><th className="vdx-r">PO Price</th><th className="vdx-r">Basic Value</th>
        {anyPkg && <><th className="vdx-r vdx-pk vdx-pk1">No. of Packages</th><th className="vdx-l vdx-pk">Token Ref. No.</th><th className="vdx-r vdx-pk">Weighted Qty.</th><th className="vdx-r vdx-pk">Net Wt.</th></>}
      </tr></thead><tbody>
        {lines.length===0 ? <tr><td colSpan={anyPkg?13:9} className="vdx-empty">No line items.</td></tr>
          : lines.map((l,i)=>{ const a = pkgAgg(l); return (
            <tr key={i}>
              <td className="vdx-sno">{l.sno}</td>
              <td className="vdx-l"><span className="vdx-part">{l.part_name||l.part_code}</span>{l.line_note?<span className="vdx-note">{l.line_note}</span>:null}</td>
              <td className="vdx-l vdx-muted">{l.ref_no||"—"}</td>
              <td className="vdx-r">{money(l.invoice_qty)}</td>
              <td className="vdx-r">{money(l.actual_qty)}</td>
              <td className="vdx-c vdx-muted">{l.uom}</td>
              <td className="vdx-r">{money(l.unit_price)}</td>
              <td className="vdx-r">{money(l.po_price)}</td>
              <td className="vdx-r vdx-val">{money(l.basic_value)}</td>
              {anyPkg && <><td className="vdx-r vdx-pk vdx-pk1">{a.count||"—"}</td><td className="vdx-l vdx-pk vdx-tokens">{a.tokens||"—"}</td><td className="vdx-r vdx-pk">{a.count?money(a.wqty):"—"}</td><td className="vdx-r vdx-pk">{a.count?a.nwt.toFixed(3):"—"}</td></>}
            </tr>); })}
      </tbody>
      <tfoot><tr>
        <td className="vdx-sno"></td><td className="vdx-l vdx-tot-lbl">Total</td><td></td>
        <td className="vdx-r"></td><td className="vdx-r"></td><td></td>
        <td className="vdx-r"></td><td className="vdx-r"></td><td className="vdx-r vdx-val">{money(totVal)}</td>
        {anyPkg && <><td className="vdx-r vdx-pk vdx-pk1">{money(lines.reduce((s,l)=>s+pkgAgg(l).count,0))}</td><td className="vdx-pk"></td><td className="vdx-r vdx-pk">{money(lines.reduce((s,l)=>s+pkgAgg(l).wqty,0))}</td><td className="vdx-r vdx-pk">{lines.reduce((s,l)=>s+pkgAgg(l).nwt,0).toFixed(3)}</td></>}
      </tr></tfoot>
      </table></div>
    </div>

    {/* status + actions */}
    <div className="vdx-foot">
      <div className="vdx-flags">{FLAGS.filter(([k])=>k!=="price_approved").map(([k,l])=>
        <label key={k} className={"vdx-flag"+(flagState(k)?" on":"")}><input type="checkbox" checked={flagState(k)} onChange={e=>onToggle(row.id,k,e.target.checked)} /><span>{l}</span></label>)}</div>
      {!row.cancelled && canMark && <div className="vdx-acts">
        <button className="btn ghost sm" onClick={()=>onEdit&&onEdit(row.id)}>Edit</button>
        <button className="btn ghost sm" onClick={()=>onMark(row.id,"modify")}>Mark Modify</button>
        <button className="btn ghost sm" onClick={()=>onMark(row.id,"delete")}>Mark Delete</button>
      </div>}
    </div>
  </div>);
}
