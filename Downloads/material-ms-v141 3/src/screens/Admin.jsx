import React, { useState, useEffect } from "react";
import { supabase, toDMY, money, VOUCHERS } from "../lib/config";
import { Field, Msg } from "../ui/primitives";
import { APP_TREE, leafKey, allLeafKeys } from "../lib/accessTree";

// module-level field wrapper (avoids remount/focus-loss from defining inside render)
function DsxField({ label, req, hint, children }) {
  return (<div className="dsx-fld"><label>{label}{req && <span className="req">*</span>}</label>{children}{hint && <span className="hint">{hint}</span>}</div>);
}

export function UserManagement() {
  const [users, setUsers] = useState([]); const [msg, setMsg] = useState(null);
  const MODULES = ["Dashboard", "Vouchers", "Books", "Inventory", "Database", "Administration"];
  const blank = { id: null, username: "", password: "", role: "user", access_modules: "ALL", weight_check: true, valid_thru_edit: false, active: true };
  const [f, setF] = useState(blank);
  // access_modules: "ALL" or comma list of "Page" and "Page:leaf". Helpers:
  const ALL_LEAVES = allLeafKeys();
  const accessSet = () => f.access_modules === "ALL" ? new Set([...MODULES, ...ALL_LEAVES]) : new Set((f.access_modules || "").split(",").map(s => s.trim()).filter(Boolean));
  const isLeafOn = (page, leaf) => { const s = accessSet(); return s.has(page) || s.has(leafKey(page, leaf)); };
  const pageLeaves = (m) => m.groups.flatMap(g => g.items.map(([k]) => leafKey(m.page, k)));
  const isPageOn = (m) => { const s = accessSet(); return s.has(m.page) || pageLeaves(m).some(lk => s.has(lk)); };
  function commit(set) {
    set.delete("ALL");
    const all = MODULES.every(p => set.has(p) || (APP_TREE.find(m => m.page === p)?.always)) && ALL_LEAVES.every(lk => set.has(lk));
    setF(p => ({ ...p, access_modules: all ? "ALL" : [...set].join(",") }));
  }
  const toggleLeaf = (page, leaf) => { const s = accessSet(); const lk = leafKey(page, leaf);
    // expand a whole-page grant into leaves first so we can remove just one
    if (s.has(page)) { s.delete(page); (APP_TREE.find(m => m.page === page)?.groups || []).forEach(g => g.items.forEach(([k]) => s.add(leafKey(page, k)))); }
    s.has(lk) ? s.delete(lk) : s.add(lk); commit(s); };
  const togglePage = (m) => { const s = accessSet(); const on = isPageOn(m);
    pageLeaves(m).forEach(lk => s.delete(lk)); s.delete(m.page);
    if (!on) { s.add(m.page); pageLeaves(m).forEach(lk => s.add(lk)); } commit(s); };
  const setAll = (on) => setF(p => ({ ...p, access_modules: on ? "ALL" : "Dashboard" }));
  async function load() { const { data } = await supabase.rpc("admin_list_users"); setUsers(data || []); }
  useEffect(() => { load(); }, []);
  async function save() {
    if (!f.username.trim()) return setMsg({ t: "err", m: "Username required." });
    if (!f.access_modules) return setMsg({ t: "err", m: "Select at least one module the user can access." });
    const { error } = await supabase.rpc("admin_save_user", { p_id: f.id, p_username: f.username, p_password: f.password || null, p_role: f.role, p_access: f.access_modules, p_weight: f.weight_check, p_valid_edit: f.valid_thru_edit, p_active: f.active });
    if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: `User ${f.username} saved.` }); setF(blank); load();
  }
  async function del(id) { const { error } = await supabase.rpc("admin_delete_user", { p_id: id }); if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: "Deleted." }); load(); }

  const FLAGS = [["generated", "Generated"], ["cancelled", "Cancelled"], ["rec_copy", "Received Copy"], ["gstr1", "GSTR 1"], ["gstr2b", "GSTR 2B"], ["approved_mgmt", "Mgmt. Approved"], ["approved_acc", "A/c Approved"]];
  const [permUser, setPermUser] = useState(null); const [perms, setPerms] = useState({});
  async function openPerms(u) {
    setPermUser(u); const { data } = await supabase.rpc("get_checkbox_perms", { p_user: u.id });
    const m = {}; FLAGS.forEach(([k]) => m[k] = true); (data || []).forEach(r => m[r.flag] = r.allowed); setPerms(m);
  }
  async function setPerm(flag, allowed) { setPerms(p => ({ ...p, [flag]: allowed })); await supabase.rpc("set_checkbox_perm", { p_user: permUser.id, p_flag: flag, p_allowed: allowed }); }
  // per-module action rights (view/create/approve)
  const RIGHT_MODULES = ["Vouchers", "Books", "Inventory", "Database", "Administration"];
  const [rightsUser, setRightsUser] = useState(null); const [rights, setRights] = useState({});
  async function openRights(u) {
    setRightsUser(u); setPermUser(null);
    const { data } = await supabase.rpc("get_module_rights", { p_user: u.id });
    const m = {}; RIGHT_MODULES.forEach(mod => m[mod] = { can_view: true, can_create: false, can_approve: false, can_edit: false, can_markdel: false, can_markedit: false });
    (data || []).forEach(r => m[r.module] = { can_view: r.can_view, can_create: r.can_create, can_approve: r.can_approve, can_edit: !!r.can_edit, can_markdel: !!r.can_markdel, can_markedit: !!r.can_markedit });
    setRights(m);
  }
  async function setRight(mod, field, val) {
    const next = { ...rights[mod], [field]: val };
    setRights(r => ({ ...r, [mod]: next }));
    await supabase.rpc("set_module_right", { p_user: rightsUser.id, p_module: mod, p_view: next.can_view, p_create: next.can_create, p_approve: next.can_approve, p_edit: !!next.can_edit, p_markdel: !!next.can_markdel, p_markedit: !!next.can_markedit });
  }
  const F = DsxField;
  return (<div className="dsx"><Msg msg={msg} />
    <div className="dsx-head">
      <div><h1>Users &amp; Access</h1><div className="sub">Create accounts, set roles, and control exactly which screens each person can reach.</div></div>
    </div>

    <div className="dsx-card">
      <div className="dsx-card-h"><h2>{f.id ? `Edit ${f.username}` : "New user"}</h2>{f.id && <button className="dsx-btn ghost sm" onClick={() => setF(blank)}>Cancel edit</button>}</div>
      <div className="dsx-card-b">
        <div className="dsx-form">
          <F label="Username"><input className="dsx-input" value={f.username} onChange={e => setF(s => ({ ...s, username: e.target.value }))} /></F>
          <F label="Password" hint={f.id ? "Leave blank to keep current" : "Defaults to: changeme"}><input className="dsx-input" type="password" placeholder={f.id ? "••••••" : "changeme"} value={f.password} onChange={e => setF(s => ({ ...s, password: e.target.value }))} /></F>
          <F label="Role"><select className="dsx-select" value={f.role} onChange={e => setF(s => ({ ...s, role: e.target.value }))}><option value="user">User</option><option value="can_edit">Can edit</option><option value="admin">Admin</option></select></F>
          <F label="Weight check"><select className="dsx-select" value={f.weight_check ? "y" : "n"} onChange={e => setF(s => ({ ...s, weight_check: e.target.value === "y" }))}><option value="y">Enforced</option><option value="n">Skip</option></select></F>
          <F label="Edit valid-thru"><select className="dsx-select" value={f.valid_thru_edit ? "y" : "n"} onChange={e => setF(s => ({ ...s, valid_thru_edit: e.target.value === "y" }))}><option value="n">No</option><option value="y">Yes</option></select></F>
          <F label="Account status"><select className="dsx-select" value={f.active ? "y" : "n"} onChange={e => setF(s => ({ ...s, active: e.target.value === "y" }))}><option value="y">Active</option><option value="n">Inactive — can't sign in</option></select></F>
        </div>

        <div className="dsx-access">
          <div className="dsx-access-head"><span>Access — modules &amp; screens</span>
            <div style={{ display: "flex", gap: 8 }}><button type="button" className="dsx-btn ghost sm" onClick={() => setAll(true)}>Select all</button><button type="button" className="dsx-btn ghost sm" onClick={() => setAll(false)}>Clear</button></div></div>
          <div className="dsx-access-grid">{APP_TREE.map(m => m.always ? null : (
            <div key={m.page} className="dsx-mod">
              <label className={"dsx-mod-h" + (isPageOn(m) ? " on" : "")}>
                <input type="checkbox" checked={isPageOn(m)} onChange={() => togglePage(m)} />
                <span>{m.label}</span>{m.adminOnly && <span className="dsx-mod-tag">admin only</span>}
              </label>
              <div className="dsx-leaves">{m.groups.map(g => (
                <div key={g.heading} className="dsx-leaf-grp">
                  <div className="dsx-leaf-h">{g.heading}</div>
                  {g.items.map(([k, lbl]) => <label key={k} className={"dsx-leaf" + (isLeafOn(m.page, k) ? " on" : "")}>
                    <input type="checkbox" checked={isLeafOn(m.page, k)} onChange={() => toggleLeaf(m.page, k)} />{lbl}</label>)}
                </div>))}
              </div>
            </div>))}</div>
          <div className="hint" style={{ marginTop: 10 }}>Tick a whole module, or expand and pick individual screens. Dashboard is always available; Administration also needs the admin role.</div>
        </div>

        <div style={{ display: "flex", gap: 9, marginTop: 22 }}><button className="dsx-btn primary" onClick={save}>{f.id ? "Save changes" : "Create user"}</button>{f.id && <button className="dsx-btn ghost" onClick={() => setF(blank)}>Cancel</button>}</div>
      </div>
    </div>

    <div className="dsx-card">
      <div className="dsx-card-h"><h2>All users</h2><span className="sub">{users.length} {users.length === 1 ? "account" : "accounts"}</span></div>
      <div className="dsx-card-b flush"><div className="dsx-table-wrap">
        <table className="dsx-table"><thead><tr><th>User</th><th>Role</th><th>Access</th><th className="c">Status</th><th>Last sign-in</th><th className="r">Actions</th></tr></thead>
          <tbody>{users.map(u => <tr key={u.id}>
            <td><span className="dsx-strong">{u.username}</span></td>
            <td><span className="dsx-badge off">{u.role}</span></td>
            <td className="dsx-muted">{u.access_modules === "ALL" ? "All modules" : `${(u.access_modules || "").split(",").filter(Boolean).length} screens`}</td>
            <td className="c">{u.active === false ? <span className="dsx-badge err">Inactive</span> : <span className="dsx-badge ok"><span className="dot" />Active</span>}</td>
            <td className="dsx-muted">{u.last_login ? new Date(u.last_login).toLocaleString() : "Never"}</td>
            <td className="r" style={{ whiteSpace: "nowrap" }}>
              <button className="dsx-btn ghost sm" onClick={() => setF({ ...u, password: "", active: u.active !== false })}>Edit</button>{" "}
              <button className="dsx-btn ghost sm" onClick={() => openPerms(u)}>Flags</button>{" "}
              <button className="dsx-btn ghost sm" onClick={() => openRights(u)}>Rights</button>{" "}
              {u.username !== "admin" && <button className="dsx-btn danger sm" onClick={() => del(u.id)}>Delete</button>}
            </td></tr>)}</tbody></table>
      </div></div>
    </div>

    {permUser && <div className="dsx-card">
      <div className="dsx-card-h"><h2>Checkbox permissions — {permUser.username}</h2><button className="dsx-btn ghost sm" onClick={() => setPermUser(null)}>Close</button></div>
      <div className="dsx-card-b">
        <div className="hint" style={{ marginBottom: 14 }}>Unticked means this user can't toggle that document control in Books. Admins always can.</div>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 10 }}>{FLAGS.map(([k, l]) => <label key={k} className={"dsx-leaf" + (perms[k] !== false ? " on" : "")} style={{ border: "1px solid var(--line-2)", borderRadius: 8, padding: "8px 13px" }}>
          <input type="checkbox" checked={perms[k] !== false} onChange={e => setPerm(k, e.target.checked)} />{l}</label>)}</div>
      </div>
    </div>}

    {rightsUser && <div className="dsx-card">
      <div className="dsx-card-h"><h2>Module rights — {rightsUser.username}</h2><button className="dsx-btn ghost sm" onClick={() => setRightsUser(null)}>Close</button></div>
      <div className="dsx-card-b">
        <div className="hint" style={{ marginBottom: 14 }}>View opens a module · Create adds or posts · Approve clears holds · Edit edits a voucher · Mark-Del / Mark-Edit raise delete / modify requests. Admins always have every right.</div>
        <div className="dsx-table-wrap"><table className="dsx-table"><thead><tr><th>Module</th><th className="c">View</th><th className="c">Create</th><th className="c">Approve</th><th className="c">Edit</th><th className="c">Mark-Del</th><th className="c">Mark-Edit</th></tr></thead>
          <tbody>{RIGHT_MODULES.map(mod => { const r = rights[mod] || {}; return <tr key={mod}><td className="dsx-strong">{mod}</td>
            <td className="c"><input type="checkbox" checked={!!r.can_view} onChange={e => setRight(mod, "can_view", e.target.checked)} /></td>
            <td className="c"><input type="checkbox" checked={!!r.can_create} onChange={e => setRight(mod, "can_create", e.target.checked)} /></td>
            <td className="c"><input type="checkbox" checked={!!r.can_approve} onChange={e => setRight(mod, "can_approve", e.target.checked)} /></td>
            <td className="c"><input type="checkbox" checked={!!r.can_edit} onChange={e => setRight(mod, "can_edit", e.target.checked)} /></td>
            <td className="c"><input type="checkbox" checked={!!r.can_markdel} onChange={e => setRight(mod, "can_markdel", e.target.checked)} /></td>
            <td className="c"><input type="checkbox" checked={!!r.can_markedit} onChange={e => setRight(mod, "can_markedit", e.target.checked)} /></td></tr>; })}</tbody></table></div>
      </div>
    </div>}
  </div>);
}

