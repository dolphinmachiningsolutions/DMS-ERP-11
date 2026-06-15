DMS ERP — TEST RIG (two parts)
==============================
Both rigs are SCRATCH-DATABASE ONLY. They create test rows and do not
clean up (so you can inspect results). NEVER run on a DB with real data.

----------------------------------------------------------------------
1) test_rig.sql  — deep SQL rig (run in Supabase SQL Editor or psql)
----------------------------------------------------------------------
WHAT IT DOES
  Seeds its own master data, then exercises every business rule and
  prints a maximum-detail report:
    - DETAIL: every assertion with expected vs actual
    - CATEGORY BREAKDOWN: passed/failed/total per area
    - FAILURES ONLY: quick list of anything wrong
    - GRAND TOTAL: pass count + percentage

CATEGORIES COVERED
  SETUP, FY & NUMBERING (FY codes, DCJW fiscal month, RC-In number,
  valid-through/due-date calcs), WEIGHT PROFILE (RM-vendor averaging),
  STOCK FLOW (PO->Purchase->DC->RC In->Production->Sales with balance
  checks and PO/DC pending), GUARDRAILS (negative block, ledger seal,
  disabled-voucher block), PRICE PENDING (save-without-stock, approve,
  reject), OVERDUE DC (detect, block, clear), LEDGERS (part ledger
  running balance + stock journal), DASHBOARD, INTEGRITY, and a final
  HEALTH AUDIT (engine_health + reconcile_stock).

HOW TO RUN
  a) Spin up a SCRATCH database (or a throwaway Supabase project).
  b) Run schema_v14.sql once to install.
  c) Paste/run test_rig.sql. Read the report at the bottom.
  Expected on a correct build: 46 / 46 PASS (100%).

----------------------------------------------------------------------
2) test_rig_node.mjs  — Node runner (calls the same Supabase RPCs the
   web app uses, from your Mac terminal)
----------------------------------------------------------------------
WHY
  The SQL rig proves the database logic. The Node runner proves the
  SAME calls work through the Supabase RPC layer the app actually uses
  (auth, REST, argument marshalling) — catching anything that only
  breaks over the wire.

SETUP
  - Point it at a SCRATCH Supabase project that already has
    schema_v14.sql installed.
  - npm i @supabase/supabase-js
  - Run:
      SUPABASE_URL="https://YOURPROJECT.supabase.co" \
      SUPABASE_ANON_KEY="YOUR_ANON_KEY" \
      node test_rig_node.mjs
    (If you omit the env vars it tries to read them from src/lib/config.js.)

OUTPUT
  Same shape as the SQL rig: per-test PASS/FAIL, category breakdown,
  failures list, grand total, and the engine health/reconcile audit.
  Exit code 0 = all passed, 1 = some failed, 2 = could not run.

----------------------------------------------------------------------
READING RESULTS
  A FAIL prints expected vs actual so you can see exactly what broke.
  The HEALTH AUDIT lines (engine_health + reconcile) are the most
  important: if those ever FAIL, stock and ledger have diverged and
  the issue is serious. Everything else points at a specific rule.
