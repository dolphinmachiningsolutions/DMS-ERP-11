import React, { useState, useEffect } from "react";
import "./ui/theme.css";
import { supabase, VOUCHERS, VOUCHER_LAYOUT } from "./lib/config";
import { parseAccess, pageAllowed, leafAllowed } from "./lib/accessTree";
import { Dashboard, LastUpdatedBanner, OpenDocsBanner } from "./screens/Masters";
import { VoucherForm } from "./screens/VoucherForm";
import { Production } from "./screens/Production";
import { LedgerForm, PartForm, PartPricing, BurrReport } from "./screens/Database";
import { PhysicalStock, StockView, PartLedger, OpeningStock } from "./screens/Inventory";
import { StockSummary } from "./screens/StockSummaryGrid";
import { Books } from "./screens/Books";
import { UserManagement, PriceApproval, RecCopyApproval, MarkRequests, Settings, MachineConfig, UndoTransactions, OverdueDC, AuditLog, PeriodClose, StockTransfer } from "./screens/Admin";

const PAGES = ["Dashboard","Vouchers","Books","Inventory","Database","Administration"];
const PAGE_IC = { Dashboard:"DB", Vouchers:"VC", Books:"BK", Inventory:"IN", Database:"DT", Administration:"AD" };

export default function App(){
  const [user,setUser]=useState(null);
  return user ? <Shell user={user} onLogout={()=>setUser(null)}/> : <Login onLogin={setUser}/>;
}

function Login({onLogin}){
  const [u,setU]=useState(""); const [p,setP]=useState(""); const [err,setErr]=useState(""); const [busy,setBusy]=useState(false);
  async function submit(){ setErr(""); setBusy(true);
    const {data,error}=await supabase.rpc("verify_login",{p_username:u,p_password:p}); setBusy(false);
    if(error) return setErr(error.message); if(!data||!data.length) return setErr("Invalid username or password."); onLogin(data[0]); }
  return (<div className="login-wrap"><div className="login">
    <div className="logo">D</div><h1>DMS ERP</h1><p className="ls">Dolphin Machining Solutions · V14.1 · build 12-Jun-2026</p>
    {err&&<div className="msg err"><b>✕</b><span>{err}</span></div>}
    <div className="fld" style={{marginBottom:13}}><label>Username</label><input className="ctl" value={u} onChange={e=>setU(e.target.value)} onKeyDown={e=>e.key==="Enter"&&submit()} autoFocus/></div>
    <div className="fld" style={{marginBottom:20}}><label>Password</label><input className="ctl" type="password" value={p} onChange={e=>setP(e.target.value)} onKeyDown={e=>e.key==="Enter"&&submit()}/></div>
    <button className="btn" style={{width:"100%",justifyContent:"center"}} onClick={submit} disabled={busy}>{busy?"Signing in…":"Log On"}</button>
  </div></div>);
}