export function PriceApproval({ user }) {
  const [rows, setRows] = useState([]); const [msg, setMsg] = useState(null);
  const [open, setOpen] = useState(null); const [lines, setLines] = useState({});
  async function load() { const { data } = await supabase.rpc("price_pending_full"); setRows(data || []); }
  useEffect(() => { load(); }, []);
  async function toggle(id) {
    if (open === id) { setOpen(null); return; }
    setOpen(id);
    if (!lines[id]) { const { data } = await supabase.rpc("price_pending_lines", { p_voucher: id }); setLines(l => ({ ...l, [id]: data || [] })); }
  }
  async function approve(id) { const { data, error } = await supabase.rpc("approve_price_post", { p_id: id, p_user: user?.username || "admin" }); if (error) return setMsg({ t: "err", m: error.message }); if (data && !data.ok) return setMsg({ t: "err", m: data.msg }); setMsg({ t: "ok", m: data?.msg || "Approved & posted." }); load(); }
  async function reject(id) { if (!window.confirm("Reject and discard this voucher? It was never posted to stock.")) return; const { data, error } = await supabase.rpc("reject_price", { p_id: id, p_user: user?.username || "admin" }); if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: data?.msg || "Rejected." }); load(); }
  return (<div className="wrap"><Msg msg={msg} /><div className="card"><div className="card-h"><h2>Price Approval</h2><span className="hint">Purchases where unit price ≠ PO price — stock posts only on approval</span></div>
    <div className="card-b" style={{ padding: 0 }}>{rows.length === 0 ? <div className="empty">Nothing pending.</div>
      : <table className="dt"><thead><tr><th></th><th>Voucher</th><th>Type</th><th>Date</th><th>Ledger</th><th className="num">Qty</th><th className="num">Value</th><th></th></tr></thead>
        <tbody>{rows.map(r => <React.Fragment key={r.id}>
          <tr><td><button className="btn ghost sm" onClick={() => toggle(r.id)}>{open === r.id ? "▾" : "▸"}</button></td>
            <td className="mono">{r.voucher_no}</td><td>{r.voucher_type}</td><td>{toDMY(r.voucher_date)}</td><td>{r.ledger_name}</td><td className="num">{money(r.total_qty)}</td><td className="num">{money(r.total_value)}</td>
            <td><button className="btn sm" onClick={() => approve(r.id)}>Approve &amp; Post</button>{" "}<button className="btn ghost sm" onClick={() => reject(r.id)}>Reject</button></td></tr>
          {open === r.id && <tr><td></td><td colSpan={7} style={{ padding: 0 }}>
            <table className="dt" style={{ margin: 0 }}><thead><tr><th>Part</th><th className="num">Qty</th><th className="num">Entered Price</th><th className="num">PO Price</th><th className="num">Difference</th><th className="num">Value</th></tr></thead>
              <tbody>{(lines[r.id] || []).map((l, i) => { const diff = (+l.unit_price || 0) - (+l.po_price || 0); return <tr key={i}>
                <td><b>{l.part_code}</b> · {l.part_name}</td><td className="num">{money(l.qty)}</td>
                <td className="num">{money(l.unit_price)}</td><td className="num">{money(l.po_price)}</td>
                <td className="num" style={{ color: diff > 0 ? "var(--err)" : diff < 0 ? "var(--ok)" : "inherit", fontWeight: 700 }}>{diff > 0 ? "+" : ""}{money(diff)}</td>
                <td className="num">{money(l.basic_value)}</td></tr>; })}
                {(lines[r.id] || []).length === 0 && <tr><td colSpan={6} className="empty">Loading…</td></tr>}</tbody></table>
          </td></tr>}
        </React.Fragment>)}</tbody></table>}</div></div></div>);
}

