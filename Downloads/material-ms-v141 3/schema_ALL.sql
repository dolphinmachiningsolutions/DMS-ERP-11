-- =====================================================================
--  DMS ERP V13.0 — COMPLETE SCHEMA (all phases incl. Production)
--  Run this ENTIRE file ONCE in the Supabase SQL Editor.
--  Clean reset, then phases 1A → 8 in order. Fresh DB only.
-- =====================================================================

-- =====================================================================
--  DMS ERP V13.0 — CLEAN INSTALL (reset + full schema in one file)
--  Run this ENTIRE file once in the Supabase SQL Editor.
--  The reset wipes the old Phase 1/2 objects so nothing collides.
--  WARNING: this deletes everything in the public schema. Safe on a
--  fresh setup with no real data yet.
-- =====================================================================
drop schema if exists public cascade;
create schema public;
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all routines in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on routines to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- =====================================================================
--  DMS ERP V13.0 — SCHEMA  (Supabase / PostgreSQL)
--  Fresh, self-contained. Run in the Supabase SQL Editor.
--  Implements: bucket stock (BAL = GRS + VAR), stock & lot ledgers,
--  monthly price list, vendor/customer-part mappings, masters, and
--  all 13 voucher modules with bucket-to-bucket posting.
-- =====================================================================
create extension if not exists pgcrypto;

-- =====================================================================
--  AUTH (simple username + password; hashed via pgcrypto)
-- =====================================================================
create table if not exists app_users (
  id uuid primary key default gen_random_uuid(),
  username text unique not null,
  password text not null,
  role text not null default 'user' check (role in ('user','can_edit','admin')),
  created_at timestamptz default now()
);
create or replace function create_app_user(p_username text, p_password text, p_role text default 'user')
returns uuid as $$ declare i uuid; begin
  insert into app_users(username,password,role) values (p_username,crypt(p_password,gen_salt('bf')),p_role) returning id into i; return i;
end; $$ language plpgsql security definer;
create or replace function verify_login(p_username text, p_password text)
returns table(id uuid, username text, role text) as $$
  select id, username, role from app_users where username=p_username and password=crypt(p_password,password);
$$ language sql security definer;
select create_app_user('admin','admin123','admin');

-- =====================================================================
--  MASTERS
-- =====================================================================
-- Stock buckets (reference list)
create table if not exists buckets (
  code text primary key,          -- RC, RCCST, CC, WIPFG, PR, MRM, FGR, RWD, VENDOR, CUSTOMER
  name text not null,
  is_external boolean default false   -- VENDOR / CUSTOMER are outside-the-walls
);
insert into buckets(code,name,is_external) values
  ('RC','Raw Casting @ DMS',false),
  ('RCCST','Raw @ Crowntech Coating',false),
  ('CC','Coated Casting',false),
  ('WIPFG','WIP / Finished Goods',false),
  ('PR','Process Rejection',false),
  ('MRM','Material Rejection',false),
  ('FGR','FG Returns',false),
  ('RWD','Rework Declared',false),
  ('VENDOR','Vendor (external)',true),
  ('CUSTOMER','Customer (external)',true)
on conflict (code) do nothing;

-- Parties
create table if not exists parties (
  id uuid primary key default gen_random_uuid(),
  party_type text not null check (party_type in ('Customer','Vendor')),
  party_code text unique not null,
  gst_number text,
  party_name text not null,
  supply_of text check (supply_of in ('Raw Material','Job Work','Consumables')),
  territory text check (territory in ('Local','Interstate','I/E')),
  contact_email text,
  status text not null default 'Active' check (status in ('Active','Inactive')),
  created_at timestamptz default now()
);
create or replace function next_party_code(p_type text) returns text as $$
declare pre text; n int; begin
  pre := case p_type when 'Customer' then 'CMR' when 'Vendor' then 'RMV' else 'PTY' end;
  select coalesce(max(substring(party_code from 4)::int),0)+1 into n from parties where party_code like pre||'%';
  return pre||lpad(n::text,3,'0'); end; $$ language plpgsql;

-- Parts (products)
create table if not exists parts (
  id uuid primary key default gen_random_uuid(),
  part_code text unique not null,        -- PRDxxx
  part_name text not null,
  part_number text,
  uom text not null default 'Nos',
  machined_weight_pc numeric default 0,  -- used by Scrap Sales weight
  weight_allowance_pct numeric default 0,
  qty_variation numeric default 0,
  status text not null default 'Active' check (status in ('Active','Inactive')),
  created_at timestamptz default now()
);
create or replace function next_part_code() returns text as $$
declare n int; begin
  select coalesce(max(substring(part_code from 4)::int),0)+1 into n from parts where part_code like 'PRD%';
  return 'PRD'||lpad(n::text,3,'0'); end; $$ language plpgsql;

-- Vendor/Customer <-> Part mapping (form part lists filter on this)
create table if not exists master_vendor_parts (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid references parties(id) on delete cascade,
  part_id uuid references parts(id) on delete cascade,
  unique (vendor_id, part_id)
);
create table if not exists master_customer_parts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references parties(id) on delete cascade,
  part_id uuid references parts(id) on delete cascade,
  unique (customer_id, part_id)
);

-- Monthly price list (per part + entity + type, by month)
create table if not exists price_list (
  id uuid primary key default gen_random_uuid(),
  part_id uuid references parts(id) on delete cascade,
  entity_id uuid references parties(id) on delete cascade,
  price_type text not null check (price_type in ('purchase','sale')),
  month_key text not null,               -- 'Jun 2026'
  unit_price numeric not null default 0,
  unique (part_id, entity_id, price_type, month_key)
);

-- =====================================================================
--  STOCK: ledger + balances (BAL = GRS + VAR)
-- =====================================================================
create table if not exists stock_ledger (
  id uuid primary key default gen_random_uuid(),
  ledger_date date not null default current_date,
  part_id uuid references parts(id),
  from_bucket text references buckets(code),
  to_bucket text references buckets(code),
  qty numeric not null,
  voucher_id uuid,
  voucher_type text,
  voucher_no text,
  note text,
  created_at timestamptz default now()
);

-- physical reconciliation variance per part+bucket
create table if not exists stock_variance (
  part_id uuid references parts(id),
  bucket text references buckets(code),
  var_qty numeric not null default 0,
  primary key (part_id, bucket)
);

-- GRS (gross) live view: opening(0) + inward - outward, per internal bucket
create or replace view stock_grs as
select p.id as part_id, b.code as bucket,
  coalesce((select sum(qty) from stock_ledger l where l.part_id=p.id and l.to_bucket=b.code),0)
  - coalesce((select sum(qty) from stock_ledger l where l.part_id=p.id and l.from_bucket=b.code),0) as grs
from parts p cross join buckets b where b.is_external=false;

-- BAL view = GRS + VAR
create or replace view stock_balance as
select g.part_id, g.bucket, g.grs,
  coalesce(v.var_qty,0) as var_qty,
  g.grs + coalesce(v.var_qty,0) as bal
from stock_grs g
left join stock_variance v on v.part_id=g.part_id and v.bucket=g.bucket;

-- checkStockAvailability: returns BAL for a part+bucket
create or replace function check_stock(p_part uuid, p_bucket text)
returns numeric as $$
  select coalesce((select bal from stock_balance where part_id=p_part and bucket=p_bucket),0);
$$ language sql;

-- getMonthlyPrice
create or replace function get_monthly_price(p_part uuid, p_entity uuid, p_type text, p_date date)
returns numeric as $$
  select coalesce((select unit_price from price_list
    where part_id=p_part and entity_id=p_entity and price_type=p_type
      and month_key=to_char(p_date,'Mon YYYY')),0);
$$ language sql;

-- =====================================================================
--  LOT ENGINE
-- =====================================================================
create table if not exists lot_master (
  id uuid primary key default gen_random_uuid(),
  lot_no text unique not null,
  part_id uuid references parts(id),
  vendor_id uuid references parties(id),
  current_bucket text references buckets(code),
  created_at timestamptz default now()
);
create table if not exists lot_ledger (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid references lot_master(id),
  from_bucket text, to_bucket text, qty numeric,
  voucher_id uuid, voucher_type text, created_at timestamptz default now()
);

-- =====================================================================
--  VOUCHERS — generic header + lines (covers all 13 modules)
--  Per-module extra fields live in line/header JSON where rare, but the
--  common, queried fields are real columns.
-- =====================================================================
create table if not exists vouchers (
  id uuid primary key default gen_random_uuid(),
  voucher_type text not null,            -- see app VOUCHERS keys
  voucher_no text not null,
  voucher_period text,                   -- 'Jun 2026'
  voucher_date date not null default current_date,
  posting_date date,
  valid_thru date,
  party_id uuid references parties(id),
  ref_no text,
  ref_voucher_id uuid references vouchers(id),
  remarks text,
  status text default 'OPEN',
  cancelled boolean default false,
  approved_mgmt text default 'APPROVED', -- or 'PENDING' via rec-copy gate
  gstr_flag boolean default false,
  created_by text,
  created_at timestamptz default now(),
  unique (voucher_type, voucher_no)
);
create table if not exists voucher_lines (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid references vouchers(id) on delete cascade,
  sno int,
  part_id uuid references parts(id),
  lot_id uuid references lot_master(id),
  ref_no text,                           -- per-line PO/SO/DC ref
  qty numeric default 0,
  invoice_qty numeric default 0,
  actual_qty numeric default 0,
  uom text default 'Nos',
  unit_price numeric default 0,
  basic_value numeric default 0,
  weight numeric default 0,
  defect_type text, root_cause text,
  line_note text
);

create or replace function next_voucher_no(p_type text) returns text as $$
declare pre text; n int; begin
  pre := case p_type
    when 'PURCHASE_ORDER' then 'PO' when 'RM_PURCHASE' then 'PUR'
    when 'DEBIT_NOTE_RC' then 'DNRC' when 'JW_DC_OUT' then 'DCO'
    when 'JW_RC_IN' then 'CST' when 'SALES_ORDER' then 'SO'
    when 'SALES' then 'SAL' when 'CREDIT_NOTE' then 'CN'
    when 'PRODUCTION' then 'PRD-LOG' when 'PROCESS_REJECTION' then 'PRJ'
    when 'MATERIAL_REJECTION' then 'MRJ' when 'SALES_PROC_REJ' then 'SCR'
    when 'DEBIT_NOTE_MAT' then 'DNM' else 'VCH' end;
  select coalesce(max(nullif(regexp_replace(voucher_no,'^.*[-/]',''),'')::int),0)+1
    into n from vouchers where voucher_type=p_type;
  if n is null then n:=1; end if;
  return pre||'-'||lpad(n::text,5,'0'); end; $$ language plpgsql;