function Shell({user,onLogout}){
  const [page,setPage]=useState("Dashboard");
  const [sub,setSub]=useState(null);   // {kind, key}
  const [editId,setEditId]=useState(null);
  const [collapsed,setCollapsed]=useState(false);
  const [counts,setCounts]=useState({});       // voucher_type -> doc_count
  const accessSet = parseAccess(user.access_modules);
  const pages = PAGES.filter(p => (p !== "Administration" || user.role === "admin") && (p === "Dashboard" || pageAllowed(accessSet, p)));
  function go(p){ setPage(p); setSub(null); setEditId(null); }
  // load document counts whenever we land on the Books tile page
  useEffect(()=>{ if(page==="Books" && !sub){ (async()=>{
    const { data } = await supabase.rpc("voucher_counts");
    const m={}; (data||[]).forEach(r=>{ m[r.voucher_type]=Number(r.doc_count); }); setCounts(m);
  })(); } },[page,sub]);
  const totalDocs = Object.values(counts).reduce((s,n)=>s+n,0);

  return (<div className={"app"+(collapsed?" collapsed":"")}>
    <aside className="side">
      <div className="brand"><div className="logo">D</div><div className="brand-txt"><b>DMS ERP</b><span>V14.1 · 12-Jun</span></div></div>
      <nav className="nav">
        {pages.map(p=> <button key={p} className={"nav-item"+(page===p?" active":"")} onClick={()=>go(p)} title={p}><span className="nav-ic">{PAGE_IC[p]||p[0]}</span><span className="nav-lbl">{p}</span></button>)}
      </nav>
      <div className="side-foot"><div className="who"><b>{user.username}</b><span className="role">{user.role}</span></div><button onClick={onLogout} title="Logout">⏻</button></div>
    </aside>
    <main className="main">
      <div className="appbar">
        <button className="side-toggle" onClick={()=>setCollapsed(c=>!c)} title="Toggle sidebar">☰</button>
        <div className="crumb">
        <span className={sub?"":"cur"}>{page}</span>
        {sub && <><span className="sep">/</span><span className="cur">{sub.title}</span></>}
        {sub && <button className="btn ghost sm" style={{marginLeft:16}} onClick={()=>{ if(editId) setEditId(null); else setSub(null); }}>← Back</button>}
      </div></div>
      <div className="scroll">
        {page==="Dashboard" && <Dashboard/>}
        {page==="Vouchers" && (sub
          ? (sub.key==="__lastupd" ? <div className="wrap"><LastUpdatedBanner/></div>
             : VOUCHERS[sub.key].special==="production" ? <Production user={user}/> : <VoucherForm key={sub.key} type={sub.key} user={user}/>)
          : <div className="wrap">
              <div className="tile-group"><div className="tile-heading">Status</div><div className="tile-row"><button className="vtile vtile-accent" onClick={()=>setSub({key:"__lastupd",title:"Last Updated Status"})}>Last Updated Status</button></div></div>
              <TilePage title="Vouchers" canLeaf={(k)=>leafAllowed(accessSet,"Vouchers",k)} onPick={(k)=>setSub({key:k,title:VOUCHERS[k].label})}/></div>)}
        {page==="Books" && (sub
          ? (sub.key==="__opendocs" ? <div className="wrap"><OpenDocsBanner/></div>
             : editId
              ? <VoucherForm key={"edit-"+editId} type={sub.key} user={user} editId={editId} onDone={()=>setEditId(null)} />
              : <Books type={sub.key} user={user} onEdit={(id)=>setEditId(id)} />)
          : <div className="wrap">
              <div className="tile-group"><div className="tile-heading">Open Documents</div><div className="tile-row">
                <button className="vtile vtile-accent" onClick={()=>setSub({key:"__opendocs",title:"Open PO / DC / SO"})}>Open PO / DC / SO</button>
                <div className="vtile vtile-stat"><span className="vtile-stat-n">{totalDocs}</span><span className="vtile-stat-l">Total Documents</span></div>
              </div></div>
              <TilePage title="Books" counts={counts} canLeaf={(k)=>leafAllowed(accessSet,"Books",k)} onPick={(k)=>{setEditId(null);setSub({key:k,title:VOUCHERS[k].label})}}/></div>)}
        {page==="Inventory" && (sub
          ? (sub.key==="summary"?<StockSummary/>:sub.key==="stockview"?<StockView/>:sub.key==="recon"?<PhysicalStock user={user}/>:sub.key==="partledger"?<PartLedger/>:sub.key==="transfer"?<StockTransfer user={user}/>:<OpeningStock user={user}/>)
          : <GroupedTiles groups={[
              {heading:"Stock Position", items:[["summary","Stock Summary"],["partledger","Part Ledger"],["stockview","Stock Statement / Ledger"]]},
              {heading:"Movements", items:[["transfer","Stock Transfer"]]},
              {heading:"Maintenance", items:[["recon","Physical Stock Recon"],["opening","Opening Stock"]]},
            ]} onPick={(k,t)=>setSub({key:k,title:t})} canLeaf={(k)=>leafAllowed(accessSet,"Inventory",k)}/>)}
        {page==="Database" && (sub
          ? (sub.key==="ledger"?<LedgerForm user={user}/>:sub.key==="part"?<PartForm user={user}/>:sub.key==="pricing"?<PartPricing/>:<BurrReport/>)
          : <GroupedTiles groups={[
              {heading:"Master Data", items:[["ledger","Ledger"],["part","Part"],["pricing","Part Pricing"]]},
              {heading:"Reports", items:[["burr","Burr Generation Report"]]},
            ]} onPick={(k,t)=>setSub({key:k,title:t})} canLeaf={(k)=>leafAllowed(accessSet,"Database",k)}/>)}
        {page==="Administration" && (sub
          ? (sub.key==="users"?<UserManagement/>:sub.key==="price"?<PriceApproval user={user}/>:sub.key==="rec"?<RecCopyApproval user={user}/>:sub.key==="mark"?<MarkRequests user={user}/>:sub.key==="settings"?<Settings user={user}/>:sub.key==="undo"?<UndoTransactions user={user}/>:sub.key==="audit"?<AuditLog/>:sub.key==="period"?<PeriodClose user={user}/>:sub.key==="overdue"?<OverdueDC user={user}/>:<MachineConfig/>)
          : <GroupedTiles groups={[
              {heading:"Approvals", items:[["price","Price Approval"],["overdue","Overdue DC Approval"],["rec","Rec Copy Approval"],["mark","Mod & Del Requests"]]},
              {heading:"Logs", items:[["undo","Transaction Log"],["audit","Audit Log"]]},
              {heading:"Configuration", items:[["users","User Management"],["settings","Settings"],["machine","Machine Config"],["period","Period Close"]]},
            ]} onPick={(k,t)=>setSub({key:k,title:t})} canLeaf={(k)=>leafAllowed(accessSet,"Administration",k)}/>)}
      </div>
    </main>
  </div>);
}

/* Vouchers/Books tile page: headings + child tiles (no continuous grid) */
function TilePage({title,onPick,counts,canLeaf}){
  return (<div className="wrap">
    {VOUCHER_LAYOUT.map(g=>{ const items=g.items.filter(k=>!canLeaf||canLeaf(k)); if(!items.length) return null; return <div key={g.heading} className="tile-group">
      <div className="tile-heading">{g.heading}</div>
      <div className="tile-row">
        {items.map(k=> <button key={k} className="vtile" onClick={()=>onPick(k)}>
          <span className="vtile-label">{VOUCHERS[k].label}</span>
          {counts && <span className="vtile-count">{counts[k]||0}</span>}
        </button>)}
      </div>
    </div>; })}
  </div>);
}
function SimpleTiles({title,items,onPick}){
  return (<div className="wrap"><div className="tile-row">
    {items.map(([k,t])=> <button key={k} className="vtile" onClick={()=>onPick(k,t)}>{t}</button>)}
  </div></div>);
}
/* Grouped tile page: headed sections, evenly laid out (Inventory/Database/Admin) */
function GroupedTiles({groups,onPick,canLeaf}){
  return (<div className="wrap">
    {groups.map(g=>{ const items=g.items.filter(([k])=>!canLeaf||canLeaf(k)); if(!items.length) return null; return <div key={g.heading} className="tile-group">
      <div className="tile-heading">{g.heading}</div>
      <div className="tile-row">
        {items.map(([k,t])=> <button key={k} className="vtile" onClick={()=>onPick(k,t)}><span className="vtile-label">{t}</span></button>)}
      </div>
    </div>; })}
  </div>);
}