export function OverdueDC({ user }) {
  const [rows, setRows] = useState([]); const [msg, setMsg] = useState(null);
  async function load() { const { data } = await supabase.rpc("overdue_dcjw"); setRows(data || []); }
  useEffect(() => { load(); }, []);
  async function clear(id) { const { error } = await supabase.rpc("clear_overdue_dcjw", { p_id: id, p_user: user?.username || "admin" }); if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: "Overdue DC cleared — new DCs allowed." }); load(); }
  return (<div className="wrap"><Msg msg={msg} /><div className="card"><div className="card-h"><h2>Overdue DC Approval</h2><span className="hint">DC Out (JW) past due date &amp; still pending — blocks new DCs until cleared</span></div>
    <div className="card-b" style={{ padding: 0 }}>{rows.length === 0 ? <div className="empty">No overdue DCs. New DCs are allowed.</div>
      : <table className="dt"><thead><tr><th>DC Number</th><th>DC Date</th><th>Due Date</th><th>Vendor</th><th>Part</th><th className="num">Pending</th><th className="num">Days Overdue</th><th></th></tr></thead>
        <tbody>{rows.map(r => <tr key={r.id} className="db-cancel"><td className="mono">{r.voucher_no}</td><td>{toDMY(r.voucher_date)}</td><td style={{ color: "var(--err)", fontWeight: 700 }}>{toDMY(r.due_date)}</td><td>{r.ledger_name}</td><td>{r.part_code}</td><td className="num">{(+r.pending_qty).toFixed(0)}</td><td className="num" style={{ color: "var(--err)", fontWeight: 700 }}>{r.days_overdue}</td>
          <td><button className="btn sm" onClick={() => clear(r.id)}>Clear / Override</button></td></tr>)}</tbody></table>}</div></div></div>);
}

export function RecCopyApproval({ user }) {
  const [rows, setRows] = useState([]); const [msg, setMsg] = useState(null);
  async function load() { const { data } = await supabase.rpc("rec_copy_holds"); setRows(data || []); }
  useEffect(() => { load(); }, []);
  async function approve(id, no) {
    const { data, error } = await supabase.rpc("approve_rec_hold", { p_id: id, p_user: user?.username || "admin" });
    if (error) { const m = /INSUFFICIENT/.test(error.message) ? "Not enough stock to post this document now." : error.message; return setMsg({ t: "err", m }); }
    if (data && !data.ok) return setMsg({ t: "err", m: data.msg });
    setMsg({ t: "ok", m: `${no} approved — stock posted.` }); load();
  }
  async function reject(id, no) {
    if (!window.confirm(`Reject ${no}? It will be discarded and no stock will post.`)) return;
    const { data, error } = await supabase.rpc("reject_rec_hold", { p_id: id, p_user: user?.username || "admin" });
    if (error) return setMsg({ t: "err", m: error.message });
    setMsg({ t: "ok", m: data?.msg || "Rejected." }); load();
  }
  return (<div className="wrap"><Msg msg={msg} /><div className="card"><div className="card-h"><h2>Rec Copy Approval</h2><span className="hint">Documents held because an earlier one is &gt;2 days without a Received Copy — approving posts their stock</span></div>
    <div className="card-b" style={{ padding: 0 }}>{rows.length === 0 ? <div className="empty">Nothing held.</div>
      : <table className="dt"><thead><tr><th>Type</th><th>Voucher</th><th>Date</th><th>Party / Ledger</th><th className="num">Qty</th><th className="num">Value</th><th></th></tr></thead>
        <tbody>{rows.map(r => <tr key={r.id}><td>{r.voucher_type}</td><td className="mono">{r.voucher_no}</td><td>{toDMY(r.voucher_date)}</td><td>{r.ledger_name || "—"}</td><td className="num">{money(r.total_qty)}</td><td className="num">{money(r.total_value)}</td>
          <td><button className="btn sm" onClick={() => approve(r.id, r.voucher_no)}>Approve &amp; Post</button>{" "}<button className="btn ghost sm" onClick={() => reject(r.id, r.voucher_no)}>Reject</button></td></tr>)}</tbody></table>}</div></div></div>);
}

export function MarkRequests({ user }) {
  const [rows, setRows] = useState([]); const [msg, setMsg] = useState(null);
  async function load() { const { data } = await supabase.rpc("marked_requests"); setRows(data || []); }
  useEffect(() => { load(); }, []);
  async function resolve(id, mark, action) { const { error } = await supabase.rpc("resolve_mark", { p_id: id, p_mark: mark, p_action: action, p_admin: user?.username || "admin" });
    if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: `${action} ${mark}.` }); load(); }
  return (<div className="wrap"><Msg msg={msg} /><div className="card"><div className="card-h"><h2>Mod &amp; Del Request</h2></div>
    <div className="card-b" style={{ padding: 0 }}>{rows.length === 0 ? <div className="empty">No requests.</div>
      : <table className="dt"><thead><tr><th>Voucher</th><th>Type</th><th>Req</th><th>Reason</th><th>By</th><th></th></tr></thead>
        <tbody>{rows.map(r => { const mark = r.delete_requested ? "delete" : "modify"; return <tr key={r.id}><td className="mono">{r.voucher_no}</td><td>{r.voucher_type}</td><td><span className="pill off">{mark}</span></td><td>{r.request_reason}</td><td>{r.requested_by}</td>
          <td><button className="btn sm" onClick={() => resolve(r.id, mark, "approve")}>Approve</button>{" "}<button className="btn ghost sm" onClick={() => resolve(r.id, mark, "reject")}>Reject</button></td></tr>; })}</tbody></table>}</div></div></div>);
}