-- =====================================================================
--  POST A VOUCHER  — header + lines + bucket stock ledger
--  Stock map per module (from -> to). External = VENDOR/CUSTOMER.
-- =====================================================================
create or replace function post_voucher(
  p_type text, p_no text, p_date date, p_posting date, p_valid date,
  p_party uuid, p_ref_voucher uuid, p_ref_no text, p_remarks text,
  p_user text, p_lines jsonb
) returns uuid as $$
declare
  v_id uuid; ln jsonb; i int := 0;
  from_b text; to_b text; move_date date; on_hand numeric;
begin
  insert into vouchers(voucher_type,voucher_no,voucher_period,voucher_date,posting_date,
    valid_thru,party_id,ref_voucher_id,ref_no,remarks,created_by)
  values (p_type,p_no,to_char(p_date,'Mon YYYY'),p_date,p_posting,p_valid,
    p_party,p_ref_voucher,p_ref_no,p_remarks,p_user)
  returning id into v_id;

  -- bucket map
  from_b := null; to_b := null;
  case p_type
    when 'RM_PURCHASE'        then from_b:='VENDOR';  to_b:='RC';
    when 'DEBIT_NOTE_RC'      then from_b:='RC';      to_b:='VENDOR';
    when 'JW_DC_OUT'          then from_b:='RC';      to_b:='RCCST';
    when 'JW_RC_IN'           then from_b:='RCCST';   to_b:='CC';
    when 'PRODUCTION'         then from_b:='CC';      to_b:='WIPFG';  -- OP10 only (handled by caller sending OP10 qty)
    when 'SALES'              then from_b:='WIPFG';   to_b:='CUSTOMER';
    when 'CREDIT_NOTE'        then from_b:='CUSTOMER';to_b:='FGR';
    when 'PROCESS_REJECTION'  then from_b:='WIPFG';   to_b:='PR';
    when 'MATERIAL_REJECTION' then from_b:='WIPFG';   to_b:='MRM';
    when 'SALES_PROC_REJ'     then from_b:='PR';      to_b:='CUSTOMER';
    when 'DEBIT_NOTE_MAT'     then from_b:='MRM';     to_b:='VENDOR';
    else from_b:=null; to_b:=null;   -- PURCHASE_ORDER, SALES_ORDER: no stock
  end case;

  move_date := coalesce(p_posting, p_date);

  for ln in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    insert into voucher_lines(voucher_id,sno,part_id,lot_id,ref_no,qty,invoice_qty,actual_qty,
      uom,unit_price,basic_value,weight,defect_type,root_cause,line_note)
    values (v_id,i,(ln->>'part_id')::uuid,nullif(ln->>'lot_id','')::uuid,ln->>'ref_no',
      coalesce((ln->>'qty')::numeric,0),coalesce((ln->>'invoice_qty')::numeric,0),
      coalesce((ln->>'actual_qty')::numeric,0),coalesce(ln->>'uom','Nos'),
      coalesce((ln->>'unit_price')::numeric,0),coalesce((ln->>'basic_value')::numeric,0),
      coalesce((ln->>'weight')::numeric,0),ln->>'defect_type',ln->>'root_cause',ln->>'line_note');

    if from_b is not null then
      -- internal-source stock check (skip if source is external VENDOR/CUSTOMER)
      if from_b not in ('VENDOR','CUSTOMER') then
        on_hand := check_stock((ln->>'part_id')::uuid, from_b);
        if on_hand < coalesce((ln->>'qty')::numeric,0) then
          raise exception '% blocked for part: % balance %, requested %',
            p_type, from_b, on_hand, (ln->>'qty')::numeric;
        end if;
      end if;
      insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
      values (move_date,(ln->>'part_id')::uuid,from_b,to_b,coalesce((ln->>'qty')::numeric,0),v_id,p_type,p_no,p_remarks);
    end if;
  end loop;

  return v_id;
end; $$ language plpgsql security definer;

-- =====================================================================
--  RLS (Phase: anon key full access; tighten later)
-- =====================================================================
do $$ declare t text; begin
  foreach t in array array['app_users','parties','parts','master_vendor_parts',
    'master_customer_parts','price_list','stock_ledger','stock_variance',
    'lot_master','lot_ledger','vouchers','voucher_lines','buckets'] loop
    execute format('alter table %I enable row level security;', t);
    execute format('drop policy if exists pol_%s on %I;', t, t);
    if t <> 'app_users' then
      execute format('create policy pol_%s on %I for all using (true) with check (true);', t, t);
    end if;
  end loop;
end $$;
-- =====================================================================
--  DMS ERP V13.0 — PHASE 1A: STOCK SUMMARY ENGINE + PHYSICAL STOCK
--  Run AFTER schema_v13.sql (or its clean-install variant).
--  Adds: opening stock, physical reconciliation (cumulative VAR),
--  expanded per-bucket breakdown, and reconciliation posting.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. OPENING STOCK  (per part + bucket)  — folds into GRS
-- ---------------------------------------------------------------------
create table if not exists opening_stock (
  part_id uuid references parts(id) on delete cascade,
  bucket text references buckets(code),
  qty numeric not null default 0,
  primary key (part_id, bucket)
);

