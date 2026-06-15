# DMS ERP V14.1 — Dolphin Machining Solutions
React + Vite + Supabase. Page-based ERP with full Production Log.

## Install
1. Supabase SQL Editor → paste ALL of `schema_v14.sql` → Run ONCE.
   (Resets the DB; only on a fresh DB / before real data.)
2. `npm install` then `npm run dev`.  Login: admin / admin123.

## Pages
- **Dashboard** — counts + live Stock Summary.
- **Vouchers** — Last Updated Status banner, then tiles grouped by heading.
  Opens the log/creation form (Production Log is the photo-style screen).
- **Books** — Open PO / DC / SO banner, then tiles → database grid (doc-control
  checkboxes, Edit / Mark-Del / Mark-Mod, query builder, sort, search,
  hide/show columns, sums).
- **Inventory** — Stock Summary · Stock Statement · Physical stock recon ·
  Part Ledger · Stock Ledger (all movements) · Opening Stock.
- **Database** — Ledger · Part (now with Part Group + Create) · Part Pricing ·
  Burr Generation Report.
- **Administration** — User Management (+ checkbox permissions) · Price Approval ·
  Rec Copy Approval · Mod & Del request · Settings (LOT toggles) ·
  Undo transactions · Machine Config (Production Log layout).

## Production Log (matches reference photo)
- Teal title + ID; Log Date; Shift = Day/Night radio; Supervisor 1/2 dropdowns.
- Tabs = Part Groups (from Machine Config). Under each tab, fixed machine rows
  (M/C down the left) with columns: Operator, Part, Lot (CC), #10/#20/#30,
  Set, Tool, B/D, Idle, Remarks. Only #10 (OP10) moves stock CC → WIPFG.
- Downtime / Breakdown log and Quality / Rejections log beneath, styled per photo.

## Setup order for Production
1. Database → Part: assign a **Part Group** (use + Create to add groups).
2. Administration → **Machine Config**: add machines under each Part Group
   (e.g. VMC 10, VMC 15 under "Torque Plate"). These become tabs + rows.
3. Vouchers → Production Log: tabs and rows appear automatically.

## Conventions
- Dates stored as DATE, shown DD/MM/YYYY everywhere. Money en-IN, commas, 2dp.
- Module + bucket names kept EXACT in code and UI.

## Notes
- Undo transactions (admin only) cancels a voucher and reverses its stock.
- RLS allows the anon key full access (internal use). Lock down before exposure.