export function Settings({ user }) {
  const [s, setS] = useState({ lot_enabled: "true", lot_mandatory: "false" }); const [msg, setMsg] = useState(null);
  const [tab, setTab] = useState("lot");
  const [cu, setCu] = useState("");                       // cancel_users draft
  const [floorN, setFloorN] = useState("");               // dcjw_nnn_floor draft
  const [frType, setFrType] = useState("PURCHASE");       // field-rules: selected voucher type
  const [fr, setFr] = useState({});                       // parsed field_rules JSON
  const [erConfirm, setErConfirm] = useState("");         // erase confirmation phrase
  const [erBusy, setErBusy] = useState(false);
  async function eraseData() {
    if (erConfirm !== "ERASE ALL DATA") { setMsg({ t: "err", m: "Type the exact phrase: ERASE ALL DATA" }); return; }
    if (!window.confirm("FINAL WARNING. This permanently deletes ALL transactions and master data (parts, parties, prices, machines). Users, rights and settings are kept. This CANNOT be undone. Proceed?")) return;
    setErBusy(true);
    const { data, error } = await supabase.rpc("admin_erase_data", { p_user: user?.username || null, p_confirm: erConfirm });
    setErBusy(false);
    if (error) { setMsg({ t: "err", m: error.message }); return; }
    setErConfirm(""); setMsg({ t: "ok", m: data || "Data erased." });
  }
  const [storage, setStorage] = useState(null); const [tables, setTables] = useState([]); const [loadingS, setLoadingS] = useState(false);
  async function load() { const { data } = await supabase.rpc("get_settings"); const o = {}; (data || []).forEach(r => o[r.key] = r.value); setS(x => ({ ...x, ...o }));
    setCu(o.cancel_users || ""); setFloorN(o.dcjw_nnn_floor || "");
    try { setFr(JSON.parse(o.field_rules || "{}")); } catch (e) { setFr({}); } }
  useEffect(() => { load(); }, []);
  async function set(key, val) { const { error } = await supabase.rpc("set_setting", { p_key: key, p_value: val }); if (error) return setMsg({ t: "err", m: error.message }); setS(x => ({ ...x, [key]: val })); setMsg({ t: "ok", m: "Saved." }); }

  async function loadStorage() {
    setLoadingS(true); setMsg(null);
    const { data: tot, error: e1 } = await supabase.rpc("db_storage_total");
    const { data: tbl, error: e2 } = await supabase.rpc("db_storage_by_table");
    setLoadingS(false);
    if (e1 || e2) return setMsg({ t: "err", m: (e1 || e2).message });
    setStorage(tot && tot[0]); setTables(tbl || []);
  }
  useEffect(() => { if (tab === "storage" && !storage) loadStorage(); }, [tab]);

  async function clearCache() {
    if (!window.confirm("Clear this app's cached data and reload? You'll stay logged in to the database but the page will refresh.")) return;
    try {
      if (window.caches) { const keys = await caches.keys(); await Promise.all(keys.map(k => caches.delete(k))); }
      if (window.indexedDB && indexedDB.databases) { const dbs = await indexedDB.databases(); await Promise.all((dbs || []).map(d => d.name && indexedDB.deleteDatabase(d.name))); }
      if (navigator.serviceWorker) { const regs = await navigator.serviceWorker.getRegistrations(); await Promise.all(regs.map(r => r.unregister())); }
      try { sessionStorage.clear(); } catch {}
      setMsg({ t: "ok", m: "Cache cleared. Reloading…" });
      setTimeout(() => window.location.reload(true), 800);
    } catch (e) { setMsg({ t: "err", m: "Could not clear cache: " + e.message }); }
  }

  const maxBytes = tables.reduce((m, t) => Math.max(m, +t.bytes || 0), 0);

  // feature 4: voucher enable/disable
  const [venabled, setVenabled] = useState({});
  async function loadVenabled() { const { data } = await supabase.rpc("list_voucher_enabled"); const o = {}; (data || []).forEach(r => o[r.voucher_type] = r.enabled); setVenabled(o); }
  useEffect(() => { if (tab === "vouchers") loadVenabled(); }, [tab]);
  async function toggleVoucher(vt, on) { const { error } = await supabase.rpc("set_voucher_enabled", { p_type: vt, p_on: on }); if (error) return setMsg({ t: "err", m: error.message }); setVenabled(x => ({ ...x, [vt]: on })); }
  const vkeys = Object.keys(VOUCHERS);

  // multi-location config
  const INT_BUCKETS = [["RC","Raw Casting"],["RCJW","RC@JW"],["CC","Coated Casting"],["MG","Machined Goods"],["PR","Process Rej."],["MR","Material Rej."],["JOBOUT","Sent Out"]];
  const [locs, setLocs] = useState([]); const [locBuckets, setLocBuckets] = useState({}); const [newLoc, setNewLoc] = useState({ code: "", name: "" });
  async function loadLocs() {
    const { data } = await supabase.rpc("list_locations", { p_active_only: false }); setLocs(data || []);
    const map = {};
    for (const l of (data || [])) { const { data: b } = await supabase.rpc("location_buckets", { p_loc: l.id }); map[l.id] = (b || []).map(x => x.bucket); }
    setLocBuckets(map);
  }
  useEffect(() => { if (tab === "locations") loadLocs(); }, [tab]);
  async function addLoc() {
    if (!newLoc.name.trim()) return setMsg({ t: "err", m: "Location name required." });
    const { error } = await supabase.rpc("save_location", { p_id: null, p_code: newLoc.code || null, p_name: newLoc.name, p_status: "Active", p_sort: locs.length });
    if (error) return setMsg({ t: "err", m: error.message });
    setNewLoc({ code: "", name: "" }); setMsg({ t: "ok", m: "Location added." }); loadLocs();
  }
  async function toggleLocStatus(l) {
    const { error } = await supabase.rpc("save_location", { p_id: l.id, p_code: l.loc_code, p_name: l.loc_name, p_status: l.status === "Active" ? "Inactive" : "Active", p_sort: l.sort_order });
    if (error) return setMsg({ t: "err", m: error.message }); loadLocs();
  }
  async function toggleLocBucket(locId, bucket) {
    const cur = locBuckets[locId] || [];
    const next = cur.includes(bucket) ? cur.filter(b => b !== bucket) : [...cur, bucket];
    const { error } = await supabase.rpc("set_location_buckets", { p_loc: locId, p_buckets: next });
    if (error) return setMsg({ t: "err", m: error.message });
    setLocBuckets(m => ({ ...m, [locId]: next })); setMsg({ t: "ok", m: "Allow-list updated." });
  }


  // feature 14: database column / checkbox config per voucher type
  const DB_COLS = [["voucher_id_code","ID"],["voucher_no","Voucher No"],["voucher_period","Voucher Period"],["voucher_date","Voucher Date"],["posting_period","Posting Period"],["posting_date","Posting Date"],["ledger_name","Ledger"],["total_qty","Qty"],["total_value","Value"],["status","Status"],["generated","Generated"],["cancelled","Cancelled"],["rec_copy","Received Copy"],["gstr1","GSTR 1"],["gstr2b","GSTR 2B"],["approved_mgmt","Mgmt. Approved"],["approved_acc","A/c Approved"]];
  const [cfgType, setCfgType] = useState(vkeys[0]); const [colCfg, setColCfg] = useState({});
  async function loadColCfg(vt) {
    const { data } = await supabase.rpc("get_column_config", { p_type: vt });
    const o = {}; DB_COLS.forEach(([k], i) => o[k] = { visible: true, sort_order: i });
    (data || []).forEach(c => o[c.col_key] = { visible: c.visible, sort_order: c.sort_order });
    setColCfg(o);
  }
  useEffect(() => { if (tab === "columns") loadColCfg(cfgType); }, [tab, cfgType]);
  async function saveColVisible(k, vis) {
    const cur = colCfg[k] || { sort_order: 0 };
    const { error } = await supabase.rpc("set_column_config", { p_type: cfgType, p_key: k, p_label: (DB_COLS.find(c=>c[0]===k)||[])[1], p_visible: vis, p_sort: cur.sort_order });
    if (error) return setMsg({ t: "err", m: error.message });
    setColCfg(c => ({ ...c, [k]: { ...c[k], visible: vis } })); setMsg({ t: "ok", m: "Saved." });
  }
  async function moveCol(k, dir) {
    const entries = DB_COLS.map(([key])=>key).sort((a,b)=>(colCfg[a]?.sort_order??0)-(colCfg[b]?.sort_order??0));
    const i = entries.indexOf(k); const j = i+dir; if (j<0||j>=entries.length) return;
    const a=entries[i], b=entries[j]; const sa=colCfg[a]?.sort_order??i, sb=colCfg[b]?.sort_order??j;
    await supabase.rpc("set_column_config", { p_type: cfgType, p_key: a, p_label:(DB_COLS.find(c=>c[0]===a)||[])[1], p_visible: colCfg[a]?.visible!==false, p_sort: sb });
    await supabase.rpc("set_column_config", { p_type: cfgType, p_key: b, p_label:(DB_COLS.find(c=>c[0]===b)||[])[1], p_visible: colCfg[b]?.visible!==false, p_sort: sa });
    loadColCfg(cfgType);
  }

  return (<div className="wrap"><Msg msg={msg} />
    <div className="tabs">
      <button className={tab === "lot" ? "active" : ""} onClick={() => setTab("lot")}>LOT Allocation</button>
      <button className={tab === "locations" ? "active" : ""} onClick={() => setTab("locations")}>Locations</button>
      <button className={tab === "rules" ? "active" : ""} onClick={() => setTab("rules")}>Voucher Rules</button>
      {user?.role === "admin" && <button className={tab === "danger" ? "active" : ""} onClick={() => setTab("danger")} style={{ color: "#b3261e" }}>Danger Zone</button>}
      <button className={tab === "vouchers" ? "active" : ""} onClick={() => setTab("vouchers")}>Enable / Disable Vouchers</button>
      <button className={tab === "columns" ? "active" : ""} onClick={() => setTab("columns")}>Database Columns</button>
      <button className={tab === "storage" ? "active" : ""} onClick={() => setTab("storage")}>Database Storage</button>
      <button className={tab === "cache" ? "active" : ""} onClick={() => setTab("cache")}>Clear Cache</button>
    </div>
    <div className="card" style={{ borderTopLeftRadius: 0 }}>
      {tab === "lot" && <div className="card-b"><div className="fg">
        <Field label="LOT Allocation" req={false}><select className="ctl" value={s.lot_enabled} onChange={e => set("lot_enabled", e.target.value)}><option value="true">On</option><option value="false">Off</option></select></Field>
        <Field label="LOT Mandatory" req={false}><select className="ctl" value={s.lot_mandatory} onChange={e => set("lot_mandatory", e.target.value)}><option value="false">Not mandatory</option><option value="true">Mandatory</option></select></Field>
      </div><div className="hint" style={{ marginTop: 8 }}>Production #10/#20/#30 enable is now configured per machine in Machine Config.</div></div>}

      {tab === "rules" && <div className="card-b">
        <div className="fg" style={{ marginBottom: 14 }}>
          <Field label="Users allowed to Cancel vouchers" req={false} wide>
            <input className="ctl" placeholder="comma-separated usernames, e.g. ravi,kumar (admin always allowed)"
              value={cu} onChange={e => setCu(e.target.value)} />
          </Field>
          <Field label=" " req={false}><button className="btn" onClick={() => set("cancel_users", cu.trim())}>Save</button></Field>
        </div>
        <div className="fg" style={{ marginBottom: 14 }}>
          <Field label="DC Out (JW) — next serial floor (NNN)" req={false}>
            <input className="ctl" type="number" min="1" placeholder="e.g. 57"
              value={floorN} onChange={e => setFloorN(e.target.value.replace(/[^0-9]/g, ""))} />
          </Field>
          <Field label=" " req={false}><button className="btn" onClick={() => set("dcjw_nnn_floor", floorN.trim())}>Save</button></Field>
        </div>
        <div className="hint" style={{ marginBottom: 10 }}>DC numbers use DDCJ + financial year + month + NNN. The floor lets you jump the NNN forward (it never goes backward past existing vouchers).</div>
        <hr style={{ border: "none", borderTop: "1px solid #e3e6eb", margin: "14px 0" }} />
        <div style={{ fontWeight: 700, marginBottom: 6 }}>Per-field mandatory rules</div>
        <div className="hint" style={{ marginBottom: 10 }}>Micro-manage which fields are mandatory per voucher type. Unchecked = use the built-in default.</div>
        <div className="fg" style={{ marginBottom: 10 }}>
          <Field label="Voucher type" req={false}>
            <select className="ctl" value={frType} onChange={e => setFrType(e.target.value)}>
              {Object.keys(VOUCHERS).map(k => <option key={k} value={k}>{VOUCHERS[k].label || k}</option>)}
            </select>
          </Field>
        </div>
        <table className="tbl" style={{ maxWidth: 560 }}>
          <thead><tr><th style={{ textAlign: "left" }}>Field</th><th>Mandatory</th></tr></thead>
          <tbody>
            {[["vehicle", "Vehicle Number"], ["narration", "Narration"]].map(([f, lbl]) => {
              const t = fr[frType] || {}; const cur = f in t ? !!t[f] : null;
              const dflt = f === "vehicle" ? ["DEBIT_NOTE_RC","DC_OUT_JW","SALES_LOCAL","SCRAP_SALES","DEBIT_NOTE_DN"].includes(frType) : false;
              const eff = cur === null ? dflt : cur;
              return (<tr key={f}>
                <td style={{ textAlign: "left" }}>{lbl} {cur === null && <span className="hint">(default: {dflt ? "mandatory" : "optional"})</span>}</td>
                <td style={{ textAlign: "center" }}>
                  <input type="checkbox" checked={eff} onChange={e => {
                    const next = { ...fr, [frType]: { ...(fr[frType] || {}), [f]: e.target.checked } };
                    setFr(next); set("field_rules", JSON.stringify(next));
                  }} />
                </td>
              </tr>);
            })}
          </tbody>
        </table>
      </div>}

      {tab === "locations" && <div className="card-b">
        <div className="hint" style={{ marginBottom: 12 }}>Define your stores/units and tick which buckets are allowed at each. Vouchers are blocked at posting if a bucket isn't enabled at the chosen location. Use a Stock Transfer to move material between locations.</div>
        <div className="fg" style={{ marginBottom: 14 }}>
          <Field label="New Location Code" req={false}><input className="ctl" placeholder="e.g. FLOOR" value={newLoc.code} onChange={e => setNewLoc(s => ({ ...s, code: e.target.value }))} /></Field>
          <Field label="New Location Name" req={false}><input className="ctl" placeholder="e.g. Shop Floor" value={newLoc.name} onChange={e => setNewLoc(s => ({ ...s, name: e.target.value }))} /></Field>
          <div style={{ display: "flex", alignItems: "flex-end" }}><button className="btn" onClick={addLoc}>Add Location</button></div>
        </div>
        <table className="dt"><thead><tr><th>Location</th>{INT_BUCKETS.map(([k, l]) => <th key={k} className="num" title={l}>{k}</th>)}<th>Status</th></tr></thead>
          <tbody>{locs.map(l => <tr key={l.id}>
            <td><b>{l.loc_name}</b>{l.is_default ? <span className="pill on" style={{ marginLeft: 6 }}>default</span> : ""}{l.loc_code ? <span className="mono" style={{ color: "var(--muted)", marginLeft: 6 }}>{l.loc_code}</span> : ""}</td>
            {INT_BUCKETS.map(([k]) => <td key={k} className="num"><input type="checkbox" checked={(locBuckets[l.id] || []).includes(k)} onChange={() => toggleLocBucket(l.id, k)} /></td>)}
            <td><button className="btn ghost sm" onClick={() => toggleLocStatus(l)}>{l.status === "Active" ? "Active" : "Inactive"}</button></td>
          </tr>)}</tbody></table>
        {locs.length === 0 && <div className="empty">Loading…</div>}
      </div>}

      {tab === "vouchers" && <div className="card-b">
        <div className="hint" style={{ marginBottom: 12 }}>Disabled voucher types are blocked at posting time and can be hidden from the tiles.</div>
        <table className="dt"><thead><tr><th>Voucher Type</th><th>Status</th><th></th></tr></thead>
          <tbody>{vkeys.map(vt => { const on = venabled[vt] !== false; return <tr key={vt}><td>{VOUCHERS[vt].label}</td>
            <td><span className={"pill " + (on ? "on" : "off")}>{on ? "Enabled" : "Disabled"}</span></td>
            <td><button className="btn ghost sm" onClick={() => toggleVoucher(vt, !on)}>{on ? "Disable" : "Enable"}</button></td></tr>; })}</tbody></table>
      </div>}

      {tab === "columns" && <div className="card-b">
        <div className="hint" style={{ marginBottom: 12 }}>Choose which columns and checkboxes appear in the Database (Books) view for each voucher type, and their order.</div>
        <Field label="Voucher Type" req={false}><select className="ctl" style={{ maxWidth: 280 }} value={cfgType} onChange={e => setCfgType(e.target.value)}>{vkeys.map(vt => <option key={vt} value={vt}>{VOUCHERS[vt].label}</option>)}</select></Field>
        <table className="dt" style={{ marginTop: 14 }}><thead><tr><th>Column / Checkbox</th><th style={{ width: 110 }}>Visible</th><th style={{ width: 120 }}>Order</th></tr></thead>
          <tbody>{DB_COLS.slice().sort((a,b)=>(colCfg[a[0]]?.sort_order??0)-(colCfg[b[0]]?.sort_order??0)).map(([k,l]) => {
            const c = colCfg[k] || { visible: true }; return <tr key={k}><td>{l}</td>
              <td><label className="vd-flag"><input type="checkbox" checked={c.visible !== false} onChange={e => saveColVisible(k, e.target.checked)} /> {c.visible !== false ? "Shown" : "Hidden"}</label></td>
              <td><button className="btn ghost sm" onClick={() => moveCol(k, -1)}>↑</button>{" "}<button className="btn ghost sm" onClick={() => moveCol(k, 1)}>↓</button></td></tr>; })}</tbody></table>
      </div>}

      {tab === "storage" && <div className="card-b">
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 16 }}>
          <div>
            <div style={{ fontSize: 12, color: "var(--muted)", textTransform: "uppercase", letterSpacing: ".5px", fontWeight: 600 }}>Total Database Storage</div>
            <div style={{ fontSize: 32, fontWeight: 800, fontFamily: "var(--mono)" }}>{loadingS ? "…" : storage ? storage.total_pretty : "—"}</div>
          </div>
          <button className="btn ghost sm" onClick={loadStorage}>Refresh</button>
        </div>
        {tables.length > 0 && <table className="dt"><thead><tr><th>Table</th><th className="num">Rows (est.)</th><th className="num">Size</th><th style={{ width: "30%" }}>Share</th></tr></thead>
          <tbody>{tables.map(t => <tr key={t.table_name}><td className="mono">{t.table_name}</td><td className="num">{(+t.row_estimate).toLocaleString("en-IN")}</td><td className="num">{t.pretty}</td>
            <td><div style={{ background: "var(--panel-3)", borderRadius: 6, height: 10, overflow: "hidden" }}><div style={{ width: (maxBytes ? (100 * (+t.bytes) / maxBytes) : 0) + "%", background: "var(--accent)", height: "100%" }} /></div></td></tr>)}</tbody></table>}
        {!loadingS && tables.length === 0 && <div className="empty">No data.</div>}
        <div className="hint" style={{ marginTop: 12 }}>Sizes include table data, indexes and TOAST. Estimates come directly from PostgreSQL.</div>
      </div>}

      {tab === "cache" && <div className="card-b">
        <div className="hint" style={{ marginBottom: 14 }}>Clears this app's cached data in your browser — Cache Storage, IndexedDB, service workers and session storage — then reloads the page. It does not delete any database records. (Browsers don't allow a web page to wipe the entire browser cache, so this clears only what this app stored.)</div>
        <button className="btn" onClick={clearCache}>Clear App Cache &amp; Reload</button>
      </div>}

      {tab === "danger" && user?.role === "admin" && <div className="card-b">
        <div style={{ border: "1px solid #f0c2c2", background: "#fdf4f4", borderRadius: 10, padding: 18, maxWidth: 620 }}>
          <div style={{ fontWeight: 700, color: "#b3261e", fontSize: 15, marginBottom: 6 }}>⚠ Erase All Data</div>
          <p style={{ color: "#5a3838", lineHeight: 1.55, margin: "0 0 12px" }}>
            Permanently deletes <b>all transactions</b> (vouchers, stock ledger, lots, production logs)
            and <b>all master data</b> (parts, parties/ledgers, prices, machines). Stock balances reset to zero.
            <br /><b>Kept:</b> user accounts, access rights, app settings and configuration (buckets, locations).
            <br />This action <b>cannot be undone</b>. Back up your Supabase database first.
          </p>
          <div className="fg">
            <Field label={'Type "ERASE ALL DATA" to confirm'} req={false} wide>
              <input className="ctl" value={erConfirm} onChange={e => setErConfirm(e.target.value)} placeholder="ERASE ALL DATA" />
            </Field>
          </div>
          <button className="btn" disabled={erBusy || erConfirm !== "ERASE ALL DATA"}
            style={{ background: "#b3261e", borderColor: "#b3261e", color: "#fff", opacity: (erBusy || erConfirm !== "ERASE ALL DATA") ? 0.5 : 1 }}
            onClick={eraseData}>{erBusy ? "Erasing…" : "Erase All Data"}</button>
        </div>
      </div>}
    </div>
  </div>);
}