-- ---------------------------------------------------------------------
-- 2. PHYSICAL STOCK reconciliation rows.
--    Each row records a counted physical qty vs system qty at a date.
--    VARIANCE = physical - system. Stock VAR = cumulative sum of these.
-- ---------------------------------------------------------------------
create table if not exists physical_stock (
  id uuid primary key default gen_random_uuid(),
  recon_date date not null default current_date,
  part_id uuid references parts(id),
  bucket text references buckets(code),
  system_qty numeric not null default 0,
  physical_qty numeric not null default 0,
  variance numeric not null default 0,        -- physical - system
  remarks text,
  created_by text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 3. Redefine GRS to INCLUDE opening stock.
--    GRS = opening + inwards(to_bucket) - outwards(from_bucket)
-- ---------------------------------------------------------------------
create or replace view stock_grs as
select p.id as part_id, b.code as bucket,
  coalesce((select qty from opening_stock o where o.part_id=p.id and o.bucket=b.code),0)
  + coalesce((select sum(qty) from stock_ledger l where l.part_id=p.id and l.to_bucket=b.code),0)
  - coalesce((select sum(qty) from stock_ledger l where l.part_id=p.id and l.from_bucket=b.code),0) as grs
from parts p cross join buckets b where b.is_external=false;

-- ---------------------------------------------------------------------
-- 4. VAR = cumulative physical variance per part+bucket (live).
--    Replaces the manual stock_variance table as the source of truth,
--    but we keep BAL reading from a unified variance source.
-- ---------------------------------------------------------------------
create or replace view stock_var as
select p.id as part_id, b.code as bucket,
  coalesce((select sum(variance) from physical_stock ps where ps.part_id=p.id and ps.bucket=b.code),0)
  + coalesce((select var_qty from stock_variance v where v.part_id=p.id and v.bucket=b.code),0) as var_qty
from parts p cross join buckets b where b.is_external=false;

-- ---------------------------------------------------------------------
-- 5. BAL view = GRS + VAR  (single enforcement point)
-- ---------------------------------------------------------------------
create or replace view stock_balance as
select g.part_id, g.bucket, g.grs,
  coalesce(v.var_qty,0) as var_qty,
  g.grs + coalesce(v.var_qty,0) as bal
from stock_grs g
left join stock_var v on v.part_id=g.part_id and v.bucket=g.bucket;

-- check_stock already reads stock_balance.bal — unchanged, still valid.

-- ---------------------------------------------------------------------
-- 6. STOCK SUMMARY breakdown view (the DB_STOCK_SUMMARY grid).
--    One row per active part with, per bucket: OPEN, inwards, outwards,
--    GRS, VAR, BAL. Inward/outward are derived from the ledger by
--    bucket role, so it survives new voucher types automatically.
-- ---------------------------------------------------------------------
create or replace view stock_summary as
with led as (
  select part_id,
    -- inward into each bucket
    sum(qty) filter (where to_bucket='RC')    as rc_in,
    sum(qty) filter (where from_bucket='RC')   as rc_out,
    sum(qty) filter (where to_bucket='RCCST')  as rccst_in,
    sum(qty) filter (where from_bucket='RCCST') as rccst_out,
    sum(qty) filter (where to_bucket='CC')     as cc_in,
    sum(qty) filter (where from_bucket='CC')    as cc_out,
    sum(qty) filter (where to_bucket='WIPFG')  as wipfg_in,
    sum(qty) filter (where from_bucket='WIPFG') as wipfg_out,
    sum(qty) filter (where to_bucket='PR')     as pr_in,
    sum(qty) filter (where from_bucket='PR')    as pr_out,
    sum(qty) filter (where to_bucket='MRM')    as mrm_in,
    sum(qty) filter (where from_bucket='MRM')   as mrm_out,
    sum(qty) filter (where to_bucket='FGR')    as fgr_in,
    sum(qty) filter (where from_bucket='FGR')   as fgr_out,
    sum(qty) filter (where to_bucket='RWD')    as rwd_in,
    sum(qty) filter (where from_bucket='RWD')   as rwd_out
  from stock_ledger group by part_id
)
select p.id as part_id, p.part_code, p.part_name,
  bal_rc.bal as rc_bal, bal_rccst.bal as rccst_bal, bal_cc.bal as cc_bal,
  bal_wipfg.bal as wipfg_bal, bal_pr.bal as pr_bal, bal_mrm.bal as mrm_bal,
  bal_fgr.bal as fgr_bal, bal_rwd.bal as rwd_bal,
  coalesce(l.rc_in,0) rc_in, coalesce(l.rc_out,0) rc_out,
  coalesce(l.cc_in,0) cc_in, coalesce(l.cc_out,0) cc_out,
  coalesce(l.wipfg_in,0) wipfg_in, coalesce(l.wipfg_out,0) wipfg_out
from parts p
left join led l on l.part_id=p.id
left join stock_balance bal_rc    on bal_rc.part_id=p.id    and bal_rc.bucket='RC'
left join stock_balance bal_rccst on bal_rccst.part_id=p.id and bal_rccst.bucket='RCCST'
left join stock_balance bal_cc    on bal_cc.part_id=p.id    and bal_cc.bucket='CC'
left join stock_balance bal_wipfg on bal_wipfg.part_id=p.id and bal_wipfg.bucket='WIPFG'
left join stock_balance bal_pr    on bal_pr.part_id=p.id    and bal_pr.bucket='PR'
left join stock_balance bal_mrm   on bal_mrm.part_id=p.id   and bal_mrm.bucket='MRM'
left join stock_balance bal_fgr   on bal_fgr.part_id=p.id   and bal_fgr.bucket='FGR'
left join stock_balance bal_rwd   on bal_rwd.part_id=p.id   and bal_rwd.bucket='RWD'
where p.status='Active';

-- ---------------------------------------------------------------------
-- 7. getStockForReconciliation — current BAL for every active part+bucket
-- ---------------------------------------------------------------------
create or replace function get_recon_grid()
returns table(part_id uuid, part_code text, part_name text, bucket text, system_qty numeric) as $$
  select p.id, p.part_code, p.part_name, b.code, check_stock(p.id, b.code)
  from parts p cross join buckets b
  where p.status='Active' and b.is_external=false
  order by p.part_code, b.code;
$$ language sql;

-- ---------------------------------------------------------------------
-- 8. processStockReconciliation — saves counted rows; variance = phys - sys.
--    p_rows: [{"part_id":..,"bucket":"RC","physical_qty":10}, ...]
--    Only rows where physical differs from system are stored (others skipped).
-- ---------------------------------------------------------------------
create or replace function post_reconciliation(p_date date, p_user text, p_rows jsonb)
returns int as $$
declare r jsonb; sys numeric; phys numeric; n int := 0;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    sys := check_stock((r->>'part_id')::uuid, r->>'bucket');
    phys := coalesce((r->>'physical_qty')::numeric, sys);
    if phys <> sys then
      insert into physical_stock(recon_date,part_id,bucket,system_qty,physical_qty,variance,remarks,created_by)
      values (p_date,(r->>'part_id')::uuid,r->>'bucket',sys,phys,phys-sys,r->>'remarks',p_user);
      n := n + 1;
    end if;
  end loop;
  return n;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 9. RLS for new tables
-- ---------------------------------------------------------------------
alter table opening_stock  enable row level security;
alter table physical_stock enable row level security;
drop policy if exists pol_opening on opening_stock;
drop policy if exists pol_physical on physical_stock;
create policy pol_opening  on opening_stock  for all using (true) with check (true);
create policy pol_physical on physical_stock for all using (true) with check (true);
-- =====================================================================
--  DMS ERP V13.0 — PHASE 2: LOT ENGINE
--  Run AFTER schema_v13.sql and schema_phase1a.sql.
--  Adds: lot number generation, lot balance, available-lot picker,
--  lot-wise stock view, and lot creation/consumption wired into
--  post_voucher (RM Purchase creates lots; consumers move them).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Extend lot_master with origin qty (spec DB_LOT_MASTER.ORIGINAL_QTY)
-- ---------------------------------------------------------------------
alter table lot_master add column if not exists original_qty numeric default 0;
alter table lot_master add column if not exists ref_voucher text;
alter table lot_ledger  add column if not exists voucher_no text;

-- ---------------------------------------------------------------------
-- 2. generateLotNo — PART-VENDORCODE-NNN (sequence per part+vendor)
-- ---------------------------------------------------------------------
create or replace function next_lot_no(p_part uuid, p_vendor uuid)
returns text as $$
declare part_code text; vcode text; n int;
begin
  select pc.part_code into part_code from parts pc where pc.id = p_part;
  select upper(left(regexp_replace(pa.party_name,'[^A-Za-z0-9]','','g'),6)) into vcode
    from parties pa where pa.id = p_vendor;
  vcode := coalesce(nullif(vcode,''),'VEN');
  select coalesce(max(nullif(regexp_replace(lot_no,'^.*-',''),'')::int),0)+1 into n
    from lot_master where part_id=p_part and vendor_id=p_vendor;
  if n is null then n := 1; end if;
  return coalesce(part_code,'PRD') || '-' || vcode || '-' || lpad(n::text,3,'0');
end; $$ language plpgsql;

-- ---------------------------------------------------------------------
-- 3. getLotBalance — qty of a lot currently in a bucket (to - from)
-- ---------------------------------------------------------------------
create or replace function lot_balance(p_lot uuid, p_bucket text)
returns numeric as $$
  select coalesce((select sum(qty) from lot_ledger where lot_id=p_lot and to_bucket=p_bucket),0)
       - coalesce((select sum(qty) from lot_ledger where lot_id=p_lot and from_bucket=p_bucket),0);
$$ language sql;

-- ---------------------------------------------------------------------
-- 4. getAvailableLots — lots of a part with positive balance in a bucket,
--    oldest-first, with vendor name. Powers the picker dropdowns.
-- ---------------------------------------------------------------------
create or replace function available_lots(p_part uuid, p_bucket text)
returns table(lot_id uuid, lot_no text, vendor text, available numeric, origin_date date) as $$
  select m.id, m.lot_no, pa.party_name, lot_balance(m.id, p_bucket), m.created_at::date
  from lot_master m
  left join parties pa on pa.id = m.vendor_id
  where m.part_id = p_part and lot_balance(m.id, p_bucket) > 0
  order by m.created_at asc;
$$ language sql;

-- ---------------------------------------------------------------------
-- 5. getLotWiseStock — every lot's balance across all internal buckets
-- ---------------------------------------------------------------------
create or replace view lot_wise_stock as
select m.id as lot_id, m.lot_no, p.part_code, p.part_name,
  pa.party_name as vendor, m.created_at::date as origin_date,
  lot_balance(m.id,'RC') rc, lot_balance(m.id,'RCCST') rccst, lot_balance(m.id,'CC') cc,
  lot_balance(m.id,'WIPFG') wipfg, lot_balance(m.id,'PR') pr, lot_balance(m.id,'MRM') mrm,
  lot_balance(m.id,'FGR') fgr, lot_balance(m.id,'RWD') rwd,
  (lot_balance(m.id,'RC')+lot_balance(m.id,'RCCST')+lot_balance(m.id,'CC')+lot_balance(m.id,'WIPFG')
   +lot_balance(m.id,'PR')+lot_balance(m.id,'MRM')+lot_balance(m.id,'FGR')+lot_balance(m.id,'RWD')) as total
from lot_master m
join parts p on p.id = m.part_id
left join parties pa on pa.id = m.vendor_id;

-- ---------------------------------------------------------------------
-- 6. Rebuild post_voucher with lot handling.
--    - RM_PURCHASE: each line with a qty creates a vendor-tagged lot in RC.
--    - Consumers (lines carrying lot_id): consume that lot from->to,
--      validated against lot_balance; aborts the txn if insufficient.
-- ---------------------------------------------------------------------
create or replace function post_voucher(
  p_type text, p_no text, p_date date, p_posting date, p_valid date,
  p_party uuid, p_ref_voucher uuid, p_ref_no text, p_remarks text,
  p_user text, p_lines jsonb
) returns uuid as $$
declare
  v_id uuid; ln jsonb; i int := 0;
  from_b text; to_b text; move_date date; on_hand numeric;
  lid uuid; new_lot_no text; lbal numeric; lqty numeric;
begin
  insert into vouchers(voucher_type,voucher_no,voucher_period,voucher_date,posting_date,
    valid_thru,party_id,ref_voucher_id,ref_no,remarks,created_by)
  values (p_type,p_no,to_char(p_date,'Mon YYYY'),p_date,p_posting,p_valid,
    p_party,p_ref_voucher,p_ref_no,p_remarks,p_user)
  returning id into v_id;

  case p_type
    when 'RM_PURCHASE'        then from_b:='VENDOR';  to_b:='RC';
    when 'DEBIT_NOTE_RC'      then from_b:='RC';      to_b:='VENDOR';
    when 'JW_DC_OUT'          then from_b:='RC';      to_b:='RCCST';
    when 'JW_RC_IN'           then from_b:='RCCST';   to_b:='CC';
    when 'PRODUCTION'         then from_b:='CC';      to_b:='WIPFG';
    when 'SALES'              then from_b:='WIPFG';   to_b:='CUSTOMER';
    when 'CREDIT_NOTE'        then from_b:='CUSTOMER';to_b:='FGR';
    when 'PROCESS_REJECTION'  then from_b:='WIPFG';   to_b:='PR';
    when 'MATERIAL_REJECTION' then from_b:='WIPFG';   to_b:='MRM';
    when 'SALES_PROC_REJ'     then from_b:='PR';      to_b:='CUSTOMER';
    when 'DEBIT_NOTE_MAT'     then from_b:='MRM';     to_b:='VENDOR';
    when 'REWORK_DECL'        then from_b:='WIPFG';   to_b:='RWD';
    when 'REWORK_COMP'        then from_b:='RWD';     to_b:='WIPFG';
    else from_b:=null; to_b:=null;
  end case;

  move_date := coalesce(p_posting, p_date);

  for ln in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    lqty := coalesce((ln->>'qty')::numeric,0);
    insert into voucher_lines(voucher_id,sno,part_id,lot_id,ref_no,qty,invoice_qty,actual_qty,
      uom,unit_price,basic_value,weight,defect_type,root_cause,line_note)
    values (v_id,i,(ln->>'part_id')::uuid,nullif(ln->>'lot_id','')::uuid,ln->>'ref_no',
      lqty,coalesce((ln->>'invoice_qty')::numeric,0),coalesce((ln->>'actual_qty')::numeric,0),
      coalesce(ln->>'uom','Nos'),coalesce((ln->>'unit_price')::numeric,0),
      coalesce((ln->>'basic_value')::numeric,0),coalesce((ln->>'weight')::numeric,0),
      ln->>'defect_type',ln->>'root_cause',ln->>'line_note');

    if from_b is not null then
      -- bucket-level stock check for internal sources
      if from_b not in ('VENDOR','CUSTOMER') then
        on_hand := check_stock((ln->>'part_id')::uuid, from_b);
        if on_hand < lqty then
          raise exception '% blocked for part: % balance %, requested %', p_type, from_b, on_hand, lqty;
        end if;
      end if;

      -- stock ledger movement
      insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
      values (move_date,(ln->>'part_id')::uuid,from_b,to_b,lqty,v_id,p_type,p_no,p_remarks);

      -- LOT handling
      if p_type = 'RM_PURCHASE' and lqty > 0 then
        -- create a new vendor-tagged lot in RC
        new_lot_no := next_lot_no((ln->>'part_id')::uuid, p_party);
        insert into lot_master(lot_no,part_id,vendor_id,current_bucket,original_qty,ref_voucher)
        values (new_lot_no,(ln->>'part_id')::uuid,p_party,'RC',lqty,p_no)
        returning id into lid;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values (lid,'VENDOR','RC',lqty,v_id,p_type,p_no);

      elsif nullif(ln->>'lot_id','') is not null then
        -- consume the chosen lot from_b -> to_b
        lid := (ln->>'lot_id')::uuid;
        lbal := lot_balance(lid, from_b);
        if lbal < lqty then
          raise exception 'Lot has insufficient balance in %: have %, need %', from_b, lbal, lqty;
        end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values (lid,from_b,to_b,lqty,v_id,p_type,p_no);
        update lot_master set current_bucket = to_b where id = lid;
      end if;
    end if;
  end loop;

  return v_id;
end; $$ language plpgsql security definer;
-- =====================================================================
--  DMS ERP V13.0 — PHASE 3: REMAINING MODULES
--  Run AFTER schema_phase2_lots.sql.
--  Adds source-bucket-driven posting for the DC Out / RC In variants
--  (Returnable, Non-Returnable, Replace) and keeps Rework working.
--
--  These modules don't have a fixed from->to in code; the user picks a
--  SOURCE bucket on each line. So post_voucher accepts an optional
--  per-line "source_bucket" and "dest" override.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Rebuild post_voucher to support per-line source/destination override.
-- Fixed-flow modules behave exactly as before (override ignored when the
-- type has a hardcoded map). Variant modules pass src/dest per line.
--
-- Variant flow rules:
--   DC_OUT_RET / DC_OUT_NONRET / DC_OUT_REPLACE : SOURCE -> 'JOBOUT' (out)
--   RC_IN_RET  / RC_IN_REPLACE                  : 'JOBOUT' -> SOURCE (in)
-- We model "sent out / not on-site" as the JOBOUT holding bucket so stock
-- leaves the source bucket on DC Out and returns to it on RC In.
-- ---------------------------------------------------------------------

-- add JOBOUT holding bucket (material physically off-site, returnable)
insert into buckets(code,name,is_external) values ('JOBOUT','Sent Out (returnable)',false)
on conflict (code) do nothing;

create or replace function post_voucher(
  p_type text, p_no text, p_date date, p_posting date, p_valid date,
  p_party uuid, p_ref_voucher uuid, p_ref_no text, p_remarks text,
  p_user text, p_lines jsonb
) returns uuid as $$
declare
  v_id uuid; ln jsonb; i int := 0;
  from_b text; to_b text; move_date date; on_hand numeric;
  lid uuid; new_lot_no text; lbal numeric; lqty numeric;
  is_variant boolean := false; src text; variant_dir text;
begin
  insert into vouchers(voucher_type,voucher_no,voucher_period,voucher_date,posting_date,
    valid_thru,party_id,ref_voucher_id,ref_no,remarks,created_by,status)
  values (p_type,p_no,to_char(p_date,'Mon YYYY'),p_date,p_posting,p_valid,
    p_party,p_ref_voucher,p_ref_no,p_remarks,p_user,'OPEN')
  returning id into v_id;

  -- fixed-flow map
  case p_type
    when 'RM_PURCHASE'        then from_b:='VENDOR';  to_b:='RC';
    when 'DEBIT_NOTE_RC'      then from_b:='RC';      to_b:='VENDOR';
    when 'JW_DC_OUT'          then from_b:='RC';      to_b:='RCCST';
    when 'JW_RC_IN'           then from_b:='RCCST';   to_b:='CC';
    when 'PRODUCTION'         then from_b:='CC';      to_b:='WIPFG';
    when 'SALES'              then from_b:='WIPFG';   to_b:='CUSTOMER';
    when 'CREDIT_NOTE'        then from_b:='CUSTOMER';to_b:='FGR';
    when 'PROCESS_REJECTION'  then from_b:='WIPFG';   to_b:='PR';
    when 'MATERIAL_REJECTION' then from_b:='WIPFG';   to_b:='MRM';
    when 'SALES_PROC_REJ'     then from_b:='PR';      to_b:='CUSTOMER';
    when 'DEBIT_NOTE_MAT'     then from_b:='MRM';     to_b:='VENDOR';
    when 'REWORK_DECL'        then from_b:='WIPFG';   to_b:='RWD';
    when 'REWORK_COMP'        then from_b:='RWD';     to_b:='WIPFG';
    else from_b:=null; to_b:=null;
  end case;

  -- variant detection
  if p_type in ('DC_OUT_RET','DC_OUT_NONRET','DC_OUT_REPLACE') then
    is_variant := true; variant_dir := 'OUT';
  elsif p_type in ('RC_IN_RET','RC_IN_REPLACE') then
    is_variant := true; variant_dir := 'IN';
  end if;

  move_date := coalesce(p_posting, p_date);

  for ln in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    lqty := coalesce((ln->>'qty')::numeric,0);
    src := nullif(ln->>'source_bucket','');

    insert into voucher_lines(voucher_id,sno,part_id,lot_id,ref_no,qty,invoice_qty,actual_qty,
      uom,unit_price,basic_value,weight,defect_type,root_cause,line_note)
    values (v_id,i,(ln->>'part_id')::uuid,nullif(ln->>'lot_id','')::uuid,ln->>'ref_no',
      lqty,coalesce((ln->>'invoice_qty')::numeric,0),coalesce((ln->>'actual_qty')::numeric,0),
      coalesce(ln->>'uom','Nos'),coalesce((ln->>'unit_price')::numeric,0),
      coalesce((ln->>'basic_value')::numeric,0),coalesce((ln->>'weight')::numeric,0),
      ln->>'defect_type',ln->>'root_cause',ln->>'line_note');

    -- resolve from/to for variant modules from the line's source bucket
    if is_variant then
      if src is null then raise exception 'Source bucket required on each line for %', p_type; end if;
      if variant_dir = 'OUT' then
        if p_type = 'DC_OUT_NONRET' then from_b := src; to_b := 'VENDOR';   -- permanent out
        else from_b := src; to_b := 'JOBOUT'; end if;                       -- returnable out
      else
        from_b := 'JOBOUT'; to_b := src;                                    -- return in
      end if;
    end if;

    if from_b is not null then
      if from_b not in ('VENDOR','CUSTOMER') then
        on_hand := check_stock((ln->>'part_id')::uuid, from_b);
        if on_hand < lqty then
          raise exception '% blocked for part: % balance %, requested %', p_type, from_b, on_hand, lqty;
        end if;
      end if;

      insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
      values (move_date,(ln->>'part_id')::uuid,from_b,to_b,lqty,v_id,p_type,p_no,p_remarks);

      -- lot handling (unchanged)
      if p_type = 'RM_PURCHASE' and lqty > 0 then
        new_lot_no := next_lot_no((ln->>'part_id')::uuid, p_party);
        insert into lot_master(lot_no,part_id,vendor_id,current_bucket,original_qty,ref_voucher)
        values (new_lot_no,(ln->>'part_id')::uuid,p_party,'RC',lqty,p_no) returning id into lid;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values (lid,'VENDOR','RC',lqty,v_id,p_type,p_no);
      elsif nullif(ln->>'lot_id','') is not null then
        lid := (ln->>'lot_id')::uuid;
        lbal := lot_balance(lid, from_b);
        if lbal < lqty then raise exception 'Lot insufficient in %: have %, need %', from_b, lbal, lqty; end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values (lid,from_b,to_b,lqty,v_id,p_type,p_no);
        update lot_master set current_bucket = to_b where id = lid;
      end if;
    end if;
  end loop;

  return v_id;
end; $$ language plpgsql security definer;

-- extend next_voucher_no prefixes for the new types
create or replace function next_voucher_no(p_type text) returns text as $$
declare pre text; n int; begin
  pre := case p_type
    when 'PURCHASE_ORDER' then 'PO' when 'RM_PURCHASE' then 'PUR'
    when 'DEBIT_NOTE_RC' then 'DNRC' when 'JW_DC_OUT' then 'DCO'
    when 'JW_RC_IN' then 'CST' when 'SALES_ORDER' then 'SO'
    when 'SALES' then 'SAL' when 'CREDIT_NOTE' then 'CN'
    when 'PRODUCTION' then 'PRD-LOG' when 'PROCESS_REJECTION' then 'PRJ'
    when 'MATERIAL_REJECTION' then 'MRJ' when 'SALES_PROC_REJ' then 'SCR'
    when 'DEBIT_NOTE_MAT' then 'DNM'
    when 'REWORK_DECL' then 'RWD' when 'REWORK_COMP' then 'RWC'
    when 'DC_OUT_RET' then 'DCR' when 'RC_IN_RET' then 'RCR'
    when 'DC_OUT_NONRET' then 'DCN' when 'DC_OUT_REPLACE' then 'DCP'
    when 'RC_IN_REPLACE' then 'RCP'
    else 'VCH' end;
  select coalesce(max(nullif(regexp_replace(voucher_no,'^.*[-/]',''),'')::int),0)+1
    into n from vouchers where voucher_type=p_type;
  if n is null then n:=1; end if;
  return pre||'-'||lpad(n::text,5,'0'); end; $$ language plpgsql;
-- =====================================================================
--  DMS ERP V13.0 — PHASE 4: ORDER & REFERENCE LOGIC
--  Run AFTER schema_phase3.sql.
--  Adds: PO/SO received & pending (live views), max-2-active guard,
--  Sales WIPFG+250 buffer, RC In DC-allocation closing DCs, and
--  DC-Out → RC-In pending-return tracking.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ORDER FULFILMENT view — received/dispatched & pending per order line.
--    PO received  = sum of RM_PURCHASE actual_qty referencing the PO no.
--    SO dispatched = sum of SALES qty referencing the SO no.
--    Matching is by ref_no (the order's voucher_no) + part.
-- ---------------------------------------------------------------------
create or replace view order_fulfilment as
select
  v.id as order_id, v.voucher_type, v.voucher_no, v.voucher_date, v.valid_thru,
  v.party_id, v.status, vl.id as line_id, vl.part_id, vl.qty as order_qty,
  coalesce((
    select sum(cl.qty) from voucher_lines cl
    join vouchers cv on cv.id = cl.voucher_id
    where cv.voucher_type = case v.voucher_type when 'PURCHASE_ORDER' then 'RM_PURCHASE' when 'SALES_ORDER' then 'SALES' end
      and cv.cancelled = false and cl.ref_no = v.voucher_no and cl.part_id = vl.part_id
  ),0) as fulfilled_qty,
  greatest(vl.qty - coalesce((
    select sum(cl.qty) from voucher_lines cl
    join vouchers cv on cv.id = cl.voucher_id
    where cv.voucher_type = case v.voucher_type when 'PURCHASE_ORDER' then 'RM_PURCHASE' when 'SALES_ORDER' then 'SALES' end
      and cv.cancelled = false and cl.ref_no = v.voucher_no and cl.part_id = vl.part_id
  ),0), 0) as pending_qty
from vouchers v
join voucher_lines vl on vl.voucher_id = v.id
where v.voucher_type in ('PURCHASE_ORDER','SALES_ORDER') and v.cancelled = false;

-- Open orders helper: pending>0 and not past valid_thru
create or replace view open_orders as
select * from order_fulfilment
where pending_qty > 0
  and (valid_thru is null or valid_thru >= current_date);

-- count of active orders per part for a given order type
create or replace function active_order_count(p_type text, p_part uuid)
returns int as $$
  select count(distinct order_id)::int from open_orders
  where voucher_type = p_type and part_id = p_part;
$$ language sql;

-- ---------------------------------------------------------------------
-- 2. DC OUT (JW) fulfilment — received via RC In DC allocations.
--    RC In lines carry ref_no = the DC Out voucher_no they close.
-- ---------------------------------------------------------------------
create or replace view dc_fulfilment as
select v.id as dc_id, v.voucher_type, v.voucher_no, v.voucher_date, v.valid_thru as due_date,
  v.party_id, vl.part_id, vl.qty as dc_qty,
  coalesce((
    select sum(rl.qty) from voucher_lines rl
    join vouchers rv on rv.id = rl.voucher_id
    where rv.cancelled = false and rl.ref_no = v.voucher_no and rl.part_id = vl.part_id
      and rv.voucher_type in ('JW_RC_IN','RC_IN_RET','RC_IN_REPLACE')
  ),0) as received_qty,
  greatest(vl.qty - coalesce((
    select sum(rl.qty) from voucher_lines rl
    join vouchers rv on rv.id = rl.voucher_id
    where rv.cancelled = false and rl.ref_no = v.voucher_no and rl.part_id = vl.part_id
      and rv.voucher_type in ('JW_RC_IN','RC_IN_RET','RC_IN_REPLACE')
  ),0), 0) as pending_qty
from vouchers v
join voucher_lines vl on vl.voucher_id = v.id
where v.voucher_type in ('JW_DC_OUT','DC_OUT_RET','DC_OUT_REPLACE') and v.cancelled = false;

create or replace view open_dcs as
select * from dc_fulfilment where pending_qty > 0;

-- ---------------------------------------------------------------------
-- 3. Rebuild post_voucher with Phase-4 enforcement:
--    (a) max-2-active POs/SOs per part
--    (b) Sales: qty <= WIPFG balance + 250 buffer
--    (c) RM Purchase: actual_qty <= referenced PO pending
--    (d) RC In: qty <= referenced DC pending (closes the DC)
--    Everything from Phase 3 retained.
-- ---------------------------------------------------------------------
create or replace function post_voucher(
  p_type text, p_no text, p_date date, p_posting date, p_valid date,
  p_party uuid, p_ref_voucher uuid, p_ref_no text, p_remarks text,
  p_user text, p_lines jsonb
) returns uuid as $$
declare
  v_id uuid; ln jsonb; i int := 0;
  from_b text; to_b text; move_date date; on_hand numeric;
  lid uuid; new_lot_no text; lbal numeric; lqty numeric;
  is_variant boolean := false; src text; variant_dir text;
  cnt int; pend numeric; sale_buffer numeric := 250;
begin
  -- (a) max 2 active orders per part (checked before insert)
  if p_type in ('PURCHASE_ORDER','SALES_ORDER') then
    for ln in select * from jsonb_array_elements(p_lines) loop
      cnt := active_order_count(p_type, (ln->>'part_id')::uuid);
      if cnt >= 2 then
        raise exception 'Max 2 active %s allowed for this part (already % open).',
          case p_type when 'PURCHASE_ORDER' then 'PO' else 'SO' end, cnt;
      end if;
    end loop;
  end if;

  insert into vouchers(voucher_type,voucher_no,voucher_period,voucher_date,posting_date,
    valid_thru,party_id,ref_voucher_id,ref_no,remarks,created_by,status)
  values (p_type,p_no,to_char(p_date,'Mon YYYY'),p_date,p_posting,p_valid,
    p_party,p_ref_voucher,p_ref_no,p_remarks,p_user,'OPEN')
  returning id into v_id;

  case p_type
    when 'RM_PURCHASE'        then from_b:='VENDOR';  to_b:='RC';
    when 'DEBIT_NOTE_RC'      then from_b:='RC';      to_b:='VENDOR';
    when 'JW_DC_OUT'          then from_b:='RC';      to_b:='RCCST';
    when 'JW_RC_IN'           then from_b:='RCCST';   to_b:='CC';
    when 'PRODUCTION'         then from_b:='CC';      to_b:='WIPFG';
    when 'SALES'              then from_b:='WIPFG';   to_b:='CUSTOMER';
    when 'CREDIT_NOTE'        then from_b:='CUSTOMER';to_b:='FGR';
    when 'PROCESS_REJECTION'  then from_b:='WIPFG';   to_b:='PR';
    when 'MATERIAL_REJECTION' then from_b:='WIPFG';   to_b:='MRM';
    when 'SALES_PROC_REJ'     then from_b:='PR';      to_b:='CUSTOMER';
    when 'DEBIT_NOTE_MAT'     then from_b:='MRM';     to_b:='VENDOR';
    when 'REWORK_DECL'        then from_b:='WIPFG';   to_b:='RWD';
    when 'REWORK_COMP'        then from_b:='RWD';     to_b:='WIPFG';
    else from_b:=null; to_b:=null;
  end case;

  if p_type in ('DC_OUT_RET','DC_OUT_NONRET','DC_OUT_REPLACE') then is_variant:=true; variant_dir:='OUT';
  elsif p_type in ('RC_IN_RET','RC_IN_REPLACE') then is_variant:=true; variant_dir:='IN'; end if;

  move_date := coalesce(p_posting, p_date);

  for ln in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    lqty := coalesce((ln->>'qty')::numeric,0);
    src := nullif(ln->>'source_bucket','');

    -- (c) RM Purchase actual qty <= PO pending (when a PO ref is given)
    if p_type = 'RM_PURCHASE' and nullif(ln->>'ref_no','') is not null then
      select pending_qty into pend from order_fulfilment
        where voucher_type='PURCHASE_ORDER' and voucher_no = ln->>'ref_no' and part_id=(ln->>'part_id')::uuid limit 1;
      if pend is not null and coalesce((ln->>'actual_qty')::numeric, lqty) > pend then
        raise exception 'Purchase exceeds PO pending for part: PO pending %, entered %', pend, coalesce((ln->>'actual_qty')::numeric, lqty);
      end if;
    end if;

    -- (d) RC In qty <= referenced DC pending
    if p_type in ('JW_RC_IN','RC_IN_RET','RC_IN_REPLACE') and nullif(ln->>'ref_no','') is not null then
      select pending_qty into pend from dc_fulfilment
        where voucher_no = ln->>'ref_no' and part_id=(ln->>'part_id')::uuid limit 1;
      if pend is not null and lqty > pend then
        raise exception 'RC In exceeds DC pending for part: DC pending %, entered %', pend, lqty;
      end if;
    end if;

    insert into voucher_lines(voucher_id,sno,part_id,lot_id,ref_no,qty,invoice_qty,actual_qty,
      uom,unit_price,basic_value,weight,defect_type,root_cause,line_note)
    values (v_id,i,(ln->>'part_id')::uuid,nullif(ln->>'lot_id','')::uuid,ln->>'ref_no',
      lqty,coalesce((ln->>'invoice_qty')::numeric,0),coalesce((ln->>'actual_qty')::numeric,0),
      coalesce(ln->>'uom','Nos'),coalesce((ln->>'unit_price')::numeric,0),
      coalesce((ln->>'basic_value')::numeric,0),coalesce((ln->>'weight')::numeric,0),
      ln->>'defect_type',ln->>'root_cause',ln->>'line_note');

    if is_variant then
      if src is null then raise exception 'Source bucket required on each line for %', p_type; end if;
      if variant_dir='OUT' then
        if p_type='DC_OUT_NONRET' then from_b:=src; to_b:='VENDOR'; else from_b:=src; to_b:='JOBOUT'; end if;
      else from_b:='JOBOUT'; to_b:=src; end if;
    end if;

    if from_b is not null then
      if from_b not in ('VENDOR','CUSTOMER') then
        on_hand := check_stock((ln->>'part_id')::uuid, from_b);
        -- (b) Sales gets the +250 buffer; everything else strict
        if p_type = 'SALES' then
          if lqty > on_hand + sale_buffer then
            raise exception 'Sales blocked for part. FG Stock: %, Max allowed (stock + %): %, you entered: %',
              on_hand, sale_buffer, on_hand + sale_buffer, lqty;
          end if;
        elsif on_hand < lqty then
          raise exception '% blocked for part: % balance %, requested %', p_type, from_b, on_hand, lqty;
        end if;
      end if;

      insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
      values (move_date,(ln->>'part_id')::uuid,from_b,to_b,lqty,v_id,p_type,p_no,p_remarks);

      if p_type='RM_PURCHASE' and lqty>0 then
        new_lot_no := next_lot_no((ln->>'part_id')::uuid, p_party);
        insert into lot_master(lot_no,part_id,vendor_id,current_bucket,original_qty,ref_voucher)
        values (new_lot_no,(ln->>'part_id')::uuid,p_party,'RC',lqty,p_no) returning id into lid;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values (lid,'VENDOR','RC',lqty,v_id,p_type,p_no);
      elsif nullif(ln->>'lot_id','') is not null then
        lid := (ln->>'lot_id')::uuid;
        lbal := lot_balance(lid, from_b);
        if lbal < lqty then raise exception 'Lot insufficient in %: have %, need %', from_b, lbal, lqty; end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values (lid,from_b,to_b,lqty,v_id,p_type,p_no);
        update lot_master set current_bucket=to_b where id=lid;
      end if;
    end if;
  end loop;

  -- close fully-fulfilled referenced orders/DCs (status flip for UI)
  update vouchers o set status='CLOSED'
  where o.voucher_no in (select distinct ln2->>'ref_no' from jsonb_array_elements(p_lines) ln2 where nullif(ln2->>'ref_no','') is not null)
    and o.voucher_type in ('PURCHASE_ORDER','SALES_ORDER','JW_DC_OUT','DC_OUT_RET','DC_OUT_REPLACE')
    and not exists (
      select 1 from order_fulfilment f where f.order_id=o.id and f.pending_qty>0
      union all
      select 1 from dc_fulfilment d where d.dc_id=o.id and d.pending_qty>0
    );

  return v_id;
end; $$ language plpgsql security definer;
-- =====================================================================
--  DMS ERP V13.0 — PHASE 5: GOVERNANCE
--  Run AFTER schema_phase4.sql.
--  Adds: rec-copy approval gate, price-approval gate, mark for
--  deletion/modification, 8-hour edit window, audit & undo logs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Governance columns on vouchers
-- ---------------------------------------------------------------------
alter table vouchers add column if not exists rec_copy boolean default false;
alter table vouchers add column if not exists price_approved text default 'OK';   -- 'OK' | 'PENDING'
alter table vouchers add column if not exists approved_acc boolean default false;
alter table vouchers add column if not exists gstr_flag2 boolean default false;
alter table vouchers add column if not exists delete_requested boolean default false;
alter table vouchers add column if not exists modify_requested boolean default false;
alter table vouchers add column if not exists request_reason text;
alter table vouchers add column if not exists requested_by text;
alter table vouchers add column if not exists request_date timestamptz;
-- approved_mgmt already exists ('APPROVED' default; 'PENDING' when gated)
-- po_price for purchase price-mismatch comparison
alter table voucher_lines add column if not exists po_price numeric default 0;

-- ---------------------------------------------------------------------
-- 2. AUDIT + UNDO logs
-- ---------------------------------------------------------------------
create table if not exists audit_log (
  id uuid primary key default gen_random_uuid(),
  ts timestamptz default now(),
  action text, app_user text, details text
);
create table if not exists undo_log (
  id uuid primary key default gen_random_uuid(),
  ts timestamptz default now(),
  voucher_type text, voucher_id uuid, original_data jsonb, undone_by text
);
create or replace function log_audit(p_action text, p_user text, p_details text)
returns void as $$ insert into audit_log(action,app_user,details) values (p_action,p_user,p_details); $$ language sql;

-- ---------------------------------------------------------------------
-- 3. REC-COPY GATE
--    Config: which voucher types are gated, the date column, grace days.
--      JW_DC_OUT (DUE_DATE, 0), DC_OUT_RET (DUE_DATE,0),
--      DC_OUT_REPLACE (DUE_DATE,0), SALES (VOUCHER_DATE, 2)
--    has_overdue_rec_copies: any non-cancelled, rec_copy=false row whose
--    (date + grace) < today → gate is tripped.
-- ---------------------------------------------------------------------
create or replace function has_overdue_rec_copies(p_type text)
returns boolean as $$
declare grace int; usecol text; trip boolean;
begin
  grace := case p_type when 'SALES' then 2 else 0 end;
  usecol := case p_type when 'SALES' then 'voucher_date' else 'valid_thru' end; -- valid_thru holds due_date for DC types
  if p_type not in ('JW_DC_OUT','DC_OUT_RET','DC_OUT_REPLACE','SALES') then return false; end if;
  execute format($f$
    select exists(
      select 1 from vouchers
      where voucher_type = %L and cancelled = false and coalesce(rec_copy,false) = false
        and %I is not null and (%I + %s) < current_date
    )$f$, p_type, usecol, usecol, grace) into trip;
  return coalesce(trip,false);
end; $$ language plpgsql;

-- ---------------------------------------------------------------------
-- 4. Wrap post_voucher with gate decisions (rec-copy + price).
--    We keep the Phase-4 core and add a thin pre/post layer by adding a
--    new entry function the app calls; it sets approved_mgmt/price_approved
--    after the core insert.
-- ---------------------------------------------------------------------
create or replace function post_voucher_governed(
  p_type text, p_no text, p_date date, p_posting date, p_valid date,
  p_party uuid, p_ref_voucher uuid, p_ref_no text, p_remarks text,
  p_user text, p_lines jsonb
) returns jsonb as $$
declare v_id uuid; gated boolean; price_pending boolean := false; ln jsonb; po_pend numeric; po_price numeric;
begin
  v_id := post_voucher(p_type,p_no,p_date,p_posting,p_valid,p_party,p_ref_voucher,p_ref_no,p_remarks,p_user,p_lines);

  -- rec-copy gate: if tripped, hold this new entry as PENDING
  gated := has_overdue_rec_copies(p_type);
  if gated then
    update vouchers set approved_mgmt = 'PENDING' where id = v_id;
  end if;

  -- price gate (RM Purchase): if any line unit_price <> PO price → PENDING
  if p_type = 'RM_PURCHASE' then
    for ln in select * from jsonb_array_elements(p_lines) loop
      if nullif(ln->>'ref_no','') is not null then
        select unit_price into po_price from voucher_lines pl
          join vouchers pv on pv.id = pl.voucher_id
          where pv.voucher_type='PURCHASE_ORDER' and pv.voucher_no = ln->>'ref_no'
            and pl.part_id = (ln->>'part_id')::uuid limit 1;
        if po_price is not null and coalesce((ln->>'unit_price')::numeric,0) <> po_price then
          price_pending := true;
        end if;
      end if;
    end loop;
    if price_pending then
      update vouchers set price_approved = 'PENDING' where id = v_id;
    end if;
  end if;

  perform log_audit('POST '||p_type, p_user, p_no);
  return jsonb_build_object('id', v_id, 'rec_gated', gated, 'price_pending', price_pending);
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 5. REC-COPY APPROVAL admin functions
-- ---------------------------------------------------------------------
create or replace function rec_copy_pending()
returns table(id uuid, voucher_type text, voucher_no text, voucher_date date, party_id uuid) as $$
  select id, voucher_type, voucher_no, voucher_date, party_id
  from vouchers where approved_mgmt = 'PENDING' and cancelled = false
  order by created_at;
$$ language sql;

create or replace function approve_rec_copy(p_ids uuid[])
returns int as $$
  with u as (update vouchers set approved_mgmt = 'APPROVED' where id = any(p_ids) returning 1)
  select count(*)::int from u;
$$ language sql security definer;

-- toggle the physical rec-copy received flag (clears a row from the gate)
create or replace function set_rec_copy(p_id uuid, p_val boolean)
returns void as $$ update vouchers set rec_copy = p_val where id = p_id; $$ language sql security definer;

-- ---------------------------------------------------------------------
-- 6. PRICE APPROVAL admin functions
-- ---------------------------------------------------------------------
create or replace function price_pending()
returns table(id uuid, voucher_no text, voucher_date date, party_id uuid) as $$
  select id, voucher_no, voucher_date, party_id
  from vouchers where price_approved = 'PENDING' and cancelled = false and voucher_type='RM_PURCHASE'
  order by created_at;
$$ language sql;

create or replace function approve_price(p_id uuid)
returns void as $$ update vouchers set price_approved='OK' where id=p_id; $$ language sql security definer;

create or replace function cancel_price_mismatch(p_id uuid)
returns void as $$ update vouchers set cancelled=true where id=p_id; $$ language sql security definer;

-- ---------------------------------------------------------------------
-- 7. MARK for Deletion / Modification + resolve
--    8-hour rule for Modify (non-admin); Delete always allowed for
--    admin/can_edit. Enforced in the marking function via role + age.
-- ---------------------------------------------------------------------
create or replace function mark_record(p_id uuid, p_mark text, p_reason text, p_user text, p_role text)
returns jsonb as $$
declare age interval; created timestamptz;
begin
  select created_at into created from vouchers where id = p_id;
  if created is null then return jsonb_build_object('ok',false,'msg','Record not found'); end if;
  age := now() - created;

  if p_role not in ('admin','can_edit') then
    return jsonb_build_object('ok',false,'msg','You do not have permission to mark records.');
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    return jsonb_build_object('ok',false,'msg','A reason is required.');
  end if;

  if p_mark = 'modify' and p_role <> 'admin' and age > interval '8 hours' then
    return jsonb_build_object('ok',false,'msg','Modify window (8 hours) has passed.');
  end if;

  update vouchers set
    delete_requested = (p_mark='delete') or delete_requested,
    modify_requested = (p_mark='modify') or modify_requested,
    request_reason = p_reason, requested_by = p_user, request_date = now()
  where id = p_id;
  perform log_audit('MARK '||p_mark, p_user, p_id::text||' : '||p_reason);
  return jsonb_build_object('ok',true,'msg','Request submitted for admin approval.');
end; $$ language plpgsql security definer;

create or replace function marked_requests()
returns table(id uuid, voucher_type text, voucher_no text, delete_requested boolean,
  modify_requested boolean, request_reason text, requested_by text, request_date timestamptz) as $$
  select id, voucher_type, voucher_no, delete_requested, modify_requested,
    request_reason, requested_by, request_date
  from vouchers where (delete_requested or modify_requested) and cancelled = false
  order by request_date;
$$ language sql;

create or replace function resolve_mark(p_id uuid, p_mark text, p_action text, p_admin text)
returns jsonb as $$
begin
  if p_action = 'approve' and p_mark = 'delete' then
    update vouchers set cancelled = true, delete_requested = false where id = p_id;       -- stock reverses via views
    perform log_audit('APPROVE DELETE', p_admin, p_id::text);
  elsif p_action = 'approve' and p_mark = 'modify' then
    update vouchers set modify_requested = false where id = p_id;                          -- now editable
    perform log_audit('APPROVE MODIFY', p_admin, p_id::text);
  else -- reject
    update vouchers set delete_requested = case when p_mark='delete' then false else delete_requested end,
                        modify_requested = case when p_mark='modify' then false else modify_requested end
      where id = p_id;
    perform log_audit('REJECT '||p_mark, p_admin, p_id::text);
  end if;
  return jsonb_build_object('ok',true);
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 8. CANCELLED stock reversal — exclude cancelled vouchers' ledger rows.
--    Stock views read stock_ledger; we filter cancelled at the ledger
--    by joining vouchers. Redefine GRS source to skip cancelled.
-- ---------------------------------------------------------------------
create or replace view stock_grs as
select p.id as part_id, b.code as bucket,
  coalesce((select qty from opening_stock o where o.part_id=p.id and o.bucket=b.code),0)
  + coalesce((select sum(l.qty) from stock_ledger l left join vouchers v on v.id=l.voucher_id
      where l.part_id=p.id and l.to_bucket=b.code and coalesce(v.cancelled,false)=false),0)
  - coalesce((select sum(l.qty) from stock_ledger l left join vouchers v on v.id=l.voucher_id
      where l.part_id=p.id and l.from_bucket=b.code and coalesce(v.cancelled,false)=false),0) as grs
from parts p cross join buckets b where b.is_external=false;

-- ---------------------------------------------------------------------
-- 9. EDIT WINDOW helper (used by app before allowing edit)
-- ---------------------------------------------------------------------
create or replace function can_edit_voucher(p_id uuid, p_user text, p_role text)
returns jsonb as $$
declare created timestamptz; owner text;
begin
  select created_at, created_by into created, owner from vouchers where id = p_id;
  if created is null then return jsonb_build_object('ok',false,'msg','Not found'); end if;
  if p_role = 'admin' then return jsonb_build_object('ok',true); end if;
  if p_role <> 'can_edit' then return jsonb_build_object('ok',false,'msg','No edit permission'); end if;
  if owner is distinct from p_user then return jsonb_build_object('ok',false,'msg','You can only edit your own entries'); end if;
  if now() - created > interval '8 hours' then return jsonb_build_object('ok',false,'msg','8-hour edit window passed'); end if;
  return jsonb_build_object('ok',true);
end; $$ language plpgsql;

-- ---------------------------------------------------------------------
-- 10. RLS for new tables
-- ---------------------------------------------------------------------
alter table audit_log enable row level security;
alter table undo_log  enable row level security;
drop policy if exists pol_audit on audit_log;
drop policy if exists pol_undo on undo_log;
create policy pol_audit on audit_log for all using (true) with check (true);
create policy pol_undo  on undo_log  for all using (true) with check (true);
-- =====================================================================
--  DMS ERP V13.0 — PHASE 6: ADMINISTRATION MASTERS
--  Run AFTER schema_phase5.sql.
--  Adds: user-management flags, machine config, checkbox permissions,
--  and admin helper functions for users, mappings, opening stock,
--  price list, and machine config.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. USER flags (spec DB_USERS): access modules, weight-check,
--    valid-thru-edit, can-edit. role already exists (user/can_edit/admin).
-- ---------------------------------------------------------------------
alter table app_users add column if not exists access_modules text default 'ALL';
alter table app_users add column if not exists weight_check boolean default true;
alter table app_users add column if not exists valid_thru_edit boolean default false;

-- admin user CRUD
create or replace function admin_list_users()
returns table(id uuid, username text, role text, access_modules text,
  weight_check boolean, valid_thru_edit boolean, created_at timestamptz) as $$
  select id, username, role, access_modules, weight_check, valid_thru_edit, created_at
  from app_users order by username;
$$ language sql security definer;

create or replace function admin_save_user(
  p_id uuid, p_username text, p_password text, p_role text,
  p_access text, p_weight boolean, p_valid_edit boolean
) returns uuid as $$
declare uid uuid;
begin
  if p_id is null then
    insert into app_users(username,password,role,access_modules,weight_check,valid_thru_edit)
    values (p_username, crypt(coalesce(p_password,'changeme'),gen_salt('bf')), p_role, p_access, p_weight, p_valid_edit)
    returning id into uid;
  else
    update app_users set
      username=p_username, role=p_role, access_modules=p_access,
      weight_check=p_weight, valid_thru_edit=p_valid_edit,
      password = case when p_password is null or p_password='' then password else crypt(p_password,gen_salt('bf')) end
    where id=p_id returning id into uid;
  end if;
  return uid;
end; $$ language plpgsql security definer;

create or replace function admin_delete_user(p_id uuid)
returns void as $$ delete from app_users where id=p_id and username <> 'admin'; $$ language sql security definer;

-- verify_login: return the extra flags too
drop function if exists verify_login(text, text);
create or replace function verify_login(p_username text, p_password text)
returns table(id uuid, username text, role text, access_modules text, weight_check boolean, valid_thru_edit boolean) as $$
  select id, username, role, access_modules, weight_check, valid_thru_edit
  from app_users where username=p_username and password=crypt(p_password,password);
$$ language sql security definer;

-- ---------------------------------------------------------------------
-- 2. MACHINE CONFIG (section -> machine -> operation), drives Production grid
-- ---------------------------------------------------------------------
create table if not exists machine_config (
  id uuid primary key default gen_random_uuid(),
  section text not null,
  machine text not null,
  operation text,
  unique (section, machine, operation)
);

-- ---------------------------------------------------------------------
-- 3. CHECKBOX PERMISSIONS (per-user doc-control edit rights)
-- ---------------------------------------------------------------------
create table if not exists checkbox_perms (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  checkbox_field text not null,   -- REC_COPY, APPROVED_ACC, APPROVED_MGMT, GSTR_2A, GSTR_1
  can_edit boolean default false,
  unique (username, checkbox_field)
);

-- ---------------------------------------------------------------------
-- 4. Opening stock bulk upsert helper
--    p_rows: [{"part_id":..,"bucket":"RC","qty":100}, ...]
-- ---------------------------------------------------------------------
create or replace function admin_save_opening(p_rows jsonb)
returns int as $$
declare r jsonb; n int := 0;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into opening_stock(part_id,bucket,qty)
    values ((r->>'part_id')::uuid, r->>'bucket', coalesce((r->>'qty')::numeric,0))
    on conflict (part_id,bucket) do update set qty = excluded.qty;
    n := n + 1;
  end loop;
  return n;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 5. Price list upsert helper
--    p_rows: [{"part_id":..,"entity_id":..,"price_type":"purchase","month_key":"Jun 2026","unit_price":12}, ...]
-- ---------------------------------------------------------------------
create or replace function admin_save_prices(p_rows jsonb)
returns int as $$
declare r jsonb; n int := 0;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into price_list(part_id,entity_id,price_type,month_key,unit_price)
    values ((r->>'part_id')::uuid,(r->>'entity_id')::uuid,r->>'price_type',r->>'month_key',coalesce((r->>'unit_price')::numeric,0))
    on conflict (part_id,entity_id,price_type,month_key) do update set unit_price = excluded.unit_price;
    n := n + 1;
  end loop;
  return n;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 6. Mapping helpers — set the full part list for a vendor/customer
-- ---------------------------------------------------------------------
create or replace function admin_set_vendor_parts(p_vendor uuid, p_parts uuid[])
returns void as $$
begin
  delete from master_vendor_parts where vendor_id = p_vendor;
  insert into master_vendor_parts(vendor_id, part_id)
    select p_vendor, unnest(p_parts) on conflict do nothing;
end; $$ language plpgsql security definer;

create or replace function admin_set_customer_parts(p_customer uuid, p_parts uuid[])
returns void as $$
begin
  delete from master_customer_parts where customer_id = p_customer;
  insert into master_customer_parts(customer_id, part_id)
    select p_customer, unnest(p_parts) on conflict do nothing;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 7. RLS
-- ---------------------------------------------------------------------
alter table machine_config enable row level security;
alter table checkbox_perms enable row level security;
drop policy if exists pol_machine on machine_config;
drop policy if exists pol_checkbox on checkbox_perms;
create policy pol_machine  on machine_config for all using (true) with check (true);
create policy pol_checkbox on checkbox_perms for all using (true) with check (true);
-- =====================================================================
--  DMS ERP V13.0 — PHASE 7: VIEWS & REPORTS
--  Run AFTER schema_phase6.sql.
--  Adds: part ledger (running balance), voucher listing for View Data,
--  last-updated status per module, and the scrap (burr) report.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PART LEDGER — running-balance tally for one part in one bucket.
--    Opening + each movement (in/out) with carried balance.
-- ---------------------------------------------------------------------
create or replace function part_ledger(p_part uuid, p_bucket text, p_from date default null, p_to date default null)
returns table(ledger_date date, voucher_type text, voucher_no text, inward numeric, outward numeric, running numeric) as $$
declare opening numeric;
begin
  select coalesce(qty,0) into opening from opening_stock where part_id=p_part and bucket=p_bucket;
  if opening is null then opening := 0; end if;

  return query
  with moves as (
    select l.ledger_date, l.voucher_type, l.voucher_no,
      case when l.to_bucket = p_bucket then l.qty else 0 end as inward,
      case when l.from_bucket = p_bucket then l.qty else 0 end as outward
    from stock_ledger l
    left join vouchers v on v.id = l.voucher_id
    where l.part_id = p_part and (l.to_bucket = p_bucket or l.from_bucket = p_bucket)
      and coalesce(v.cancelled,false) = false
      and (p_from is null or l.ledger_date >= p_from)
      and (p_to   is null or l.ledger_date <= p_to)
  ),
  ordered as (
    select 0 sort_o, null::date ld, 'OPENING'::text vt, ''::text vn, opening inw, 0::numeric outw
    union all
    select 1, ld.ledger_date, ld.voucher_type, ld.voucher_no, ld.inward, ld.outward
    from moves ld
  )
  select o.ld, o.vt, o.vn, o.inw, o.outw,
    sum(o.inw - o.outw) over (order by o.sort_o, o.ld nulls first rows between unbounded preceding and current row) as running
  from ordered o order by o.sort_o, o.ld nulls first;
end; $$ language plpgsql;

-- ---------------------------------------------------------------------
-- 2. VOUCHER LISTING for View Data (header + first-line summary + flags)
--    Hides rec-copy-PENDING entries from normal listing (spec D.5).
-- ---------------------------------------------------------------------
create or replace function list_vouchers(p_type text, p_include_pending boolean default false)
returns table(
  id uuid, voucher_no text, voucher_date date, party_name text,
  total_qty numeric, total_value numeric, status text,
  rec_copy boolean, approved_acc boolean, approved_mgmt text, price_approved text,
  gstr_flag boolean, delete_requested boolean, modify_requested boolean,
  cancelled boolean, created_by text, created_at timestamptz
) as $$
  select v.id, v.voucher_no, v.voucher_date, pa.party_name,
    coalesce((select sum(qty) from voucher_lines l where l.voucher_id=v.id),0),
    coalesce((select sum(basic_value) from voucher_lines l where l.voucher_id=v.id),0),
    v.status, v.rec_copy, v.approved_acc, v.approved_mgmt, v.price_approved,
    v.gstr_flag, v.delete_requested, v.modify_requested, v.cancelled, v.created_by, v.created_at
  from vouchers v
  left join parties pa on pa.id = v.party_id
  where v.voucher_type = p_type
    and (p_include_pending or coalesce(v.approved_mgmt,'APPROVED') <> 'PENDING')
  order by v.created_at desc;
$$ language sql;

-- toggle a doc-control checkbox (generic)
create or replace function set_doc_flag(p_id uuid, p_field text, p_val boolean)
returns void as $$
begin
  case p_field
    when 'rec_copy'     then update vouchers set rec_copy=p_val where id=p_id;
    when 'approved_acc' then update vouchers set approved_acc=p_val where id=p_id;
    when 'gstr_flag'    then update vouchers set gstr_flag=p_val where id=p_id;
    else raise exception 'Unknown flag %', p_field;
  end case;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 3. LAST-UPDATED status per voucher type
-- ---------------------------------------------------------------------
create or replace function last_updated_status()
returns table(voucher_type text, last_at timestamptz, cnt bigint) as $$
  select voucher_type, max(created_at), count(*)
  from vouchers where cancelled=false group by voucher_type;
$$ language sql;

-- ---------------------------------------------------------------------
-- 4. SCRAP (BURR) REPORT — per part: OP10 produced x scrap weight/pc
--    over a date range. Uses parts.machined_weight_pc as scrap basis.
--    (Spec uses MASTER_PART.SCRAP_WEIGHT; we add a scrap_weight_pc col.)
-- ---------------------------------------------------------------------
alter table parts add column if not exists scrap_weight_pc numeric default 0;

create or replace function scrap_report(p_from date, p_to date)
returns table(part_code text, part_name text, produced numeric, scrap_wt_pc numeric, total_scrap numeric) as $$
  select p.part_code, p.part_name,
    coalesce(sum(l.qty),0) as produced,
    p.scrap_weight_pc,
    coalesce(sum(l.qty),0) * p.scrap_weight_pc as total_scrap
  from parts p
  left join stock_ledger l on l.part_id=p.id and l.voucher_type='PRODUCTION'
    and l.to_bucket='WIPFG'
    and (p_from is null or l.ledger_date>=p_from)
    and (p_to is null or l.ledger_date<=p_to)
  where p.status='Active'
  group by p.id, p.part_code, p.part_name, p.scrap_weight_pc
  having coalesce(sum(l.qty),0) > 0;
$$ language sql;
-- =====================================================================
--  DMS ERP V13.0 — PHASE 8: FULL PRODUCTION MODULE
--  Run AFTER schema_phase7.sql.
--  Production header + machine grid rows (OP10/20/30), with OP10 only
--  moving CC -> WIPFG. Downtime & Quality sub-logs keyed to a header.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists production_log (
  id uuid primary key default gen_random_uuid(),
  log_period text,
  log_date date not null default current_date,
  shift text,
  supervisor_1 text not null,
  supervisor_2 text,
  created_by text,
  created_at timestamptz default now()
);

create table if not exists production_rows (
  id uuid primary key default gen_random_uuid(),
  production_id uuid references production_log(id) on delete cascade,
  section text,
  machine_no text,
  operator text,
  part_id uuid references parts(id),
  lot_id uuid references lot_master(id),
  op10_actual numeric default 0,
  op20_actual numeric default 0,
  op30_actual numeric default 0,
  setting_time numeric default 0,
  tool_change_time numeric default 0,
  breakdown_time numeric default 0,
  idle_time numeric default 0,
  remarks text
);

create table if not exists downtime_log (
  id uuid primary key default gen_random_uuid(),
  production_id uuid references production_log(id) on delete cascade,
  log_date date,
  section text,
  machine_no text,
  start_time text,
  end_time text,
  duration_min numeric,
  reason text,
  action_taken text,
  created_at timestamptz default now()
);

create table if not exists quality_log (
  id uuid primary key default gen_random_uuid(),
  production_id uuid references production_log(id) on delete cascade,
  log_date date,
  section text,
  machine_no text,
  part_id uuid references parts(id),
  qty_rejected numeric,
  rejection_type text,
  defect_type text,
  root_cause text,
  corrective_action text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 2. post_production — header + rows + sub-logs in one call.
--    Only OP10 > 0 moves stock CC -> WIPFG (checked against CC BAL),
--    and consumes the chosen lot CC -> WIPFG when a lot is given.
--    p_rows:     [{section,machine_no,operator,part_id,lot_id,op10_actual,op20_actual,op30_actual,
--                  setting_time,tool_change_time,breakdown_time,idle_time,remarks}]
--    p_downtime: [{section,machine_no,start_time,end_time,duration_min,reason,action_taken}]
--    p_quality:  [{section,machine_no,part_id,qty_rejected,rejection_type,defect_type,root_cause,corrective_action}]
-- ---------------------------------------------------------------------
create or replace function post_production(
  p_date date, p_shift text, p_sup1 text, p_sup2 text, p_user text,
  p_rows jsonb, p_downtime jsonb, p_quality jsonb
) returns uuid as $$
declare
  h_id uuid; r jsonb; pid uuid; lid uuid; op10 numeric; cc numeric; lbal numeric;
begin
  if p_sup1 is null or length(trim(p_sup1)) = 0 then
    raise exception 'Supervisor 1 is required.';
  end if;

  insert into production_log(log_period,log_date,shift,supervisor_1,supervisor_2,created_by)
  values (to_char(p_date,'Mon YYYY'), p_date, p_shift, p_sup1, p_sup2, p_user)
  returning id into h_id;

  -- machine rows
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    pid  := nullif(r->>'part_id','')::uuid;
    lid  := nullif(r->>'lot_id','')::uuid;
    op10 := coalesce((r->>'op10_actual')::numeric,0);

    insert into production_rows(production_id,section,machine_no,operator,part_id,lot_id,
      op10_actual,op20_actual,op30_actual,setting_time,tool_change_time,breakdown_time,idle_time,remarks)
    values (h_id, r->>'section', r->>'machine_no', r->>'operator', pid, lid,
      op10, coalesce((r->>'op20_actual')::numeric,0), coalesce((r->>'op30_actual')::numeric,0),
      coalesce((r->>'setting_time')::numeric,0), coalesce((r->>'tool_change_time')::numeric,0),
      coalesce((r->>'breakdown_time')::numeric,0), coalesce((r->>'idle_time')::numeric,0), r->>'remarks');

    -- only OP10 moves stock CC -> WIPFG
    if pid is not null and op10 > 0 then
      cc := check_stock(pid, 'CC');
      if cc < op10 then
        raise exception 'Production blocked: CC balance % < OP10 % for a part', cc, op10;
      end if;
      insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
      values (p_date, pid, 'CC', 'WIPFG', op10, h_id, 'PRODUCTION', 'PRD-'||to_char(p_date,'YYYYMMDD'), 'OP10');
      if lid is not null then
        lbal := lot_balance(lid,'CC');
        if lbal < op10 then raise exception 'Lot CC balance % < OP10 %', lbal, op10; end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values (lid,'CC','WIPFG',op10,h_id,'PRODUCTION','PRD-'||to_char(p_date,'YYYYMMDD'));
        update lot_master set current_bucket='WIPFG' where id=lid;
      end if;
    end if;
  end loop;

  -- downtime sub-log
  for r in select * from jsonb_array_elements(coalesce(p_downtime,'[]'::jsonb)) loop
    insert into downtime_log(production_id,log_date,section,machine_no,start_time,end_time,duration_min,reason,action_taken)
    values (h_id,p_date,r->>'section',r->>'machine_no',r->>'start_time',r->>'end_time',
      nullif(r->>'duration_min','')::numeric,r->>'reason',r->>'action_taken');
  end loop;

  -- quality sub-log
  for r in select * from jsonb_array_elements(coalesce(p_quality,'[]'::jsonb)) loop
    insert into quality_log(production_id,log_date,section,machine_no,part_id,qty_rejected,rejection_type,defect_type,root_cause,corrective_action)
    values (h_id,p_date,r->>'section',r->>'machine_no',nullif(r->>'part_id','')::uuid,
      nullif(r->>'qty_rejected','')::numeric,r->>'rejection_type',r->>'defect_type',r->>'root_cause',r->>'corrective_action');
  end loop;

  perform log_audit('POST PRODUCTION', p_user, h_id::text);
  return h_id;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------
alter table production_log  enable row level security;
alter table production_rows enable row level security;
alter table downtime_log    enable row level security;
alter table quality_log     enable row level security;
do $$ declare t text; begin
  foreach t in array array['production_log','production_rows','downtime_log','quality_log'] loop
    execute format('drop policy if exists pol_%s on %I;', t, t);
    execute format('create policy pol_%s on %I for all using (true) with check (true);', t, t);
  end loop;
end $$;