export function MachineConfig() {
  const [groups, setGroups] = useState([]); const [rows, setRows] = useState([]); const [msg, setMsg] = useState(null);
  const [f, setF] = useState({ id: null, part_group_id: "", machine: "", operation: "", sort_order: 0, op10: true, op20: true, op30: true });
  async function load() {
    const { data: g } = await supabase.rpc("list_part_groups"); setGroups(g || []);
    const { data } = await supabase.rpc("production_layout");
    const flat = (data || []).filter(r => r.machine_id).map(r => ({ id: r.machine_id, part_group_id: r.group_id, group_name: r.group_name, machine: r.machine, operation: r.operation, sort_order: r.sort_order, op10: r.op10_enabled, op20: r.op20_enabled, op30: r.op30_enabled }));
    setRows(flat);
  }
  useEffect(() => { load(); }, []);
  async function createGroup() { const name = window.prompt("New Part Group name:"); if (!name) return; const { error } = await supabase.rpc("create_part_group", { p_name: name }); if (error) return setMsg({ t: "err", m: error.message }); load(); }
  async function save() {
    if (!f.part_group_id || !f.machine.trim()) return setMsg({ t: "err", m: "Part Group and Machine are required." });
    const { error } = await supabase.rpc("mc_save", { p_id: f.id, p_group: f.part_group_id, p_machine: f.machine, p_operation: f.operation || null, p_sort: +f.sort_order || 0, p_op10: f.op10, p_op20: f.op20, p_op30: f.op30 });
    if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: "Saved." }); setF({ id: null, part_group_id: f.part_group_id, machine: "", operation: "", sort_order: 0, op10: true, op20: true, op30: true }); load();
  }
  async function del(id) { const { error } = await supabase.rpc("mc_delete", { p_id: id }); if (error) return setMsg({ t: "err", m: error.message }); load(); }
  return (<div className="wrap"><Msg msg={msg} />
    <div className="card"><div className="card-h"><h2>Machine Config — Production Log Layout</h2><button className="btn ghost sm" onClick={createGroup}>+ Part Group</button></div>
      <div className="card-b"><div className="hint" style={{ marginBottom: 12 }}>Part Groups become the tabs in Production Log; machines become the rows. The #10/#20/#30 checkboxes control which operation columns are editable for that machine.</div>
        <div className="fg">
          <Field label="Part Group"><select className="ctl" value={f.part_group_id} onChange={e => setF(s => ({ ...s, part_group_id: e.target.value }))}><option value="">— select —</option>{groups.map(g => <option key={g.id} value={g.id}>{g.group_name}</option>)}</select></Field>
          <Field label="Machine (M/C)"><input className="ctl" value={f.machine} onChange={e => setF(s => ({ ...s, machine: e.target.value }))} placeholder="VMC 10" /></Field>
          <Field label="Operation" req={false}><input className="ctl" value={f.operation} onChange={e => setF(s => ({ ...s, operation: e.target.value }))} /></Field>
          <Field label="Sort Order" req={false}><input className="ctl num" type="number" value={f.sort_order} onChange={e => setF(s => ({ ...s, sort_order: e.target.value }))} /></Field>
          <Field label="Operations Enabled" req={false}><div style={{ display: "flex", gap: 14, alignItems: "center", height: 42 }}>
            <label style={{ display: "flex", gap: 5, alignItems: "center" }}><input type="checkbox" checked={f.op10} onChange={e => setF(s => ({ ...s, op10: e.target.checked }))} />#10</label>
            <label style={{ display: "flex", gap: 5, alignItems: "center" }}><input type="checkbox" checked={f.op20} onChange={e => setF(s => ({ ...s, op20: e.target.checked }))} />#20</label>
            <label style={{ display: "flex", gap: 5, alignItems: "center" }}><input type="checkbox" checked={f.op30} onChange={e => setF(s => ({ ...s, op30: e.target.checked }))} />#30</label>
          </div></Field>
        </div>
      </div>
      <div className="row-actions"><button className="btn" onClick={save}>{f.id ? "Update" : "Add"} Machine</button>{f.id && <button className="btn ghost" onClick={() => setF({ id: null, part_group_id: f.part_group_id, machine: "", operation: "", sort_order: 0, op10: true, op20: true, op30: true })}>Cancel</button>}</div>
    </div>
    <div className="card"><div className="card-h"><h2>Configured Machines</h2></div>
      <div className="card-b" style={{ padding: 0 }}>{rows.length === 0 ? <div className="empty">No machines configured.</div>
        : <table className="dt"><thead><tr><th>Part Group</th><th>Machine</th><th>Operation</th><th>Sort</th><th>#10</th><th>#20</th><th>#30</th><th></th></tr></thead>
          <tbody>{rows.map(r => <tr key={r.id}><td>{r.group_name}</td><td><b>{r.machine}</b></td><td>{r.operation || "—"}</td><td>{r.sort_order}</td>
            <td>{r.op10 ? "✓" : "–"}</td><td>{r.op20 ? "✓" : "–"}</td><td>{r.op30 ? "✓" : "–"}</td>
            <td><button className="btn ghost sm" onClick={() => setF({ id: r.id, part_group_id: r.part_group_id, machine: r.machine, operation: r.operation || "", sort_order: r.sort_order || 0, op10: r.op10, op20: r.op20, op30: r.op30 })}>Edit</button>{" "}<button className="btn ghost sm" onClick={() => del(r.id)}>Delete</button></td></tr>)}</tbody></table>}
      </div>
    </div>
  </div>);
}

export function UndoTransactions({ user }) {
  const [rows, setRows] = useState([]); const [msg, setMsg] = useState(null); const [q, setQ] = useState("");
  async function load() { const { data } = await supabase.rpc("recent_transactions", { p_limit: 150 }); setRows(data || []); }
  useEffect(() => { load(); }, []);
  async function undo(id, no) { if (!window.confirm(`Undo ${no}? This cancels the voucher and reverses its stock.`)) return;
    const { data, error } = await supabase.rpc("undo_voucher", { p_id: id, p_user: user?.username, p_role: user?.role || "user" });
    if (error) return setMsg({ t: "err", m: error.message }); if (!data?.ok) return setMsg({ t: "err", m: data?.msg }); setMsg({ t: "ok", m: data.msg }); load(); }
  const shown = rows.filter(r => !q || `${r.voucher_id_code} ${r.voucher_no} ${r.voucher_type} ${r.ledger_name || ""} ${r.parts || ""}`.toLowerCase().includes(q.toLowerCase()));
  return (<div className="wrap"><Msg msg={msg} />
    <div className="card"><div className="card-h"><h2>Transaction Log</h2><input className="ctl" style={{ width: 220 }} placeholder="Search voucher / part / ledger…" value={q} onChange={e => setQ(e.target.value)} /></div>
      <div className="card-b" style={{ padding: 0 }}><div className="hint" style={{ padding: "10px 14px" }}>Admin only. Undoing cancels the voucher and reverses all its stock movements.</div>
        {shown.length === 0 ? <div className="empty">No transactions.</div>
          : <table className="dt"><thead><tr><th>Type</th><th>Voucher</th><th>Date</th><th>Ledger</th><th>Part(s)</th><th className="num">Qty</th><th className="num">Value</th><th>Status</th><th></th></tr></thead>
            <tbody>{shown.map(r => <tr key={r.id} style={r.cancelled ? { opacity: .5 } : null}><td>{r.voucher_type}</td><td className="mono">{r.voucher_no}</td><td>{toDMY(r.voucher_date)}</td><td>{r.ledger_name || "—"}</td><td style={{ maxWidth: 280, whiteSpace: "normal" }}>{r.parts || "—"}</td><td className="num">{money(r.total_qty)}</td><td className="num">{money(r.total_value)}</td>
              <td>{r.cancelled ? <span className="pill off">CANCELLED</span> : <span className="pill on">active</span>}</td>
              <td>{!r.cancelled && user?.role === "admin" && <button className="btn ghost sm" onClick={() => undo(r.id, r.voucher_no)}>Undo</button>}</td></tr>)}</tbody></table>}
      </div>
    </div>
  </div>);
}

export function AuditLog() {
  const [rows, setRows] = useState([]); const [q, setQ] = useState("");
  async function load() { const { data } = await supabase.rpc("audit_log_recent", { p_limit: 500 }); setRows(data || []); }
  useEffect(() => { load(); }, []);
  const shown = rows.filter(r => !q || `${r.action} ${r.app_user || ""} ${r.details || ""}`.toLowerCase().includes(q.toLowerCase()));
  return (<div className="wrap">
    <div className="card"><div className="card-h"><h2>Audit Log</h2><div style={{ display: "flex", gap: 8 }}><input className="ctl" style={{ width: 240 }} placeholder="Search action / user / details…" value={q} onChange={e => setQ(e.target.value)} /><button className="btn ghost sm" onClick={load}>Refresh</button></div></div>
      <div className="card-b" style={{ padding: 0, maxHeight: "70vh", overflow: "auto" }}>
        <div className="hint" style={{ padding: "10px 14px" }}>A timestamped record of every posting, edit, undo, price approval/rejection, mark request and period close — newest first. Entries appear here automatically as people use the system.</div>
        {shown.length === 0 ? <div className="empty">{q ? "No entries match your search." : "No activity recorded yet. Post or edit a voucher and it will appear here."}</div>
          : <table className="dt"><thead><tr><th>Timestamp</th><th>Action</th><th>User</th><th>Details</th></tr></thead>
            <tbody>{shown.map((r, i) => <tr key={i}><td className="mono">{new Date(r.ts).toLocaleString()}</td><td><b>{r.action}</b></td><td>{r.app_user || "—"}</td><td className="mono">{r.details || "—"}</td></tr>)}</tbody></table>}
      </div>
    </div>
  </div>);
}

export function PeriodClose({ user }) {
  const [closed, setClosed] = useState([]); const [msg, setMsg] = useState(null);
  const [month, setMonth] = useState(() => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`; });
  async function load() { const { data } = await supabase.rpc("closed_periods"); setClosed(data || []); }
  useEffect(() => { load(); }, []);
  async function doClose() {
    if (!month) return;
    const p = month + "-01";
    if (!window.confirm(`Close ${month}? Stock movements dated in this month will be refused afterward (admin can reopen).`)) return;
    const { data, error } = await supabase.rpc("close_period", { p_month: p, p_user: user?.username || "admin", p_note: null });
    if (error) return setMsg({ t: "err", m: error.message });
    setMsg({ t: "ok", m: `Closed ${data?.period} — ${data?.snapshot_rows} balances frozen.` }); load();
  }
  async function doReopen(pm) {
    if (!window.confirm(`Reopen ${new Date(pm).toLocaleDateString("en-IN", { month: "short", year: "numeric" })}? Movements in that month will be allowed again.`)) return;
    const { error } = await supabase.rpc("reopen_period", { p_month: pm, p_user: user?.username || "admin" });
    if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: "Reopened." }); load();
  }
  return (<div className="wrap"><Msg msg={msg} />
    <div className="card"><div className="card-h"><h2>Period Close</h2></div>
      <div className="card-b">
        <div className="hint" style={{ marginBottom: 12 }}>Closing a month freezes it: any voucher or production dated within a closed month is refused at posting. The closing balances become the locked opening for the next month. Closing is reversible by an admin.</div>
        <div className="fg">
          <Field label="Month to Close" req={false}><input className="ctl" type="month" value={month} onChange={e => setMonth(e.target.value)} /></Field>
          <div style={{ display: "flex", alignItems: "flex-end" }}><button className="btn" onClick={doClose}>Close Month</button></div>
        </div>
      </div>
    </div>
    <div className="card"><div className="card-h"><h2>Closed Periods</h2></div>
      <div className="card-b" style={{ padding: 0 }}>
        {closed.length === 0 ? <div className="empty">No periods closed yet.</div>
          : <table className="dt"><thead><tr><th>Month</th><th>Closed On</th><th>By</th><th></th></tr></thead>
            <tbody>{closed.map((c, i) => <tr key={i}>
              <td><b>{new Date(c.period_month).toLocaleDateString("en-IN", { month: "long", year: "numeric" })}</b></td>
              <td>{new Date(c.closed_at).toLocaleString()}</td><td>{c.closed_by || "—"}</td>
              <td><button className="btn ghost sm" onClick={() => doReopen(c.period_month)}>Reopen</button></td></tr>)}</tbody></table>}
      </div>
    </div>
  </div>);
}

export function StockTransfer({ user }) {
  const [parts, setParts] = useState([]); const [locs, setLocs] = useState([]); const [hist, setHist] = useState([]);
  const [f, setF] = useState({ part: "", bucket: "RC", from: "", to: "", qty: "", note: "" }); const [msg, setMsg] = useState(null);
  const BUCKETS = [["RC","Raw Casting"],["RCJW","RC@JW"],["CC","Coated Casting"],["MG","Machined Goods"],["PR","Process Rej."],["MR","Material Rej."],["JOBOUT","Sent Out"]];
  async function load() {
    const { data: p } = await supabase.from("part").select("id,part_code,part_name").eq("status", "Active").order("part_code"); setParts(p || []);
    const { data: l } = await supabase.rpc("list_locations", { p_active_only: true }); setLocs(l || []);
    const { data: h } = await supabase.rpc("stock_transfers", { p_limit: 100 }); setHist(h || []);
  }
  useEffect(() => { load(); }, []);
  async function submit() {
    if (!f.part || !f.from || !f.to || !(+f.qty > 0)) return setMsg({ t: "err", m: "Part, both locations, and a positive quantity are required." });
    if (f.from === f.to) return setMsg({ t: "err", m: "Source and destination must differ." });
    const { data, error } = await supabase.rpc("post_stock_transfer", { p_date: new Date().toISOString().slice(0, 10), p_part: f.part, p_bucket: f.bucket, p_from_loc: f.from, p_to_loc: f.to, p_qty: +f.qty, p_user: user?.username || "admin", p_note: f.note || null });
    if (error) { const m = /INSUFFICIENT/.test(error.message) ? "Not enough stock at the source location." : /NOT ALLOWED/.test(error.message) ? "That bucket isn't enabled at one of the locations." : error.message; return setMsg({ t: "err", m }); }
    setMsg({ t: "ok", m: `Transferred — ${data?.voucher_no}` }); setF(s => ({ ...s, qty: "", note: "" })); load();
  }
  return (<div className="wrap"><Msg msg={msg} />
    <div className="card"><div className="card-h"><h2>Stock Transfer</h2></div>
      <div className="card-b"><div className="fg">
        <Field label="Part"><select className="ctl" value={f.part} onChange={e => setF(s => ({ ...s, part: e.target.value }))}><option value="">— select —</option>{parts.map(p => <option key={p.id} value={p.id}>{p.part_code} · {p.part_name}</option>)}</select></Field>
        <Field label="Bucket"><select className="ctl" value={f.bucket} onChange={e => setF(s => ({ ...s, bucket: e.target.value }))}>{BUCKETS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
        <Field label="From Location"><select className="ctl" value={f.from} onChange={e => setF(s => ({ ...s, from: e.target.value }))}><option value="">— from —</option>{locs.map(l => <option key={l.id} value={l.id}>{l.loc_name}</option>)}</select></Field>
        <Field label="To Location"><select className="ctl" value={f.to} onChange={e => setF(s => ({ ...s, to: e.target.value }))}><option value="">— to —</option>{locs.map(l => <option key={l.id} value={l.id}>{l.loc_name}</option>)}</select></Field>
        <Field label="Quantity"><input className="ctl num" type="text" inputMode="numeric" value={f.qty} onChange={e => setF(s => ({ ...s, qty: e.target.value.replace(/[^\d.]/g, "") }))} /></Field>
        <Field label="Note" req={false}><input className="ctl" value={f.note} onChange={e => setF(s => ({ ...s, note: e.target.value }))} /></Field>
      </div>
      <div className="row-actions"><button className="btn" onClick={submit}>Post Transfer</button></div>
      </div>
    </div>
    <div className="card"><div className="card-h"><h2>Recent Transfers</h2></div>
      <div className="card-b" style={{ padding: 0, maxHeight: "50vh", overflow: "auto" }}>
        {hist.length === 0 ? <div className="empty">No transfers yet.</div>
          : <table className="dt"><thead><tr><th>Voucher</th><th>Date</th><th>Part</th><th>Bucket</th><th>From</th><th>To</th><th className="num">Qty</th></tr></thead>
            <tbody>{hist.map((h, i) => <tr key={i}><td className="mono">{h.voucher_no}</td><td>{toDMY(h.xfer_date)}</td><td>{h.part_code}</td><td><span className="bkt-tag">{h.bucket}</span></td><td>{h.from_loc}</td><td>{h.to_loc}</td><td className="num">{money(h.qty)}</td></tr>)}</tbody></table>}
      </div>
    </div>
  </div>);
}
