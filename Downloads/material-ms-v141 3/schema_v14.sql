-- =====================================================================
--  DMS ERP V14 — RESTRUCTURE SCHEMA  (run ONCE on a fresh DB)
--  Clean reset, then: Ledger (Customer/Vendor RM/Vendor JW), Part (PRT
--  codes, validity-dated pricing), all V13 stock buckets & posting,
--  governance, production. Dates stored as DATE; UI formats DD/MM/YYYY.
--  Module + bucket names kept EXACT per spec.
-- =====================================================================
--
--  *** STOP — READ THIS ***
--  This file ERASES ALL DATA (it drops the whole schema below). It is a
--  ONE-TIME FRESH INSTALL only. To change SQL logic WITHOUT losing data,
--  run update_safe.sql instead — never this file.
--
--  SAFETY GUARD: the block below refuses to run if business data already
--  exists, so this file cannot wipe a live database by accident. If you
--  truly want a clean wipe, set the override flag exactly as instructed in
--  the error message.
-- =====================================================================
do $guard$
declare n bigint := 0;
begin
  if to_regclass('public.part') is not null then
    execute 'select count(*) from part' into n;
  end if;
  if n > 0 and current_setting('dms.force_wipe', true) is distinct from 'YES_DELETE_EVERYTHING' then
    raise exception
      E'REFUSING TO WIPE: this database has % parts (and likely vouchers/stock).\n'
      '   schema_v14.sql erases everything. To UPDATE logic without data loss, run update_safe.sql instead.\n'
      '   If you REALLY want to wipe and reinstall, first run:  set dms.force_wipe = ''YES_DELETE_EVERYTHING'';  then run this file.', n
      using errcode = 'P0001';
  end if;
  -- safe to proceed: perform the wipe INSIDE the guard so it can never run
  -- when the check above refused (even if the client ignores errors).
  execute 'drop schema if exists public cascade';
  execute 'create schema public';
end $guard$;
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all routines in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on routines to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
create extension if not exists pgcrypto;

-- =====================================================================
--  AUTH + SETTINGS
-- =====================================================================
create table app_users (
  id uuid primary key default gen_random_uuid(),
  username text unique not null, password text not null,
  role text not null default 'user' check (role in ('user','can_edit','admin')),
  access_modules text default 'ALL', weight_check boolean default true,
  valid_thru_edit boolean default false,
  active boolean not null default true,           -- disable without deleting
  last_login timestamptz,                          -- set on each successful login
  created_at timestamptz default now()
);
-- per-module action rights: view / create / approve, one row per (user,module)
create table user_module_rights (
  user_id uuid references app_users(id) on delete cascade,
  module text not null,
  can_view boolean default true, can_create boolean default false, can_approve boolean default false,
  can_edit boolean default false, can_markdel boolean default false, can_markedit boolean default false,
  primary key (user_id, module)
);
create function create_app_user(p_username text, p_password text, p_role text default 'user')
returns uuid as $$ declare i uuid; begin
  insert into app_users(username,password,role) values (p_username,crypt(p_password,gen_salt('bf')),p_role) returning id into i; return i; end;
$$ language plpgsql security definer;
create function verify_login(p_username text, p_password text)
returns table(id uuid, username text, role text, access_modules text, weight_check boolean, valid_thru_edit boolean) as $$
  with ok as (
    select u.id from app_users u
    where u.username=p_username and u.password=crypt(p_password,u.password) and coalesce(u.active,true)=true
  ), upd as (
    update app_users set last_login=now() where id in (select id from ok) returning id
  )
  select u.id,u.username,u.role,u.access_modules,u.weight_check,u.valid_thru_edit
  from app_users u where u.id in (select id from ok);
$$ language sql security definer;
select create_app_user('admin','admin123','admin');

-- app-wide settings (LOT allocation toggles)
create table app_settings (key text primary key, value text);
insert into app_settings(key,value) values ('lot_enabled','true'), ('lot_mandatory','false');
create function get_settings() returns table(key text, value text) as $$ select key,value from app_settings; $$ language sql;
create function set_setting(p_key text, p_value text) returns void as $$
  insert into app_settings(key,value) values (p_key,p_value) on conflict(key) do update set value=excluded.value; $$ language sql security definer;

-- database storage usage: total + per-table sizes
create or replace function db_storage_total() returns table(total_bytes bigint, total_pretty text) as $$
  select sum(pg_total_relation_size(c.oid))::bigint,
         pg_size_pretty(sum(pg_total_relation_size(c.oid)))
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('r','m'); $$ language sql security definer;
create or replace function db_storage_by_table() returns table(table_name text, bytes bigint, pretty text, row_estimate bigint) as $$
  select c.relname::text, pg_total_relation_size(c.oid)::bigint, pg_size_pretty(pg_total_relation_size(c.oid)), c.reltuples::bigint
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r'
  order by pg_total_relation_size(c.oid) desc; $$ language sql security definer;

-- =====================================================================
--  STOCK BUCKETS (exact names)
-- =====================================================================
create table buckets (code text primary key, name text, is_external boolean default false);
insert into buckets(code,name,is_external) values
 ('RC','Raw Casting',false),('RCJW','RC@JW',false),('CC','Coated Casting',false),
 ('MG','Machined Goods',false),('PR','Process Rejection',false),('MR','Material Rejection',false),
 ('JOBOUT','Sent Out (expected back)',false),
 ('VENDOR','Vendor',true),('CUSTOMER','Customer',true),('DCNOUT','Sent Out (non-returnable)',true);

-- =====================================================================
--  LOCATIONS  (multi-store) + per-location bucket allow-list
--  Stock identity is (part, location, bucket). External buckets
--  (VENDOR/CUSTOMER/DCNOUT) are global and not location-scoped.
-- =====================================================================
create table location (
  id uuid primary key default gen_random_uuid(),
  loc_code text unique, loc_name text not null,
  status text default 'Active', is_default boolean default false,
  sort_order int default 0, created_at timestamptz default now());

-- which INTERNAL buckets are permitted to exist at each location
create table location_bucket (
  location_id uuid references location(id) on delete cascade,
  bucket text references buckets(code),
  primary key(location_id, bucket));

-- seed a default location (Main Store) with all internal buckets enabled
do $seed_loc$
declare lid uuid;
begin
  insert into location(loc_code,loc_name,status,is_default,sort_order)
    values('MAIN','Main Store','Active',true,0) returning id into lid;
  insert into location_bucket(location_id,bucket)
    select lid, code from buckets where is_external=false;
end $seed_loc$;

-- helper: the default location id
create or replace function default_location() returns uuid as $$
  select id from location where is_default=true order by sort_order limit 1;
$$ language sql stable;

-- helper: is this bucket allowed at this location? (external buckets always ok)
create or replace function bucket_allowed(p_loc uuid, p_bucket text) returns boolean as $$
  select case
    when (select is_external from buckets where code=p_bucket) then true
    when p_loc is null then false
    else exists(select 1 from location_bucket where location_id=p_loc and bucket=p_bucket)
  end;
$$ language sql stable;

-- =====================================================================
--  LEDGER  (Customer / Vendor RM / Vendor JW)
-- =====================================================================
create table ledger (
  id uuid primary key default gen_random_uuid(),
  ledger_type text not null check (ledger_type in ('Customer','Vendor RM','Vendor JW')),
  ledger_code text unique not null,            -- CSRxxx / RMVxxx / JWVxxx
  ledger_name text not null,
  gst_no text, contact_email text,
  tax text check (tax in ('Local','Interstate','Import / Export')),
  status text not null default 'Active' check (status in ('Active','Inactive')),
  created_at timestamptz default now()
);
create function next_ledger_code(p_type text) returns text as $$
declare pre text; n int; begin
  pre := case p_type when 'Customer' then 'CSR' when 'Vendor RM' then 'RMV' when 'Vendor JW' then 'JWV' else 'LDG' end;
  select coalesce(max(substring(ledger_code from 4)::int),0)+1 into n from ledger where ledger_code like pre||'%';
  if n is null then n:=1; end if;
  return pre||lpad(n::text,3,'0'); end; $$ language plpgsql;

-- =====================================================================
--  PART  (PRT codes; validity-dated pricing; allowance on input weight)
-- =====================================================================
create table part (
  id uuid primary key default gen_random_uuid(),
  lb_price numeric default 0,
  part_code text unique not null,              -- PRTxxx
  part_name text not null, part_number text, uom text default 'Nos',
  input_weight_pc numeric default 0, output_weight_pc numeric default 0,
  scrap_weight_pc numeric default 0,           -- input - output
  allowance_pct numeric default 0,             -- +/- % on input weight
  qty_variation numeric default 0,             -- +/- pcs (<=2 digits)
  cumulative_group text,                        -- view-only: group same part across vendors (e.g. "SP2i")
  status text not null default 'Active' check (status in ('Active','Inactive')),
  created_at timestamptz default now()
);
create function next_part_code() returns text as $$
declare n int; begin
  select coalesce(max(substring(part_code from 4)::int),0)+1 into n from part where part_code like 'PRT%';
  if n is null then n:=1; end if; return 'PRT'||lpad(n::text,3,'0'); end; $$ language plpgsql;

-- price rows with validity window + ledger link (purchase=Vendor RM, sale=Customer)
create table part_price (
  id uuid primary key default gen_random_uuid(),
  part_id uuid references part(id) on delete cascade,
  ledger_id uuid references ledger(id) on delete cascade,
  price_type text check (price_type in ('purchase','sale')),
  unit_price numeric default 0,
  lb_price numeric default 0,
  valid_from date, valid_upto date
);
-- part<->ledger mapping is implied by part_price rows.

-- monthly-style price lookup by date within validity window
create function get_price(p_part uuid, p_ledger uuid, p_type text, p_date date)
returns numeric as $$
  select coalesce((select unit_price from part_price
    where part_id=p_part and ledger_id=p_ledger and price_type=p_type
      and (valid_from is null or valid_from<=p_date) and (valid_upto is null or valid_upto>=p_date)
    order by valid_from desc nulls last limit 1),0);
$$ language sql;

-- =====================================================================
--  OPENING + LEDGER/VARIANCE + STOCK VIEWS (BAL = GRS + VAR)
-- =====================================================================
create table opening_stock (part_id uuid references part(id) on delete cascade, location_id uuid references location(id), bucket text references buckets(code), qty numeric default 0, primary key(part_id,location_id,bucket));
create table stock_variance (part_id uuid references part(id), location_id uuid references location(id), bucket text references buckets(code), var_qty numeric default 0, primary key(part_id,location_id,bucket));
create table physical_stock (
  id uuid primary key default gen_random_uuid(), recon_date date default current_date,
  part_id uuid references part(id), location_id uuid references location(id), bucket text references buckets(code),
  system_qty numeric default 0, physical_qty numeric default 0, variance numeric default 0,
  remarks text, created_by text, created_at timestamptz default now());

create table stock_ledger (
  id uuid primary key default gen_random_uuid(), ledger_date date default current_date,
  part_id uuid references part(id),
  from_location uuid references location(id), to_location uuid references location(id),
  from_bucket text references buckets(code), to_bucket text references buckets(code),
  qty numeric not null, voucher_id uuid, voucher_type text, voucher_no text, note text, created_at timestamptz default now());

-- relocated table definitions (needed by stock views below)
create table lot_master (id uuid primary key default gen_random_uuid(), lot_no text unique not null,
  part_id uuid references part(id), ledger_id uuid references ledger(id), current_bucket text references buckets(code),
  original_qty numeric default 0, ref_voucher text, created_at timestamptz default now());
create table lot_ledger (id uuid primary key default gen_random_uuid(), lot_id uuid references lot_master(id),
  from_bucket text, to_bucket text, qty numeric, voucher_id uuid, voucher_type text, voucher_no text, created_at timestamptz default now());

create table vouchers (
  id uuid primary key default gen_random_uuid(),
  vehicle_no text,
  grn boolean default false,
  scrap_slip_wt numeric, voucher_type text not null,
  voucher_id_code text, voucher_no text, voucher_period text,
  voucher_date date default current_date, posting_date date, valid_thru date,
  ledger_id uuid references ledger(id), ref_no text, ref_voucher_id uuid references vouchers(id),
  tax_rate numeric default 18, narration text, status text default 'OPEN', cancelled boolean default false,
  generated boolean default false, rec_copy boolean default false,
  approved_mgmt text default 'APPROVED', approved_acc boolean default false, price_approved text default 'OK',
  rec_hold boolean default false,
  gstr1 boolean default false, gstr2b boolean default false,
  delete_requested boolean default false, modify_requested boolean default false,
  request_reason text, requested_by text, request_date timestamptz,
  created_by text, created_at timestamptz default now(),
  location_id uuid references location(id),
  free_ledger text,
  unique(voucher_type,voucher_no));
create table voucher_lines (
  id uuid primary key default gen_random_uuid(),
  pkg_count numeric default 0,
  lot_alloc jsonb, voucher_id uuid references vouchers(id) on delete cascade,
  sno int, part_id uuid references part(id), lot_id uuid references lot_master(id),
  ref_no text, source_bucket text, qty numeric default 0, invoice_qty numeric default 0, actual_qty numeric default 0,
  uom text default 'Nos', unit_price numeric default 0, po_price numeric default 0, basic_value numeric default 0,
  weight numeric default 0, defect_type text, root_cause text, line_note text,
  disposition text, return_bucket text,
  packages jsonb);   -- [{pkg, token_ref, net_weight, qty}]

create view stock_grs as
select p.id part_id, loc.id location_id, b.code bucket,
  coalesce((select qty from opening_stock o where o.part_id=p.id and o.location_id=loc.id and o.bucket=b.code),0)
  + coalesce((select sum(l.qty) from stock_ledger l left join vouchers v on v.id=l.voucher_id
       where l.part_id=p.id and l.to_location=loc.id and l.to_bucket=b.code and coalesce(v.cancelled,false)=false),0)
  - coalesce((select sum(l.qty) from stock_ledger l left join vouchers v on v.id=l.voucher_id
       where l.part_id=p.id and l.from_location=loc.id and l.from_bucket=b.code and coalesce(v.cancelled,false)=false),0) grs
from part p cross join location loc cross join buckets b where b.is_external=false;

create view stock_var as
select p.id part_id, loc.id location_id, b.code bucket,
  coalesce((select sum(variance) from physical_stock ps where ps.part_id=p.id and ps.location_id=loc.id and ps.bucket=b.code),0)
  + coalesce((select var_qty from stock_variance v where v.part_id=p.id and v.location_id=loc.id and v.bucket=b.code),0) var_qty
from part p cross join location loc cross join buckets b where b.is_external=false;

create view stock_balance as
select g.part_id, g.location_id, g.bucket, g.grs, coalesce(v.var_qty,0) var_qty, g.grs+coalesce(v.var_qty,0) bal
from stock_grs g left join stock_var v on v.part_id=g.part_id and v.location_id=g.location_id and v.bucket=g.bucket;

-- per-location balance
create function check_stock_loc(p_part uuid, p_loc uuid, p_bucket text) returns numeric as $$
  select coalesce((select bal from stock_balance where part_id=p_part and location_id=p_loc and bucket=p_bucket),0); $$ language sql;

-- aggregate balance across ALL locations (back-compat for reads that don't care about location)
create function check_stock(p_part uuid, p_bucket text) returns numeric as $$
  select coalesce((select sum(bal) from stock_balance where part_id=p_part and bucket=p_bucket),0); $$ language sql;

-- =====================================================================
--  EXPLODED STOCK MOVEMENT — per part per bucket, broken into the
--  individual voucher-type movements (the rich Stock Summary grid).
--  One row per (part,bucket). Inflows positive, outflows positive
--  (shown as deductions in the UI). Gross/Var/Bal computed here so the
--  grid never does arithmetic the DB can't verify.
-- =====================================================================
create view stock_explode as
with mv as (
  select l.part_id, b.code bucket,
    -- generic in/out by voucher type, only this bucket, non-cancelled
    sum(case when l.to_bucket=b.code and l.voucher_type='PURCHASE' then l.qty else 0 end) in_purchase,
    sum(case when l.to_bucket=b.code and l.voucher_type='RC_IN_JW' then l.qty else 0 end) in_rcin_jw,
    sum(case when l.to_bucket=b.code and l.voucher_type='DC_OUT_JW' then l.qty else 0 end) in_dcout_jw,
    sum(case when l.to_bucket=b.code and l.voucher_type='PRODUCTION' then l.qty else 0 end) in_production,
    sum(case when l.to_bucket=b.code and l.voucher_type='CREDIT_NOTE' then l.qty else 0 end) in_salesreturn,
    sum(case when l.to_bucket=b.code and l.voucher_type='PROCESS_REJECTION' then l.qty else 0 end) in_procrej,
    sum(case when l.to_bucket=b.code and l.voucher_type='MATERIAL_REJECTION' then l.qty else 0 end) in_matrej,
    sum(case when l.to_bucket=b.code and l.voucher_type='RC_IN_RET' then l.qty else 0 end) in_rcr,
    sum(case when l.to_bucket=b.code and l.voucher_type='RC_IN_REPLACE' then l.qty else 0 end) in_rcm,
    -- outflows
    sum(case when l.from_bucket=b.code and l.voucher_type='DEBIT_NOTE_RC' then l.qty else 0 end) out_dn_rc,
    sum(case when l.from_bucket=b.code and l.voucher_type='DEBIT_NOTE_DN' then l.qty else 0 end) out_dn,
    sum(case when l.from_bucket=b.code and l.voucher_type='DC_OUT_JW' then l.qty else 0 end) out_dcout_jw,
    sum(case when l.from_bucket=b.code and l.voucher_type='RC_IN_JW' then l.qty else 0 end) out_rcin_jw,
    sum(case when l.from_bucket=b.code and l.voucher_type='PRODUCTION' then l.qty else 0 end) out_production,
    sum(case when l.from_bucket=b.code and l.voucher_type='SALES_LOCAL' then l.qty else 0 end) out_sales,
    sum(case when l.from_bucket=b.code and l.voucher_type='SCRAP_SALES' then l.qty else 0 end) out_scrap,
    sum(case when l.from_bucket=b.code and l.voucher_type='PROCESS_REJECTION' then l.qty else 0 end) out_procrej,
    sum(case when l.from_bucket=b.code and l.voucher_type='MATERIAL_REJECTION' then l.qty else 0 end) out_matrej,
    sum(case when l.from_bucket=b.code and l.voucher_type='DC_OUT_RET' then l.qty else 0 end) out_dcr,
    sum(case when l.from_bucket=b.code and l.voucher_type='DC_OUT_NONRET' then l.qty else 0 end) out_dcn,
    sum(case when l.from_bucket=b.code and l.voucher_type='DC_OUT_REPLACE' then l.qty else 0 end) out_dcm
  from stock_ledger l
  left join vouchers v on v.id=l.voucher_id
  cross join buckets b
  where b.is_external=false and coalesce(v.cancelled,false)=false
    and (l.to_bucket=b.code or l.from_bucket=b.code)
  group by l.part_id, b.code
)
select p.id part_id, p.part_code, p.part_name, p.cumulative_group, b.code bucket,
  coalesce((select sum(qty) from opening_stock o where o.part_id=p.id and o.bucket=b.code),0) opening,
  coalesce(m.in_purchase,0) in_purchase, coalesce(m.in_rcin_jw,0) in_rcin_jw, coalesce(m.in_dcout_jw,0) in_dcout_jw,
  coalesce(m.in_production,0) in_production, coalesce(m.in_salesreturn,0) in_salesreturn,
  coalesce(m.in_procrej,0) in_procrej, coalesce(m.in_matrej,0) in_matrej,
  coalesce(m.in_rcr,0) in_rcr, coalesce(m.in_rcm,0) in_rcm,
  coalesce(m.out_dn_rc,0) out_dn_rc, coalesce(m.out_dn,0) out_dn, coalesce(m.out_dcout_jw,0) out_dcout_jw,
  coalesce(m.out_rcin_jw,0) out_rcin_jw,
  coalesce(m.out_production,0) out_production, coalesce(m.out_sales,0) out_sales, coalesce(m.out_scrap,0) out_scrap,
  coalesce(m.out_procrej,0) out_procrej, coalesce(m.out_matrej,0) out_matrej,
  coalesce(m.out_dcr,0) out_dcr, coalesce(m.out_dcn,0) out_dcn, coalesce(m.out_dcm,0) out_dcm,
  -- physical & variance from stock_var/recon (summed across locations)
  coalesce((select sum(variance) from physical_stock ps where ps.part_id=p.id and ps.bucket=b.code),0)
    + coalesce((select sum(var_qty) from stock_variance sv where sv.part_id=p.id and sv.bucket=b.code),0) variance,
  coalesce((select sum(bal) from stock_balance s2 where s2.part_id=p.id and s2.bucket=b.code),0) bal
from part p cross join buckets b
left join mv m on m.part_id=p.id and m.bucket=b.code
where p.status='Active' and b.is_external=false;

create view stock_summary as
select p.id part_id, p.part_code, p.part_name,
  (select bal from stock_balance s where s.part_id=p.id and s.bucket='RC') rc_bal,
  (select bal from stock_balance s where s.part_id=p.id and s.bucket='RCJW') rcjw_bal,
  (select bal from stock_balance s where s.part_id=p.id and s.bucket='CC') cc_bal,
  (select bal from stock_balance s where s.part_id=p.id and s.bucket='MG') mg_bal,
  (select bal from stock_balance s where s.part_id=p.id and s.bucket='PR') pr_bal,
  (select bal from stock_balance s where s.part_id=p.id and s.bucket='MR') mr_bal,
  (select bal from stock_balance s where s.part_id=p.id and s.bucket='JOBOUT') jobout_bal
from part p where p.status='Active';

-- ---- cumulative grouping (VIEW ONLY): same part bought from many vendors ----
-- distinct group names for the Part-form dropdown
create or replace function cumulative_groups() returns table(grp text) as $$
  select distinct cumulative_group from part where nullif(trim(cumulative_group),'') is not null order by 1;
$$ language sql;
-- (stock_summary_cumulative is defined later, after stock_cache exists)

-- ---- anti-loophole: conservation & negative-balance diagnostics ----
-- Any row here = a problem. Negative internal balance, or JOBOUT out without trace.
create view stock_diagnostics as
select p.id part_id, p.part_code, b.code bucket, s.bal
from part p cross join buckets b
join stock_balance s on s.part_id=p.id and s.bucket=b.code
where b.is_external=false and s.bal < 0;

-- JOBOUT tracked by the source bucket it came from (per spec: show what's out & from where)
create view jobout_by_source as
select l.part_id, p.part_code, p.part_name,
  coalesce(l.source_origin, l.note, 'UNKNOWN') source_bucket,
  sum(case when l.to_bucket='JOBOUT' then l.qty else 0 end)
  - sum(case when l.from_bucket='JOBOUT' then l.qty else 0 end) out_qty
from (
  select sl.*, vl.source_bucket source_origin
  from stock_ledger sl
  left join vouchers v on v.id=sl.voucher_id
  left join voucher_lines vl on vl.voucher_id=sl.voucher_id and vl.part_id=sl.part_id
  where (sl.to_bucket='JOBOUT' or sl.from_bucket='JOBOUT') and coalesce(v.cancelled,false)=false
) l join part p on p.id=l.part_id
group by l.part_id, p.part_code, p.part_name, coalesce(l.source_origin, l.note, 'UNKNOWN')
having (sum(case when l.to_bucket='JOBOUT' then l.qty else 0 end)
      - sum(case when l.from_bucket='JOBOUT' then l.qty else 0 end)) <> 0;

create function get_recon_grid() returns table(part_id uuid, part_code text, part_name text, bucket text, system_qty numeric) as $$
  select p.id,p.part_code,p.part_name,b.code,check_stock(p.id,b.code) from part p cross join buckets b
  where p.status='Active' and b.is_external=false order by p.part_code,b.code; $$ language sql;
create function post_reconciliation(p_date date, p_user text, p_rows jsonb) returns int as $$
declare r jsonb; sys numeric; phys numeric; n int:=0; lid uuid; begin
  for r in select * from jsonb_array_elements(p_rows) loop
    lid := coalesce(nullif(r->>'location_id','')::uuid, default_location());
    sys:=check_stock_loc((r->>'part_id')::uuid,lid,r->>'bucket'); phys:=coalesce((r->>'physical_qty')::numeric,sys);
    if phys<>sys then insert into physical_stock(recon_date,part_id,location_id,bucket,system_qty,physical_qty,variance,remarks,created_by)
      values(p_date,(r->>'part_id')::uuid,lid,r->>'bucket',sys,phys,phys-sys,r->>'remarks',p_user);
      perform recache_cell((r->>'part_id')::uuid,lid,r->>'bucket'); n:=n+1; end if;
  end loop; return n; end; $$ language plpgsql security definer;

-- =====================================================================
--  LOT ENGINE
-- =====================================================================
-- (lot_master & lot_ledger tables relocated earlier for dependency order)
create function next_lot_no(p_part uuid, p_ledger uuid) returns text as $$
declare pc text; vc text; n int; begin
  select part_code into pc from part where id=p_part;
  select upper(left(regexp_replace(ledger_name,'[^A-Za-z0-9]','','g'),6)) into vc from ledger where id=p_ledger;
  vc:=coalesce(nullif(vc,''),'LDG');
  select coalesce(max(nullif(regexp_replace(lot_no,'^.*-',''),'')::int),0)+1 into n from lot_master where part_id=p_part and ledger_id=p_ledger;
  if n is null then n:=1; end if; return coalesce(pc,'PRT')||'-'||vc||'-'||lpad(n::text,3,'0'); end; $$ language plpgsql;
create function lot_balance(p_lot uuid, p_bucket text) returns numeric as $$
  select coalesce((select sum(qty) from lot_ledger where lot_id=p_lot and to_bucket=p_bucket),0)
       - coalesce((select sum(qty) from lot_ledger where lot_id=p_lot and from_bucket=p_bucket),0); $$ language sql;
create function available_lots(p_part uuid, p_bucket text) returns table(lot_id uuid, lot_no text, ledger text, available numeric, origin_date date) as $$
  select m.id,m.lot_no,l.ledger_name,lot_balance(m.id,p_bucket),m.created_at::date from lot_master m
  left join ledger l on l.id=m.ledger_id where m.part_id=p_part and lot_balance(m.id,p_bucket)>0 order by m.created_at; $$ language sql;
create view lot_wise_stock as
select m.id lot_id,m.lot_no,p.part_code,p.part_name,l.ledger_name ledger,m.created_at::date origin_date,
  lot_balance(m.id,'RC') rc,lot_balance(m.id,'RCJW') rcjw,lot_balance(m.id,'CC') cc,lot_balance(m.id,'MG') mg,
  lot_balance(m.id,'PR') pr,lot_balance(m.id,'MR') mr,lot_balance(m.id,'JOBOUT') jobout,
  (lot_balance(m.id,'RC')+lot_balance(m.id,'RCJW')+lot_balance(m.id,'CC')+lot_balance(m.id,'MG')+lot_balance(m.id,'PR')+lot_balance(m.id,'MR')+lot_balance(m.id,'JOBOUT')) total
from lot_master m join part p on p.id=m.part_id left join ledger l on l.id=m.ledger_id;

-- =====================================================================
--  VOUCHERS (exact module keys per spec) + lines
-- =====================================================================
-- (vouchers & voucher_lines tables relocated earlier for dependency order)

-- Voucher ID code prefixes (POxxx etc) and voucher_no auto-seed
create function next_voucher_idcode(p_type text) returns text as $$
declare pre text; n int; begin
  pre := case p_type
    when 'PURCHASE_ORDER' then 'PO' when 'PURCHASE' then 'PUR' when 'DEBIT_NOTE_RC' then 'DNRC'
    when 'DC_OUT_JW' then 'DCO' when 'RC_IN_JW' then 'RCI' when 'PRODUCTION' then 'PRD'
    when 'SALES_ORDER' then 'SO' when 'SALES_LOCAL' then 'SAL' when 'CREDIT_NOTE' then 'CN'
    when 'PROCESS_REJECTION' then 'PRJ' when 'SCRAP_SALES' then 'SCR' when 'MATERIAL_REJECTION' then 'MRJ'
    when 'DEBIT_NOTE_DN' then 'DN' when 'DC_OUT_RET' then 'DCR' when 'RC_IN_RET' then 'RCR'
    when 'DC_OUT_REPLACE' then 'DCP' when 'RC_IN_REPLACE' then 'RCP' when 'DC_OUT_NONRET' then 'DCN'
    else 'VCH' end;
  select coalesce(max(substring(voucher_id_code from length(pre)+1)::int),0)+1 into n
    from vouchers where voucher_type=p_type and voucher_id_code ~ ('^'||pre||'[0-9]+$');
  if n is null then n:=1; end if; return pre||lpad(n::text,3,'0'); end; $$ language plpgsql;

-- Valid-Through = 5th of next month relative to voucher date's month
create function valid_thru_5th(p_date date) returns date as $$
  select (date_trunc('month', p_date) + interval '1 month' + interval '4 days')::date; $$ language sql;

-- =====================================================================
--  POST VOUCHER (bucket map uses exact module keys)
-- =====================================================================

-- ---- RESALE availability: only MG stock that arrived via Sales Returns (Resale disposition) ----
create or replace function resale_available(p_part uuid) returns numeric as $$
  select greatest(
    coalesce((select sum(qty) from stock_ledger
       where part_id=p_part and to_bucket='MG' and voucher_type='CREDIT_NOTE'),0)
    - coalesce((select sum(qty) from stock_ledger
       where part_id=p_part and from_bucket='MG' and voucher_type='RESALE'),0)
  , 0);
$$ language sql;

create function post_voucher(
  p_type text, p_idcode text, p_no text, p_date date, p_posting date, p_valid date,
  p_ledger uuid, p_ref_voucher uuid, p_ref_no text, p_tax numeric, p_narration text,
  p_user text, p_lines jsonb, p_price_pending boolean default false, p_location uuid default null, p_free_ledger text default null, p_vehicle text default null, p_slip numeric default null
) returns jsonb as $$
declare v_id uuid; ln jsonb; i int:=0; from_b text; to_b text; move_date date; on_hand numeric;
  lid uuid; new_lot text; lbal numeric; lqty numeric; is_variant boolean:=false; src text; vdir text;
  cnt int; pend numeric; buf numeric:=250; lot_on boolean; lot_must boolean; price_pending boolean:=false; po_pr numeric;
  la jsonb; la_q numeric; la_tot numeric;
  rec_hold boolean:=false;
begin
  -- no voucher number given -> use the voucher ID code as the number
  p_no := coalesce(nullif(trim(p_no),''), p_idcode);
  if p_price_pending then price_pending:=true; end if;
  if p_location is null then p_location := default_location(); end if;
  select (value='true') into lot_on from app_settings where key='lot_enabled';
  select (value='true') into lot_must from app_settings where key='lot_mandatory';

  perform assert_voucher_enabled(p_type);  -- feature 4: blocked if disabled in Settings

  -- PERIOD LOCK: neither the document date nor the posting date may fall in a closed month
  if to_regclass('public.period_lock') is not null then
    if period_is_locked(p_date) then
      raise exception 'PERIOD CLOSED: voucher date % is in a locked month.', to_char(p_date,'DD Mon YYYY') using errcode='23514';
    end if;
    if p_posting is not null and period_is_locked(p_posting) then
      raise exception 'PERIOD CLOSED: posting date % is in a locked month.', to_char(p_posting,'DD Mon YYYY') using errcode='23514';
    end if;
  end if;

  -- DC Out (JW): block new DCs when overdue ones are pending (admin override clears)
  if p_type='DC_OUT_JW' then perform dcjw_overdue_block(p_ledger); end if;

  -- SHARED RECEIVED-COPY GATE -----------------------------------------
  -- Types in the gate: Sales Local, Scrap Sales, both Debit Notes,
  -- DC Out (JW). If ANY such doc is >2 calendar days past its voucher
  -- date with Received Copy still unticked, every NEW gated doc is held
  -- (no stock movement) and routed to Rec Copy Approval until cleared.
  if p_type in ('SALES_LOCAL','SCRAP_SALES','DEBIT_NOTE_RC','DEBIT_NOTE_DN','DC_OUT_JW','DC_OUT_RET','DC_OUT_NONRET','DC_OUT_REPLACE') then
    if rec_copy_overdue_exists() then rec_hold := true; end if;
  end if;

  -- max 2 active orders per part
  if p_type in ('PURCHASE_ORDER','SALES_ORDER') then
    for ln in select * from jsonb_array_elements(p_lines) loop
      select count(distinct order_id) into cnt from open_orders where voucher_type=p_type and part_id=(ln->>'part_id')::uuid;
      if cnt>=2 then raise exception 'Max 2 active %s allowed for this part.', case p_type when 'PURCHASE_ORDER' then 'PO' else 'SO' end; end if;
    end loop;
  end if;

  insert into vouchers(voucher_type,voucher_id_code,voucher_no,voucher_period,voucher_date,posting_date,valid_thru,
    ledger_id,ref_voucher_id,ref_no,tax_rate,narration,created_by,status,price_approved,location_id,free_ledger,rec_hold,vehicle_no,scrap_slip_wt)
  values (p_type,p_idcode,p_no,to_char(p_date,'Mon YYYY'),p_date,p_posting,p_valid,p_ledger,p_ref_voucher,p_ref_no,
    coalesce(p_tax,18),p_narration,p_user,'OPEN', case when price_pending then 'PENDING' else 'OK' end, p_location, nullif(p_free_ledger,''), rec_hold, nullif(trim(coalesce(p_vehicle,'')),''), p_slip) returning id into v_id;

  case p_type
    when 'PURCHASE' then from_b:='VENDOR'; to_b:='RC';
    when 'DEBIT_NOTE_RC' then from_b:='RC'; to_b:='VENDOR';
    when 'DC_OUT_JW' then from_b:='RC'; to_b:='RCJW';
    when 'RC_IN_JW' then from_b:='RCJW'; to_b:='CC';
    when 'SALES_LOCAL' then from_b:='MG'; to_b:='CUSTOMER';
    when 'RESALE' then from_b:='MG'; to_b:='CUSTOMER';
    when 'CREDIT_NOTE' then from_b:='CUSTOMER'; to_b:=null;  -- per-line disposition
    when 'PROCESS_REJECTION' then from_b:='MG'; to_b:='PR';
    when 'MATERIAL_REJECTION' then from_b:='MG'; to_b:='MR';
    when 'SCRAP_SALES' then from_b:='PR'; to_b:='CUSTOMER';
    when 'DEBIT_NOTE_DN' then from_b:='MR'; to_b:='VENDOR';
    else from_b:=null; to_b:=null; end case;

  if p_type in ('DC_OUT_RET','DC_OUT_REPLACE','DC_OUT_NONRET') then is_variant:=true; vdir:='OUT';
  elsif p_type in ('RC_IN_RET','RC_IN_REPLACE') then is_variant:=true; vdir:='IN'; end if;

  move_date:=coalesce(p_posting,p_date);
  for ln in select * from jsonb_array_elements(p_lines) loop
    i:=i+1; lqty:=coalesce((ln->>'qty')::numeric,0); src:=nullif(ln->>'source_bucket','');

    if p_type='PURCHASE' and nullif(ln->>'ref_no','') is not null then
      select pending_qty into pend from order_fulfilment where voucher_type='PURCHASE_ORDER' and voucher_no=ln->>'ref_no' and part_id=(ln->>'part_id')::uuid limit 1;
      if pend is not null and coalesce((ln->>'actual_qty')::numeric,lqty)>pend then raise exception 'Purchase exceeds PO pending: % vs %', coalesce((ln->>'actual_qty')::numeric,lqty), pend; end if;
    end if;
    if p_type in ('RC_IN_JW','RC_IN_RET','RC_IN_REPLACE') and nullif(ln->>'ref_no','') is not null then
      select pending_qty into pend from dc_fulfilment where voucher_no=ln->>'ref_no' and part_id=(ln->>'part_id')::uuid limit 1;
      if pend is not null and lqty>pend then raise exception 'RC In exceeds DC pending: % vs %', lqty, pend; end if;
    end if;

    insert into voucher_lines(voucher_id,sno,part_id,lot_id,ref_no,source_bucket,qty,invoice_qty,actual_qty,uom,unit_price,po_price,basic_value,weight,defect_type,root_cause,line_note,disposition,return_bucket,packages,pkg_count,lot_alloc)
    values (v_id,i,(ln->>'part_id')::uuid,nullif(ln->>'lot_id','')::uuid,ln->>'ref_no',src,lqty,
      coalesce((ln->>'invoice_qty')::numeric,0),coalesce((ln->>'actual_qty')::numeric,0),coalesce(ln->>'uom','Nos'),
      coalesce((ln->>'unit_price')::numeric,0),coalesce((ln->>'po_price')::numeric,0),coalesce((ln->>'basic_value')::numeric,0),
      coalesce((ln->>'weight')::numeric,0),ln->>'defect_type',ln->>'root_cause',ln->>'line_note',
      nullif(ln->>'disposition',''),nullif(ln->>'return_bucket',''),(ln->'packages'),coalesce((ln->>'pkg_count')::numeric,0),(ln->'lot_alloc'));

    if p_type='CREDIT_NOTE' then
      -- spec: return quantity cannot exceed what was sold (net of earlier returns) for this part & party
      declare sold numeric; ret numeric; begin
        select coalesce(sum(l2.qty),0) into sold from voucher_lines l2 join vouchers v2 on v2.id=l2.voucher_id
          where v2.voucher_type='SALES_LOCAL' and coalesce(v2.cancelled,false)=false and coalesce(v2.rec_hold,false)=false
            and v2.ledger_id=p_ledger and l2.part_id=(ln->>'part_id')::uuid;
        select coalesce(sum(l3.qty),0) into ret from voucher_lines l3 join vouchers v3 on v3.id=l3.voucher_id
          where v3.voucher_type='CREDIT_NOTE' and coalesce(v3.cancelled,false)=false
            and v3.ledger_id=p_ledger and l3.part_id=(ln->>'part_id')::uuid and v3.id<>v_id;
        if lqty > sold - ret then
          raise exception 'Sales Return blocked: returning %, but net sold to this party is % (sold % - returned %).', lqty, sold-ret, sold, ret;
        end if;
      end;
      -- Sales Return disposition: Process -> PR, Material -> MR, Resale -> MG
      case coalesce(ln->>'disposition','RESALE')
        when 'PROCESS' then to_b:='PR'; when 'MATERIAL' then to_b:='MR'; else to_b:='MG'; end case;
    end if;

    if is_variant then
      if src is null then raise exception 'Source bucket required for %', p_type; end if;
      if vdir='OUT' then
        if p_type='DC_OUT_NONRET' then from_b:=src; to_b:='DCNOUT';   -- permanent subtract
        else from_b:=src; to_b:='JOBOUT'; end if;                     -- DCR / DCM held as out
      else
        from_b:='JOBOUT';
        if p_type='RC_IN_REPLACE' then to_b:=coalesce(nullif(ln->>'return_bucket',''),src);  -- RCM: user-picked
        else to_b:=src; end if;                                        -- RCR: back to source
      end if;
    end if;

    if from_b is not null and not price_pending and not rec_hold then
      if from_b not in ('VENDOR','CUSTOMER') then
        on_hand:=check_stock((ln->>'part_id')::uuid,from_b);
        if p_type='SALES_LOCAL' then
          if lqty>on_hand+buf then raise exception 'Sales blocked. FG Stock: %, Max (stock+%): %, entered: %', on_hand, buf, on_hand+buf, lqty; end if;
        elsif p_type='RESALE' then
          declare ravail numeric; begin
            ravail := resale_available((ln->>'part_id')::uuid);
            if lqty > ravail then raise exception 'Resale blocked: only % available in MG from Sales Returns (resale), requested %', ravail, lqty; end if;
          end;
        elsif on_hand<lqty then raise exception '% blocked: % balance %, requested %', p_type, from_b, on_hand, lqty; end if;
      end if;
      perform post_stock_move(move_date,(ln->>'part_id')::uuid,from_b,to_b,lqty,v_id,p_type,p_no,p_narration,
        case when p_type='SALES_LOCAL' then buf else 0 end, p_location, p_location);

      if p_type='PURCHASE' and lqty>0 then
        if lot_on then
          new_lot:=next_lot_no((ln->>'part_id')::uuid,p_ledger);
          insert into lot_master(lot_no,part_id,ledger_id,current_bucket,original_qty,ref_voucher) values(new_lot,(ln->>'part_id')::uuid,p_ledger,'RC',lqty,p_no) returning id into lid;
          insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,'VENDOR','RC',lqty,v_id,p_type,p_no);
        end if;
      elsif lot_on and jsonb_typeof(ln->'lot_alloc')='array' and jsonb_array_length(ln->'lot_alloc')>0 then
        la_tot:=0;
        for la in select * from jsonb_array_elements(ln->'lot_alloc') loop
          lid:=nullif(la->>'lot_id','')::uuid; la_q:=coalesce((la->>'qty')::numeric,0);
          if lid is null or la_q<=0 then continue; end if;
          lbal:=lot_balance(lid,from_b);
          if lbal<la_q then raise exception 'Lot % insufficient in %: have %, need %',
            coalesce((select lot_no from lot_master where id=lid),'?'), from_b, lbal, la_q; end if;
          insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,from_b,to_b,la_q,v_id,p_type,p_no);
          update lot_master set current_bucket=to_b where id=lid;
          la_tot:=la_tot+la_q;
        end loop;
        if la_tot<>lqty then raise exception 'Lot allocation total % must equal line qty %', la_tot, lqty; end if;
      elsif lot_on and nullif(ln->>'lot_id','') is not null then
        lid:=(ln->>'lot_id')::uuid; lbal:=lot_balance(lid,from_b);
        if lbal<lqty then raise exception 'Lot insufficient in %: have %, need %', from_b, lbal, lqty; end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,from_b,to_b,lqty,v_id,p_type,p_no);
        update lot_master set current_bucket=to_b where id=lid;
      elsif lot_on and lot_must and from_b not in ('VENDOR','CUSTOMER') then
        raise exception 'Lot allocation is mandatory for %', p_type;
      end if;
    end if;
  end loop;

  -- close fulfilled refs
  update vouchers o set status='CLOSED' where o.voucher_no in (select distinct ln2->>'ref_no' from jsonb_array_elements(p_lines) ln2 where nullif(ln2->>'ref_no','') is not null)
    and o.voucher_type in ('PURCHASE_ORDER','SALES_ORDER','DC_OUT_JW','DC_OUT_RET','DC_OUT_REPLACE')
    and not exists (select 1 from order_fulfilment f where f.order_id=o.id and f.pending_qty>0 union all select 1 from dc_fulfilment d where d.dc_id=o.id and d.pending_qty>0);

  perform log_audit(case when rec_hold then 'HELD (rec-copy) ' else 'POST ' end||p_type, p_user, p_no);
  return jsonb_build_object('id',v_id,'price_pending',price_pending,'rec_hold',rec_hold);
end; $$ language plpgsql security definer;

-- =====================================================================
--  ORDER / DC FULFILMENT
-- =====================================================================
create view order_fulfilment as
select v.id order_id, v.voucher_type, v.voucher_no, v.voucher_date, v.valid_thru, v.ledger_id, v.status,
  vl.id line_id, vl.part_id, vl.qty order_qty,
  coalesce((select sum(cl.qty) from voucher_lines cl join vouchers cv on cv.id=cl.voucher_id
    where cv.voucher_type=case v.voucher_type when 'PURCHASE_ORDER' then 'PURCHASE' when 'SALES_ORDER' then 'SALES_LOCAL' end
      and cv.cancelled=false and cl.ref_no=v.voucher_no and cl.part_id=vl.part_id),0) fulfilled_qty,
  greatest(vl.qty-coalesce((select sum(cl.qty) from voucher_lines cl join vouchers cv on cv.id=cl.voucher_id
    where cv.voucher_type=case v.voucher_type when 'PURCHASE_ORDER' then 'PURCHASE' when 'SALES_ORDER' then 'SALES_LOCAL' end
      and cv.cancelled=false and cl.ref_no=v.voucher_no and cl.part_id=vl.part_id),0),0) pending_qty
from vouchers v join voucher_lines vl on vl.voucher_id=v.id
where v.voucher_type in ('PURCHASE_ORDER','SALES_ORDER') and v.cancelled=false;

create view open_orders as select * from order_fulfilment where pending_qty>0 and (valid_thru is null or valid_thru>=current_date);

create view dc_fulfilment as
select v.id dc_id, v.voucher_type, v.voucher_no, v.voucher_date, v.valid_thru due_date, v.ledger_id, vl.part_id, vl.qty dc_qty,
  coalesce((select sum(rl.qty) from voucher_lines rl join vouchers rv on rv.id=rl.voucher_id
    where rv.cancelled=false and rl.ref_no=v.voucher_no and rl.part_id=vl.part_id and rv.voucher_type in ('RC_IN_JW','RC_IN_RET','RC_IN_REPLACE')),0) received_qty,
  greatest(vl.qty-coalesce((select sum(rl.qty) from voucher_lines rl join vouchers rv on rv.id=rl.voucher_id
    where rv.cancelled=false and rl.ref_no=v.voucher_no and rl.part_id=vl.part_id and rv.voucher_type in ('RC_IN_JW','RC_IN_RET','RC_IN_REPLACE')),0),0) pending_qty
from vouchers v join voucher_lines vl on vl.voucher_id=v.id
where v.voucher_type in ('DC_OUT_JW','DC_OUT_RET','DC_OUT_REPLACE') and v.cancelled=false;
create view open_dcs as select * from dc_fulfilment where pending_qty>0;

-- =====================================================================
--  GOVERNANCE: audit, gates, marks, listing, doc flags
-- =====================================================================
create table audit_log (id uuid primary key default gen_random_uuid(), ts timestamptz default now(), action text, app_user text, details text);
create function log_audit(p_action text, p_user text, p_details text) returns void as $$ insert into audit_log(action,app_user,details) values(p_action,p_user,p_details); $$ language sql;

create function price_pending() returns table(id uuid, voucher_no text, voucher_date date, ledger_id uuid) as $$
  select id,voucher_no,voucher_date,ledger_id from vouchers where price_approved='PENDING' and cancelled=false order by created_at; $$ language sql;
create function approve_price(p_id uuid) returns void as $$ update vouchers set price_approved='OK' where id=p_id; $$ language sql security definer;

create function rec_copy_pending() returns table(id uuid, voucher_type text, voucher_no text, voucher_date date) as $$
  select id,voucher_type,voucher_no,voucher_date from vouchers where approved_mgmt='PENDING' and cancelled=false order by created_at; $$ language sql;
create function approve_rec_copy(p_ids uuid[]) returns int as $$
  with u as (update vouchers set approved_mgmt='APPROVED' where id=any(p_ids) returning 1) select count(*)::int from u; $$ language sql security definer;

-- ====================================================================
--  SHARED RECEIVED-COPY GATE (2-day rule)
--  Types: Sales Local, Scrap Sales, both Debit Notes, DC Out (JW).
-- ====================================================================
-- Is any gated doc >2 calendar days past its voucher date with rec_copy
-- still unticked (and not itself already on hold / cancelled)?
create or replace function rec_copy_overdue_exists() returns boolean as $$
  select exists(
    select 1 from vouchers
    where voucher_type in ('SALES_LOCAL','SCRAP_SALES','DEBIT_NOTE_RC','DEBIT_NOTE_DN','DC_OUT_JW')
      and coalesce(cancelled,false)=false
      and coalesce(rec_copy,false)=false
      and coalesce(rec_hold,false)=false
      and ( (valid_thru is not null and current_date > valid_thru)
         or (valid_thru is null and created_at < now() - interval '3 days') )
  ); $$ language sql;

-- docs currently held awaiting rec-copy approval (no stock posted yet)
create or replace function rec_copy_holds() returns table(
  id uuid, voucher_type text, voucher_no text, voucher_date date, ledger_name text, total_qty numeric, total_value numeric) as $$
  select v.id, v.voucher_type, v.voucher_no, v.voucher_date, coalesce(v.free_ledger,l.ledger_name),
    coalesce((select sum(qty) from voucher_lines x where x.voucher_id=v.id),0),
    coalesce((select sum(basic_value) from voucher_lines x where x.voucher_id=v.id),0)
  from vouchers v left join ledger l on l.id=v.ledger_id
  where coalesce(v.rec_hold,false)=true and coalesce(v.cancelled,false)=false
  order by v.created_at; $$ language sql;

-- approve a held doc: lift the hold and post its stock now (mirrors price approval)
create or replace function approve_rec_hold(p_id uuid, p_user text) returns jsonb as $$
declare v vouchers%rowtype; ln record; from_b text; to_b text; src text; buf numeric:=250; on_hand numeric;
begin
  select * into v from vouchers where id=p_id;
  if v.id is null then return jsonb_build_object('ok',false,'msg','Not found'); end if;
  if not coalesce(v.rec_hold,false) then return jsonb_build_object('ok',false,'msg','Not on rec-copy hold'); end if;

  -- re-derive each line's move from the bucket map and post it through the gate
  for ln in select * from voucher_lines where voucher_id=p_id order by sno loop
    select bm.from_bucket, bm.to_bucket into from_b, to_b from bucket_map bm where bm.voucher_type=v.voucher_type;
    if from_b is not null then
      perform post_stock_move(coalesce(v.posting_date,v.voucher_date), ln.part_id, from_b, to_b,
        coalesce(nullif(ln.actual_qty,0),ln.qty), p_id, v.voucher_type, v.voucher_no, 'rec-copy approved',
        case when v.voucher_type='SALES_LOCAL' then buf else 0 end, v.location_id, v.location_id);
    end if;
  end loop;

  update vouchers set rec_hold=false where id=p_id;
  perform log_audit('REC-COPY APPROVE', p_user, v.voucher_no);
  return jsonb_build_object('ok',true,'voucher_no',v.voucher_no);
end; $$ language plpgsql security definer;

create or replace function reject_rec_hold(p_id uuid, p_user text) returns jsonb as $$
declare vno text;
begin
  select voucher_no into vno from vouchers where id=p_id;
  update vouchers set cancelled=true, rec_hold=false where id=p_id;
  perform log_audit('REC-COPY REJECT', p_user, vno);
  return jsonb_build_object('ok',true,'msg','Rejected; document discarded (no stock posted).');
end; $$ language plpgsql security definer;

create function mark_record(p_id uuid, p_mark text, p_reason text, p_user text, p_role text) returns jsonb as $$
declare created timestamptz; age interval; begin
  select created_at into created from vouchers where id=p_id; if created is null then return jsonb_build_object('ok',false,'msg','Not found'); end if;
  age:=now()-created;
  if p_role not in ('admin','can_edit') then return jsonb_build_object('ok',false,'msg','No permission'); end if;
  if p_reason is null or length(trim(p_reason))=0 then return jsonb_build_object('ok',false,'msg','Reason required'); end if;
  if p_mark='modify' and p_role<>'admin' and age>interval '8 hours' then return jsonb_build_object('ok',false,'msg','8-hour modify window passed'); end if;
  update vouchers set delete_requested=(p_mark='delete') or delete_requested, modify_requested=(p_mark='modify') or modify_requested,
    request_reason=p_reason, requested_by=p_user, request_date=now() where id=p_id;
  perform log_audit('MARK '||p_mark,p_user,p_id::text); return jsonb_build_object('ok',true,'msg','Submitted for approval'); end; $$ language plpgsql security definer;
create function marked_requests() returns table(id uuid, voucher_type text, voucher_no text, delete_requested boolean, modify_requested boolean, request_reason text, requested_by text) as $$
  select id,voucher_type,voucher_no,delete_requested,modify_requested,request_reason,requested_by from vouchers where (delete_requested or modify_requested) and cancelled=false order by request_date; $$ language sql;
create function resolve_mark(p_id uuid, p_mark text, p_action text, p_admin text) returns void as $$
begin
  if p_action='approve' and p_mark='delete' then
    if exists(
      select 1 from vouchers c where coalesce(c.cancelled,false)=false and c.id<>p_id and (
        c.ref_voucher_id=p_id or
        c.ref_no = (select voucher_no from vouchers where id=p_id) or
        exists(select 1 from voucher_lines cl where cl.voucher_id=c.id and cl.ref_no=(select voucher_no from vouchers where id=p_id)))
    ) then
      raise exception 'Cannot delete: this voucher is linked to other voucher(s) (e.g. a Purchase/Sales/RC-In references it). Cancel the dependent voucher first.';
    end if;
    update vouchers set cancelled=true,delete_requested=false where id=p_id;
  elsif p_action='approve' and p_mark='modify' then update vouchers set modify_requested=false where id=p_id;
  else update vouchers set delete_requested=case when p_mark='delete' then false else delete_requested end,
    modify_requested=case when p_mark='modify' then false else modify_requested end where id=p_id; end if;
  perform log_audit(p_action||' '||p_mark,p_admin,p_id::text); end; $$ language plpgsql security definer;

create function list_vouchers(p_type text, p_include_pending boolean default true) returns table(
  id uuid, voucher_id_code text, voucher_no text, voucher_date date, ledger_name text, total_qty numeric, total_value numeric,
  status text, generated boolean, cancelled boolean, rec_copy boolean, gstr1 boolean, gstr2b boolean,
  approved_mgmt text, approved_acc boolean, delete_requested boolean, modify_requested boolean, created_by text, created_at timestamptz) as $$
  select v.id,v.voucher_id_code,v.voucher_no,v.voucher_date,l.ledger_name,
    coalesce((select sum(qty) from voucher_lines x where x.voucher_id=v.id),0),
    coalesce((select sum(basic_value) from voucher_lines x where x.voucher_id=v.id),0),
    v.status,v.generated,v.cancelled,v.rec_copy,v.gstr1,v.gstr2b,v.approved_mgmt,v.approved_acc,
    v.delete_requested,v.modify_requested,v.created_by,v.created_at
  from vouchers v left join ledger l on l.id=v.ledger_id where v.voucher_type=p_type order by v.created_at desc; $$ language sql;
create function set_doc_flag(p_id uuid, p_field text, p_val boolean, p_user text default null) returns void as $$
declare cur boolean; allowed text; urole text;
begin
  if p_field='cancelled' then
    select cancelled into cur from vouchers where id=p_id;
    if coalesce(cur,false) and not p_val then
      raise exception 'Cancelled cannot be undone.';
    end if;
    if p_val then
      -- only allowed users (admin always; plus app_settings cancel_users comma list)
      select role into urole from app_users where lower(username)=lower(coalesce(p_user,''));
      select value into allowed from app_settings where key='cancel_users';
      if coalesce(urole,'')<>'admin' and not (coalesce(p_user,'') <> '' and
          lower(coalesce(p_user,'')) = any(string_to_array(lower(coalesce(allowed,'')),','))) then
        raise exception 'You are not allowed to cancel vouchers.';
      end if;
      if exists(
        select 1 from vouchers c where coalesce(c.cancelled,false)=false and c.id<>p_id and (
          c.ref_voucher_id=p_id or
          c.ref_no = (select voucher_no from vouchers where id=p_id) or
          exists(select 1 from voucher_lines cl where cl.voucher_id=c.id and cl.ref_no=(select voucher_no from vouchers where id=p_id)))
      ) then
        raise exception 'Cannot cancel: this voucher is linked to other voucher(s). Cancel the dependent voucher first.';
      end if;
      update vouchers set cancelled=true, generated=false where id=p_id;
      return;
    end if;
  end if;
  case p_field
  when 'generated' then update vouchers set generated=p_val where id=p_id and coalesce(cancelled,false)=false;
  when 'cancelled' then update vouchers set cancelled=p_val where id=p_id;
  when 'rec_copy' then update vouchers set rec_copy=p_val where id=p_id;
  when 'grn' then update vouchers set grn=p_val where id=p_id;
  when 'gstr1' then update vouchers set gstr1=p_val where id=p_id;
  when 'gstr2b' then update vouchers set gstr2b=p_val where id=p_id;
  when 'approved_acc' then update vouchers set approved_acc=p_val where id=p_id;
  when 'approved_mgmt' then update vouchers set approved_mgmt=case when p_val then 'APPROVED' else 'PENDING' end where id=p_id;
  else raise exception 'Unknown flag %', p_field; end case; end; $$ language plpgsql security definer;

-- =====================================================================
--  PART LEDGER + BURR (scrap) report + last updated
-- =====================================================================
create function part_ledger(p_part uuid, p_bucket text, p_from date default null, p_to date default null)
returns table(ledger_date date, voucher_type text, voucher_no text, inward numeric, outward numeric, running numeric) as $$
declare opening numeric; begin
  select coalesce(sum(qty),0) into opening from opening_stock where part_id=p_part and bucket=p_bucket; if opening is null then opening:=0; end if;
  return query with moves as (
    select l.ledger_date,l.voucher_type,l.voucher_no,
      case when l.to_bucket=p_bucket then l.qty else 0 end inward, case when l.from_bucket=p_bucket then l.qty else 0 end outward
    from stock_ledger l left join vouchers v on v.id=l.voucher_id
    where l.part_id=p_part and (l.to_bucket=p_bucket or l.from_bucket=p_bucket) and coalesce(v.cancelled,false)=false
      and (p_from is null or l.ledger_date>=p_from) and (p_to is null or l.ledger_date<=p_to)),
  ordered as (select 0 so, null::date ld, 'OPENING'::text vt, ''::text vn, opening inw, 0::numeric outw
    union all select 1, ld.ledger_date, ld.voucher_type, ld.voucher_no, ld.inward, ld.outward from moves ld)
  select o.ld,o.vt,o.vn,o.inw,o.outw, sum(o.inw-o.outw) over (order by o.so,o.ld nulls first rows between unbounded preceding and current row) from ordered o order by o.so,o.ld nulls first;
end; $$ language plpgsql;

create function scrap_report(p_from date, p_to date) returns table(part_code text, part_name text, produced numeric, scrap_wt_pc numeric, total_scrap numeric) as $$
  select p.part_code,p.part_name,coalesce(sum(l.qty),0),p.scrap_weight_pc,coalesce(sum(l.qty),0)*p.scrap_weight_pc
  from part p left join stock_ledger l on l.part_id=p.id and l.voucher_type='PRODUCTION' and l.to_bucket='MG'
    and (p_from is null or l.ledger_date>=p_from) and (p_to is null or l.ledger_date<=p_to)
  where p.status='Active' group by p.id,p.part_code,p.part_name,p.scrap_weight_pc having coalesce(sum(l.qty),0)>0; $$ language sql;

-- =====================================================================
--  PRODUCTION
-- =====================================================================
create sequence if not exists production_code_seq;
create table production_log (
  log_code text default lpad(nextval('production_code_seq')::text, 6, '0'),id uuid primary key default gen_random_uuid(), log_period text, log_date date default current_date,
  shift text, supervisor_1 text not null, supervisor_2 text, created_by text, created_at timestamptz default now());
create table production_rows (
  lot_alloc jsonb,id uuid primary key default gen_random_uuid(), production_id uuid references production_log(id) on delete cascade,
  section text, machine_no text, operator text, part_id uuid references part(id), lot_id uuid references lot_master(id),
  op10_actual numeric default 0, op20_actual numeric default 0, op30_actual numeric default 0,
  setting_time numeric default 0, tool_change_time numeric default 0, breakdown_time numeric default 0, idle_time numeric default 0, remarks text);

create function last_updated_status() returns table(voucher_type text, last_at timestamptz, cnt bigint) as $$
  select voucher_type,max(created_at),count(*) from vouchers where cancelled=false group by voucher_type
  union all
  select 'PRODUCTION', max(created_at), count(*) from production_log; $$ language sql;


create table downtime_log (id uuid primary key default gen_random_uuid(), production_id uuid references production_log(id) on delete cascade,
  log_date date, section text, machine_no text, start_time text, end_time text, duration_min numeric, reason text, action_taken text, created_at timestamptz default now());
create table quality_log (id uuid primary key default gen_random_uuid(), production_id uuid references production_log(id) on delete cascade,
  log_date date, section text, machine_no text, part_id uuid references part(id), qty_rejected numeric, rejection_type text, defect_type text, root_cause text, corrective_action text, created_at timestamptz default now());
create table machine_config (id uuid primary key default gen_random_uuid(), section text not null, machine text not null, operation text, unique(section,machine,operation));

create function post_production(p_date date, p_shift text, p_sup1 text, p_sup2 text, p_user text, p_rows jsonb, p_downtime jsonb, p_quality jsonb, p_location uuid default null)
returns uuid as $$
declare h uuid; r jsonb; pid uuid; lid uuid; op10 numeric; cc numeric; lbal numeric; lot_on boolean;
  la jsonb; la_q numeric; la_tot numeric; begin
  if p_location is null then p_location := default_location(); end if;
  if to_regclass('public.period_lock') is not null and period_is_locked(p_date) then
    raise exception 'PERIOD CLOSED: production date % is in a locked month.', to_char(p_date,'DD Mon YYYY') using errcode='23514';
  end if;
  if p_sup1 is null or length(trim(p_sup1))=0 then raise exception 'Supervisor 1 is required.'; end if;
  select (value='true') into lot_on from app_settings where key='lot_enabled';
  insert into production_log(log_period,log_date,shift,supervisor_1,supervisor_2,created_by) values(to_char(p_date,'Mon YYYY'),p_date,p_shift,p_sup1,p_sup2,p_user) returning id into h;
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    pid:=nullif(r->>'part_id','')::uuid; lid:=nullif(r->>'lot_id','')::uuid; op10:=coalesce((r->>'op10_actual')::numeric,0);
    insert into production_rows(production_id,section,machine_no,operator,part_id,lot_id,op10_actual,op20_actual,op30_actual,setting_time,tool_change_time,breakdown_time,idle_time,remarks,lot_alloc)
    values(h,r->>'section',r->>'machine_no',r->>'operator',pid,lid,op10,coalesce((r->>'op20_actual')::numeric,0),coalesce((r->>'op30_actual')::numeric,0),
      coalesce((r->>'setting_time')::numeric,0),coalesce((r->>'tool_change_time')::numeric,0),coalesce((r->>'breakdown_time')::numeric,0),coalesce((r->>'idle_time')::numeric,0),r->>'remarks',(r->'lot_alloc'));
    if pid is not null and op10>0 then
      cc:=check_stock_loc(pid,p_location,'CC'); if cc<op10 then raise exception 'Production blocked: CC balance % < OP10 % at this location', cc, op10; end if;
      perform post_stock_move(p_date,pid,'CC','MG',op10,h,'PRODUCTION','PRD-'||to_char(p_date,'YYYYMMDD'),'OP10',0,p_location,p_location);
      if lot_on and jsonb_typeof(r->'lot_alloc')='array' and jsonb_array_length(r->'lot_alloc')>0 then
        la_tot:=0;
        for la in select * from jsonb_array_elements(r->'lot_alloc') loop
          lid:=nullif(la->>'lot_id','')::uuid; la_q:=coalesce((la->>'qty')::numeric,0);
          if lid is null or la_q<=0 then continue; end if;
          lbal:=lot_balance(lid,'CC');
          if lbal<la_q then raise exception 'Lot % CC balance % < %', coalesce((select lot_no from lot_master where id=lid),'?'), lbal, la_q; end if;
          insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,'CC','MG',la_q,h,'PRODUCTION','PRD');
          update lot_master set current_bucket='MG' where id=lid;
          la_tot:=la_tot+la_q;
        end loop;
        if la_tot<>op10 then raise exception 'Lot allocation total % must equal OP10 %', la_tot, op10; end if;
      elsif lot_on and lid is not null then lbal:=lot_balance(lid,'CC'); if lbal<op10 then raise exception 'Lot CC balance % < OP10 %', lbal, op10; end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,'CC','MG',op10,h,'PRODUCTION','PRD'); update lot_master set current_bucket='MG' where id=lid; end if;
    end if;
  end loop;
  for r in select * from jsonb_array_elements(coalesce(p_downtime,'[]'::jsonb)) loop
    insert into downtime_log(production_id,log_date,section,machine_no,start_time,end_time,duration_min,reason,action_taken)
    values(h,p_date,r->>'section',r->>'machine_no',r->>'start_time',r->>'end_time',nullif(r->>'duration_min','')::numeric,r->>'reason',r->>'action_taken'); end loop;
  for r in select * from jsonb_array_elements(coalesce(p_quality,'[]'::jsonb)) loop
    insert into quality_log(production_id,log_date,section,machine_no,part_id,qty_rejected,rejection_type,defect_type,root_cause,corrective_action)
    values(h,p_date,r->>'section',r->>'machine_no',nullif(r->>'part_id','')::uuid,nullif(r->>'qty_rejected','')::numeric,r->>'rejection_type',r->>'defect_type',r->>'root_cause',r->>'corrective_action'); end loop;
  perform log_audit('POST PRODUCTION',p_user,h::text); return h;
end; $$ language plpgsql security definer;

-- admin user crud + mappings + opening + prices
create function admin_list_users() returns table(id uuid, username text, role text, access_modules text, weight_check boolean, valid_thru_edit boolean, active boolean, last_login timestamptz) as $$
  select id,username,role,access_modules,weight_check,valid_thru_edit,coalesce(active,true),last_login from app_users order by username; $$ language sql security definer;
create function admin_save_user(p_id uuid, p_username text, p_password text, p_role text, p_access text, p_weight boolean, p_valid_edit boolean, p_active boolean default true) returns uuid as $$
declare uid uuid; begin
  if p_id is null then insert into app_users(username,password,role,access_modules,weight_check,valid_thru_edit,active) values(p_username,crypt(coalesce(p_password,'changeme'),gen_salt('bf')),p_role,p_access,p_weight,p_valid_edit,coalesce(p_active,true)) returning id into uid;
  else update app_users set username=p_username,role=p_role,access_modules=p_access,weight_check=p_weight,valid_thru_edit=p_valid_edit,active=coalesce(p_active,true), password=case when p_password is null or p_password='' then password else crypt(p_password,gen_salt('bf')) end where id=p_id returning id into uid; end if;
  return uid; end; $$ language plpgsql security definer;
create function admin_delete_user(p_id uuid) returns void as $$ delete from app_users where id=p_id and username<>'admin'; $$ language sql security definer;

-- per-module action rights
create function get_module_rights(p_user uuid) returns table(module text, can_view boolean, can_create boolean, can_approve boolean, can_edit boolean, can_markdel boolean, can_markedit boolean) as $$
  select module,can_view,can_create,can_approve,can_edit,can_markdel,can_markedit from user_module_rights where user_id=p_user; $$ language sql security definer;
create function set_module_right(p_user uuid, p_module text, p_view boolean, p_create boolean, p_approve boolean, p_edit boolean default false, p_markdel boolean default false, p_markedit boolean default false) returns void as $$
  insert into user_module_rights(user_id,module,can_view,can_create,can_approve,can_edit,can_markdel,can_markedit)
  values(p_user,p_module,p_view,p_create,p_approve,p_edit,p_markdel,p_markedit)
  on conflict(user_id,module) do update set can_view=excluded.can_view,can_create=excluded.can_create,can_approve=excluded.can_approve,can_edit=excluded.can_edit,can_markdel=excluded.can_markdel,can_markedit=excluded.can_markedit;
$$ language sql security definer;
create function admin_save_opening(p_rows jsonb) returns int as $$
declare r jsonb; n int:=0; lid uuid; begin for r in select * from jsonb_array_elements(p_rows) loop
  lid := coalesce(nullif(r->>'location_id','')::uuid, default_location());
  insert into opening_stock(part_id,location_id,bucket,qty) values((r->>'part_id')::uuid,lid,r->>'bucket',coalesce((r->>'qty')::numeric,0))
    on conflict(part_id,location_id,bucket) do update set qty=excluded.qty;
  perform recache_cell((r->>'part_id')::uuid,lid,r->>'bucket');
  n:=n+1; end loop; return n; end; $$ language plpgsql security definer;

-- RLS
do $$ declare t text; begin
  foreach t in array array['app_users','app_settings','buckets','ledger','part','part_price','opening_stock','stock_variance','physical_stock','stock_ledger','lot_master','lot_ledger','vouchers','voucher_lines','audit_log','production_log','production_rows','downtime_log','quality_log','machine_config'] loop
    execute format('alter table %I enable row level security;',t);
    execute format('drop policy if exists pol_%s on %I;',t,t);
    if t<>'app_users' then execute format('create policy pol_%s on %I for all using (true) with check (true);',t,t); end if;
  end loop; end $$;

-- ---- load one voucher with its lines (for the edit form) ----
create or replace function get_voucher(p_id uuid)
returns jsonb as $$
  select jsonb_build_object(
    'header', (select to_jsonb(v) from vouchers v where v.id=p_id),
    'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.sno) from voucher_lines l where l.voucher_id=p_id),'[]'::jsonb)
  );
$$ language sql security definer;


-- ---- ADMIN: erase all transaction + master data (keeps users, rights, settings, config) ----
create or replace function admin_erase_data(p_user text, p_confirm text) returns text as $$
declare urole text;
begin
  select role into urole from app_users where lower(username)=lower(coalesce(p_user,''));
  if coalesce(urole,'') <> 'admin' then
    raise exception 'Only an admin may erase data.';
  end if;
  if p_confirm <> 'ERASE ALL DATA' then
    raise exception 'Confirmation phrase mismatch. Type exactly: ERASE ALL DATA';
  end if;

  -- transactional + derived data
  truncate table
    audit_log, downtime_log, quality_log, production_rows, production_log,
    lot_ledger, lot_master, stock_variance, physical_stock, period_opening,
    period_lock, opening_stock, stock_cache, stock_ledger, voucher_lines, vouchers
  restart identity cascade;

  -- master data
  truncate table part_price, part, part_group, ledger, supervisor, machine_config, defect_type
  restart identity cascade;

  -- KEEP (untouched): app_users, user_module_rights, app_settings, ui_column_config,
  --   voucher_enabled, checkbox_perms, buckets, bucket_map, location, location_bucket

  return 'Erased: transactions + masters. Users, rights, settings and configuration kept. Cache cleared.';
end; $$ language plpgsql security definer;

-- ---- reverse a voucher's stock + lot moves (used by edit/cancel) ----
create or replace function reverse_voucher_stock(p_id uuid) returns void as $$
begin
  perform purge_voucher_moves(p_id);   -- sealed/immutable-safe removal + recache
  -- drop any lots that were *created* by this voucher (purchase) and now have no ledger rows
  delete from lot_master m where m.ref_voucher=(select voucher_no from vouchers where id=p_id)
    and not exists (select 1 from lot_ledger ll where ll.lot_id=m.id);
end; $$ language plpgsql security definer;

-- ---- edit: permission + window check, then reverse old & repost new lines ----
create or replace function edit_voucher(
  p_id uuid, p_no text, p_date date, p_posting date, p_valid date, p_ledger uuid,
  p_ref_no text, p_tax numeric, p_narration text, p_user text, p_role text, p_lines jsonb, p_location uuid default null, p_vehicle text default null, p_slip numeric default null
) returns jsonb as $$
declare vt text; created timestamptz; age interval; from_b text; to_b text; ln jsonb; i int:=0;
  is_variant boolean:=false; vdir text; src text; lqty numeric; move_date date; on_hand numeric;
  lot_on boolean; lid uuid; lbal numeric; new_lot text; valid_edit boolean;
  la jsonb; la_q numeric; la_tot numeric;
begin
  if p_location is null then p_location := default_location(); end if;
  -- no voucher number given -> use the voucher ID code as the number
  p_no := coalesce(nullif(trim(p_no),''), (select voucher_id_code from vouchers where id=p_id));
  select voucher_type, created_at into vt, created from vouchers where id=p_id;
  if vt is null then return jsonb_build_object('ok',false,'msg','Voucher not found'); end if;
  age := now()-created;
  if p_role not in ('admin','can_edit') then return jsonb_build_object('ok',false,'msg','No permission to edit'); end if;
  if p_role<>'admin' and age>interval '8 hours' then return jsonb_build_object('ok',false,'msg','8-hour edit window has passed'); end if;
  select (value='true') into lot_on from app_settings where key='lot_enabled';

  -- 1) reverse existing stock effects + remove old lines
  perform reverse_voucher_stock(p_id);
  delete from voucher_lines where voucher_id=p_id;

  -- 2) update header
  update vouchers set voucher_no=p_no, voucher_date=p_date, posting_date=p_posting, valid_thru=p_valid,
    ledger_id=p_ledger, ref_no=p_ref_no, tax_rate=coalesce(p_tax,18), narration=p_narration,
    voucher_period=to_char(p_date,'Mon YYYY'), vehicle_no=nullif(trim(coalesce(p_vehicle, vehicle_no, '')),''), scrap_slip_wt=coalesce(p_slip, scrap_slip_wt) where id=p_id;

  -- 3) recompute bucket map (same as post_voucher)
  case vt
    when 'PURCHASE' then from_b:='VENDOR'; to_b:='RC';
    when 'DEBIT_NOTE_RC' then from_b:='RC'; to_b:='VENDOR';
    when 'DC_OUT_JW' then from_b:='RC'; to_b:='RCJW';
    when 'RC_IN_JW' then from_b:='RCJW'; to_b:='CC';
    when 'SALES_LOCAL' then from_b:='MG'; to_b:='CUSTOMER';
    when 'RESALE' then from_b:='MG'; to_b:='CUSTOMER';
    when 'CREDIT_NOTE' then from_b:='CUSTOMER'; to_b:=null;  -- per-line disposition
    when 'PROCESS_REJECTION' then from_b:='MG'; to_b:='PR';
    when 'MATERIAL_REJECTION' then from_b:='MG'; to_b:='MR';
    when 'SCRAP_SALES' then from_b:='PR'; to_b:='CUSTOMER';
    when 'DEBIT_NOTE_DN' then from_b:='MR'; to_b:='VENDOR';
    else from_b:=null; to_b:=null; end case;
  if vt in ('DC_OUT_RET','DC_OUT_REPLACE','DC_OUT_NONRET') then is_variant:=true; vdir:='OUT';
  elsif vt in ('RC_IN_RET','RC_IN_REPLACE') then is_variant:=true; vdir:='IN'; end if;

  move_date:=coalesce(p_posting,p_date);
  for ln in select * from jsonb_array_elements(p_lines) loop
    i:=i+1; lqty:=coalesce((ln->>'qty')::numeric,0); src:=nullif(ln->>'source_bucket','');
    insert into voucher_lines(voucher_id,sno,part_id,lot_id,ref_no,source_bucket,qty,invoice_qty,actual_qty,uom,unit_price,po_price,basic_value,weight,defect_type,root_cause,line_note,disposition,return_bucket,packages,pkg_count,lot_alloc)
    values(p_id,i,(ln->>'part_id')::uuid,nullif(ln->>'lot_id','')::uuid,ln->>'ref_no',src,lqty,
      coalesce((ln->>'invoice_qty')::numeric,0),coalesce((ln->>'actual_qty')::numeric,0),coalesce(ln->>'uom','Nos'),
      coalesce((ln->>'unit_price')::numeric,0),coalesce((ln->>'po_price')::numeric,0),coalesce((ln->>'basic_value')::numeric,0),
      coalesce((ln->>'weight')::numeric,0),ln->>'defect_type',ln->>'root_cause',ln->>'line_note',
      nullif(ln->>'disposition',''),nullif(ln->>'return_bucket',''),(ln->'packages'),coalesce((ln->>'pkg_count')::numeric,0),(ln->'lot_alloc'));

    if vt='CREDIT_NOTE' then
      case coalesce(ln->>'disposition','RESALE')
        when 'PROCESS' then to_b:='PR'; when 'MATERIAL' then to_b:='MR'; else to_b:='MG'; end case;
    end if;

    if is_variant then
      if src is null then raise exception 'Source bucket required for %', vt; end if;
      if vdir='OUT' then
        if vt='DC_OUT_NONRET' then from_b:=src; to_b:='DCNOUT';
        else from_b:=src; to_b:='JOBOUT'; end if;
      else
        from_b:='JOBOUT';
        if vt='RC_IN_REPLACE' then to_b:=coalesce(nullif(ln->>'return_bucket',''),src);
        else to_b:=src; end if;
      end if;
    end if;

    if from_b is not null then
      if from_b not in ('VENDOR','CUSTOMER') then
        on_hand:=check_stock((ln->>'part_id')::uuid,from_b);
        if on_hand<lqty then raise exception '% edit blocked: % balance %, requested %', vt, from_b, on_hand, lqty; end if;
      end if;
      perform post_stock_move(move_date,(ln->>'part_id')::uuid,from_b,to_b,lqty,p_id,vt,p_no,p_narration,
        case when vt='SALES_LOCAL' then 250 else 0 end, p_location, p_location);
      if vt='PURCHASE' and lqty>0 and lot_on then
        new_lot:=next_lot_no((ln->>'part_id')::uuid,p_ledger);
        insert into lot_master(lot_no,part_id,ledger_id,current_bucket,original_qty,ref_voucher) values(new_lot,(ln->>'part_id')::uuid,p_ledger,'RC',lqty,p_no) returning id into lid;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,'VENDOR','RC',lqty,p_id,vt,p_no);
      elsif lot_on and jsonb_typeof(ln->'lot_alloc')='array' and jsonb_array_length(ln->'lot_alloc')>0 then
        la_tot:=0;
        for la in select * from jsonb_array_elements(ln->'lot_alloc') loop
          lid:=nullif(la->>'lot_id','')::uuid; la_q:=coalesce((la->>'qty')::numeric,0);
          if lid is null or la_q<=0 then continue; end if;
          lbal:=lot_balance(lid,from_b);
          if lbal<la_q then raise exception 'Lot % insufficient in %: have %, need %',
            coalesce((select lot_no from lot_master where id=lid),'?'), from_b, lbal, la_q; end if;
          insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,from_b,to_b,la_q,p_id,vt,p_no);
          update lot_master set current_bucket=to_b where id=lid;
          la_tot:=la_tot+la_q;
        end loop;
        if la_tot<>lqty then raise exception 'Lot allocation total % must equal line qty %', la_tot, lqty; end if;
      elsif lot_on and nullif(ln->>'lot_id','') is not null then
        lid:=(ln->>'lot_id')::uuid; lbal:=lot_balance(lid,from_b);
        if lbal<lqty then raise exception 'Lot insufficient in %: have %, need %', from_b, lbal, lqty; end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,from_b,to_b,lqty,p_id,vt,p_no);
        update lot_master set current_bucket=to_b where id=lid;
      end if;
    end if;
  end loop;

  update vouchers set modify_requested=false where id=p_id;
  perform log_audit('EDIT '||vt, p_user, p_no);
  return jsonb_build_object('ok',true,'msg','Voucher updated');
end; $$ language plpgsql security definer;

-- ---- GST format validation: NN AAAAA NNNN A N (A/N) ----
create or replace function valid_gst(p_gst text) returns boolean as $$
  select p_gst is null or p_gst='' or p_gst ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}[Z]{1}[0-9A-Z]{1}$';
$$ language sql;
-- enforce on ledger writes
create or replace function ledger_gst_check() returns trigger as $$
begin if not valid_gst(new.gst_no) then raise exception 'GST No format invalid (expected 22AAAAA0000A1Z5 style).'; end if; return new; end; $$ language plpgsql;
drop trigger if exists trg_ledger_gst on ledger;
create trigger trg_ledger_gst before insert or update on ledger for each row execute function ledger_gst_check();

-- ---- per-user checkbox permissions ----
create table if not exists checkbox_perms (
  user_id uuid references app_users(id) on delete cascade,
  flag text, allowed boolean default true, primary key(user_id,flag));
create or replace function get_checkbox_perms(p_user uuid) returns table(flag text, allowed boolean) as $$
  select flag, allowed from checkbox_perms where user_id=p_user; $$ language sql security definer;
create or replace function set_checkbox_perm(p_user uuid, p_flag text, p_allowed boolean) returns void as $$
  insert into checkbox_perms(user_id,flag,allowed) values(p_user,p_flag,p_allowed)
  on conflict(user_id,flag) do update set allowed=excluded.allowed; $$ language sql security definer;
alter table checkbox_perms enable row level security;
drop policy if exists pol_checkbox_perms on checkbox_perms;
create policy pol_checkbox_perms on checkbox_perms for all using(true) with check(true);
-- =====================================================================

-- ---- Part Groups (tabs in Production Log) ----
create table if not exists part_group (
  id uuid primary key default gen_random_uuid(),
  group_name text unique not null,
  sort_order int default 0,
  created_at timestamptz default now()
);
create or replace function list_part_groups() returns table(id uuid, group_name text, sort_order int) as $$
  select id, group_name, sort_order from part_group order by sort_order, group_name; $$ language sql;
create or replace function create_part_group(p_name text) returns uuid as $$
declare i uuid; begin
  insert into part_group(group_name) values(p_name) on conflict(group_name) do nothing;
  select id into i from part_group where group_name=p_name; return i; end; $$ language plpgsql security definer;

-- ---- Part master: add part_group ----
alter table part add column if not exists part_group_id uuid references part_group(id);

-- ---- Machine Config: redefine as full Production layout ----
--  (part_group -> machine -> operation, with ordering)
drop table if exists machine_config cascade;
create table machine_config (
  id uuid primary key default gen_random_uuid(),
  part_group_id uuid references part_group(id) on delete cascade,
  machine text not null,         -- e.g. VMC 10
  operation text,                -- optional label
  sort_order int default 0,
  created_at timestamptz default now()
);
alter table machine_config enable row level security;
drop policy if exists pol_machine_config on machine_config;
create policy pol_machine_config on machine_config for all using(true) with check(true);

-- read the full production layout: tabs + machines per tab
create or replace function production_layout() returns table(
  group_id uuid, group_name text, group_sort int,
  machine_id uuid, machine text, operation text, machine_sort int) as $$
  select g.id, g.group_name, g.sort_order,
         m.id, m.machine, m.operation, coalesce(m.sort_order,0)
  from part_group g
  left join machine_config m on m.part_group_id=g.id
  order by g.sort_order, g.group_name, coalesce(m.sort_order,0), m.machine; $$ language sql;

-- machine config CRUD helpers
-- mc_save is defined in SPEC PACK 2 (8-arg version with op10/20/30 flags)
create or replace function mc_delete(p_id uuid) returns void as $$ delete from machine_config where id=p_id; $$ language sql security definer;

-- ---- Undo transactions: cancel a voucher and reverse its stock ----
create or replace function undo_voucher(p_id uuid, p_user text, p_role text) returns jsonb as $$
declare vt text; vn text; begin
  if p_role <> 'admin' then return jsonb_build_object('ok',false,'msg','Only admin can undo transactions'); end if;
  select voucher_type, voucher_no into vt, vn from vouchers where id=p_id;
  if vt is null then return jsonb_build_object('ok',false,'msg','Voucher not found'); end if;
  perform reverse_voucher_stock(p_id);
  update vouchers set cancelled=true, status='CANCELLED' where id=p_id;
  perform log_audit('UNDO '||vt, p_user, vn);
  return jsonb_build_object('ok',true,'msg','Transaction '||vn||' undone (cancelled & stock reversed)');
end; $$ language plpgsql security definer;

-- recent transactions for the Undo screen
create or replace function recent_transactions(p_limit int default 100) returns table(
  id uuid, voucher_type text, voucher_id_code text, voucher_no text, voucher_date date,
  ledger_name text, parts text, total_qty numeric, total_value numeric, cancelled boolean, created_by text, created_at timestamptz) as $$
  select v.id, v.voucher_type, v.voucher_id_code, v.voucher_no, v.voucher_date, l.ledger_name,
    (select string_agg(distinct p.part_code||' · '||p.part_name, ', ')
       from voucher_lines x left join part p on p.id=x.part_id where x.voucher_id=v.id),
    coalesce((select sum(coalesce(nullif(x.actual_qty,0),x.qty)) from voucher_lines x where x.voucher_id=v.id),0),
    coalesce((select sum(basic_value) from voucher_lines x where x.voucher_id=v.id),0), v.cancelled, v.created_by, v.created_at
  from vouchers v left join ledger l on l.id=v.ledger_id
  order by v.created_at desc limit p_limit; $$ language sql;

-- Open PO / DC / SO summary for the Books page banner
create or replace function open_documents() returns table(
  doc text, voucher_no text, voucher_date date, due_date date, ledger_name text, part_code text,
  order_qty numeric, received numeric, pending numeric, completion_pct numeric) as $$
  select 'PO', o.voucher_no, o.voucher_date, o.valid_thru, l.ledger_name, p.part_code,
         o.order_qty, o.fulfilled_qty, o.pending_qty,
         round(100.0*o.fulfilled_qty/nullif(o.order_qty,0),1)
    from open_orders o left join ledger l on l.id=o.ledger_id left join part p on p.id=o.part_id where o.voucher_type='PURCHASE_ORDER'
  union all
  select 'SO', o.voucher_no, o.voucher_date, o.valid_thru, l.ledger_name, p.part_code,
         o.order_qty, o.fulfilled_qty, o.pending_qty,
         round(100.0*o.fulfilled_qty/nullif(o.order_qty,0),1)
    from open_orders o left join ledger l on l.id=o.ledger_id left join part p on p.id=o.part_id where o.voucher_type='SALES_ORDER'
  union all
  select 'DC', d.voucher_no, d.voucher_date, d.due_date, l.ledger_name, p.part_code,
         d.dc_qty, d.received_qty, d.pending_qty,
         round(100.0*d.received_qty/nullif(d.dc_qty,0),1)
    from open_dcs d left join ledger l on l.id=d.ledger_id left join part p on p.id=d.part_id; $$ language sql;

-- Opening stock editable grid read (reuse get_recon_grid shape but with stored opening)
create or replace function opening_grid() returns table(part_id uuid, part_code text, part_name text, bucket text, qty numeric) as $$
  select p.id, p.part_code, p.part_name, b.code, coalesce((select sum(qty) from opening_stock o where o.part_id=p.id and o.bucket=b.code),0)
  from part p cross join buckets b where p.status='Active' and b.is_external=false order by p.part_code, b.code; $$ language sql;


-- =====================================================================
--  STOCK ENGINE HARDENING — "the vault"
--  Run at the END of schema_v14.sql (it is appended there).
--  Layers 7 guarantees on top of the stock engine so the bucket logic
--  cannot be corrupted by app bugs, manual edits, or concurrency.
--
--  G1 Balanced-pair integrity (column constraints)
--  G2 Sealed ledger: only post_stock_move() may write stock_ledger
--  G3 Atomic no-negative with row-level lock
--  G4 Immutable history: no UPDATE/DELETE on posted movements
--  G5 Derived balance + self-rebuilding cache + reconciliation auditor
--  G6 All-or-nothing (transaction-scoped; posting fns already atomic)
--  G7 Single source of truth for the bucket map
-- =====================================================================

-- ---------------------------------------------------------------------
-- G7. ONE bucket map. Every module's from/to lives here, nowhere else.
-- ---------------------------------------------------------------------
create table if not exists bucket_map (
  voucher_type text primary key,
  from_bucket  text,           -- null = resolved per-line (variants / disposition)
  to_bucket    text,           -- null = resolved per-line
  note         text
);
delete from bucket_map;
insert into bucket_map(voucher_type,from_bucket,to_bucket,note) values
 ('PURCHASE','VENDOR','RC','+RC -PO'),
 ('RESALE','MG','CUSTOMER','-MG (resale, no SO)'),
 ('DEBIT_NOTE_RC','RC','VENDOR','-RC'),
 ('DC_OUT_JW','RC','RCJW','-RC +RCJW'),
 ('RC_IN_JW','RCJW','CC','-RCJW +CC'),
 ('PRODUCTION','CC','MG','-CC +MG'),
 ('SALES_LOCAL','MG','CUSTOMER','-MG -SO'),
 ('CREDIT_NOTE','CUSTOMER',null,'sales return: per-line disposition -> PR/MR/MG'),
 ('PROCESS_REJECTION','MG','PR','-MG +PR'),
 ('SCRAP_SALES','PR','CUSTOMER','-PR'),
 ('MATERIAL_REJECTION','MG','MR','-MG +MR'),
 ('DEBIT_NOTE_DN','MR','VENDOR','-MR'),
 ('DC_OUT_RET',null,'JOBOUT','source -> JOBOUT (returnable)'),
 ('DC_OUT_REPLACE',null,'JOBOUT','source -> JOBOUT (replacement)'),
 ('DC_OUT_NONRET',null,'DCNOUT','source -> out (permanent subtract)'),
 ('RC_IN_RET','JOBOUT',null,'JOBOUT -> source (returnable)'),
 ('RC_IN_REPLACE','JOBOUT',null,'JOBOUT -> user-picked bucket (replacement)');

-- ---------------------------------------------------------------------
-- G1. Balanced-pair integrity. A movement must be well-formed.
--     (Drop first so re-runs are clean.)
-- ---------------------------------------------------------------------
alter table stock_ledger drop constraint if exists chk_qty_positive;
alter table stock_ledger drop constraint if exists chk_from_ne_to;
alter table stock_ledger add constraint chk_qty_positive check (qty > 0);
-- the (location,bucket) pair must differ between source and destination.
-- Same bucket is allowed when locations differ (a Stock Transfer); same
-- location is allowed only when buckets differ (a normal in-place move).
alter table stock_ledger add constraint chk_from_ne_to
  check (from_bucket is distinct from to_bucket or from_location is distinct from to_location);
-- both buckets must exist (FK already present on from/to via buckets table)

-- ---------------------------------------------------------------------
-- G5a. Balance CACHE table, rebuilt by the DB from the ledger.
--      Never hand-set. Truth remains the ledger; this is a fast mirror.
-- ---------------------------------------------------------------------
create table if not exists stock_cache (
  part_id uuid, location_id uuid, bucket text, grs numeric not null default 0,
  var_qty numeric not null default 0, bal numeric not null default 0,
  updated_at timestamptz default now(), primary key(part_id,location_id,bucket));

-- recompute one (part,location,bucket) cache cell straight from source views
create or replace function recache_cell(p_part uuid, p_loc uuid, p_bucket text) returns void as $$
declare g numeric; v numeric; begin
  select grs into g from stock_grs where part_id=p_part and location_id=p_loc and bucket=p_bucket;
  select var_qty into v from stock_var where part_id=p_part and location_id=p_loc and bucket=p_bucket;
  g:=coalesce(g,0); v:=coalesce(v,0);
  insert into stock_cache(part_id,location_id,bucket,grs,var_qty,bal,updated_at)
  values(p_part,p_loc,p_bucket,g,v,g+v,now())
  on conflict(part_id,location_id,bucket) do update set grs=excluded.grs,var_qty=excluded.var_qty,bal=excluded.bal,updated_at=now();
end; $$ language plpgsql;

-- full rebuild (used on install and by the auditor's repair)
create or replace function recache_all() returns void as $$
  select recache_cell(part_id,location_id,bucket) from stock_grs; select null::void;
$$ language sql;

-- ---------------------------------------------------------------------
-- G3 + G2 helper. THE ONLY sanctioned writer of stock_ledger.
--   - takes a row-level lock on the (part,bucket) cache cell
--   - re-derives current balance under the lock
--   - blocks if the move would drive an INTERNAL source below zero
--   - writes the movement, then refreshes the two affected cache cells
--   A session GUC (app.stock_gate) is set TRUE only inside this function,
--   and the ledger trigger (G2) refuses any write made without it.
-- ---------------------------------------------------------------------
create or replace function post_stock_move(
  p_date date, p_part uuid, p_from text, p_to text, p_qty numeric,
  p_voucher uuid, p_vtype text, p_vno text, p_note text, p_allow_negative numeric default 0,
  p_from_loc uuid default null, p_to_loc uuid default null
) returns uuid as $$
declare avail numeric; rid uuid; from_internal boolean; to_internal boolean; dft uuid;
begin
  if p_qty is null or p_qty <= 0 then raise exception 'stock move qty must be > 0 (got %)', p_qty; end if;
  if p_from is distinct from p_to or p_from_loc is distinct from p_to_loc then null;
  else raise exception 'from and to (location,bucket) cannot be identical (%/%).', p_from, p_from_loc; end if;

  -- PERIOD LOCK: refuse any movement dated into a closed month
  if to_regclass('public.period_lock') is not null and period_is_locked(p_date) then
    raise exception 'PERIOD CLOSED: % falls in a locked month; movement refused.', p_date using errcode='23514';
  end if;

  select not is_external into from_internal from buckets where code=p_from;
  select not is_external into to_internal   from buckets where code=p_to;
  if from_internal is null then raise exception 'unknown from_bucket %', p_from; end if;
  if to_internal   is null then raise exception 'unknown to_bucket %', p_to; end if;

  -- default any missing location to the default store (back-compat / external moves)
  dft := default_location();
  if from_internal and p_from_loc is null then p_from_loc := dft; end if;
  if to_internal   and p_to_loc   is null then p_to_loc   := dft; end if;

  -- ALLOW-LIST: bucket must be permitted at its location (internal only)
  if from_internal and not bucket_allowed(p_from_loc, p_from) then
    raise exception 'BUCKET NOT ALLOWED: % is not enabled at the source location.', p_from using errcode='23514';
  end if;
  if to_internal and not bucket_allowed(p_to_loc, p_to) then
    raise exception 'BUCKET NOT ALLOWED: % is not enabled at the destination location.', p_to using errcode='23514';
  end if;

  -- G3: lock the source (part,location,bucket) cache cell so concurrent posts serialise
  if from_internal then
    perform 1 from stock_cache where part_id=p_part and location_id=p_from_loc and bucket=p_from for update;
    if not found then perform recache_cell(p_part,p_from_loc,p_from); perform 1 from stock_cache where part_id=p_part and location_id=p_from_loc and bucket=p_from for update; end if;
    avail := check_stock_loc(p_part,p_from_loc,p_from);
    if avail + coalesce(p_allow_negative,0) < p_qty then
      raise exception 'INSUFFICIENT STOCK: part % in % @loc, need %, have % (allowance %)', p_part, p_from, p_qty, avail, coalesce(p_allow_negative,0)
        using errcode='23514';
    end if;
  end if;

  -- G2: open the gate for this one insert, then close it
  perform set_config('app.stock_gate','on',true);
  insert into stock_ledger(ledger_date,part_id,from_location,to_location,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
  values(p_date,p_part,case when from_internal then p_from_loc end,case when to_internal then p_to_loc end,p_from,p_to,p_qty,p_voucher,p_vtype,p_vno,p_note) returning id into rid;
  perform set_config('app.stock_gate','off',true);

  -- G5: refresh both affected (part,location,bucket) cache cells
  if from_internal then perform recache_cell(p_part,p_from_loc,p_from); end if;
  if to_internal   then perform recache_cell(p_part,p_to_loc,p_to);   end if;
  return rid;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- G2. SEAL the ledger. Any INSERT not flagged by the gate is refused.
--     UPDATE/DELETE on posted rows is refused outright (G4 immutability),
--     EXCEPT a controlled cancel path that sets app.stock_uncage.
-- ---------------------------------------------------------------------
create or replace function ledger_guard() returns trigger as $$
begin
  if tg_op='INSERT' then
    if current_setting('app.stock_gate', true) is distinct from 'on' then
      raise exception 'stock_ledger is sealed: write only via post_stock_move()' using errcode='42501';
    end if;
    return new;
  end if;
  -- UPDATE / DELETE
  if current_setting('app.stock_uncage', true) = 'on' then return coalesce(new,old); end if;
  raise exception 'stock_ledger is immutable: posted movements cannot be % (use a reversing entry)', tg_op using errcode='42501';
end; $$ language plpgsql;

drop trigger if exists trg_ledger_guard on stock_ledger;
create trigger trg_ledger_guard before insert or update or delete on stock_ledger
  for each row execute function ledger_guard();

-- controlled removal of a voucher's movements (for cancel/undo & edit-repost).
-- Opens the uncage flag, deletes, recaches touched cells, closes the flag.
create or replace function purge_voucher_moves(p_voucher uuid) returns void as $$
declare r record;
begin
  perform set_config('app.stock_uncage','on',true);
  drop table if exists _touched;
  create temp table _touched(part_id uuid, location_id uuid, bucket text);
  insert into _touched select distinct part_id, from_location, from_bucket from stock_ledger where voucher_id=p_voucher and from_bucket is not null and from_location is not null
    union select distinct part_id, to_location, to_bucket from stock_ledger where voucher_id=p_voucher and to_bucket is not null and to_location is not null;
  delete from stock_ledger where voucher_id=p_voucher;
  delete from lot_ledger where voucher_id=p_voucher;
  perform set_config('app.stock_uncage','off',true);
  for r in select part_id,location_id,bucket from _touched loop perform recache_cell(r.part_id,r.location_id,r.bucket); end loop;
  drop table if exists _touched;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- G5b. RECONCILIATION AUDITOR. Re-derives every balance from the ledger
--      and compares to the cache. Any row returned = drift = a bug.
--      In practice always empty (app never writes the cache).
-- ---------------------------------------------------------------------
create or replace function reconcile_stock() returns table(
  part_id uuid, part_code text, location_id uuid, bucket text, ledger_bal numeric, cache_bal numeric, drift numeric) as $$
  select g.part_id, p.part_code, g.location_id, g.bucket,
         (g.grs + coalesce(v.var_qty,0)) ledger_bal,
         coalesce(c.bal,0) cache_bal,
         (g.grs + coalesce(v.var_qty,0)) - coalesce(c.bal,0) drift
  from stock_grs g
  join part p on p.id=g.part_id
  left join stock_var v on v.part_id=g.part_id and v.location_id=g.location_id and v.bucket=g.bucket
  left join stock_cache c on c.part_id=g.part_id and c.location_id=g.location_id and c.bucket=g.bucket
  where abs((g.grs + coalesce(v.var_qty,0)) - coalesce(c.bal,0)) > 0.0001;
$$ language sql security definer;

-- negative-balance auditor (should also always be empty), per location
create or replace function audit_negatives() returns table(part_code text, location_id uuid, bucket text, bal numeric) as $$
  select p.part_code, s.location_id, s.bucket, s.grs+coalesce(v.var_qty,0)
  from stock_grs s join part p on p.id=s.part_id
  left join stock_var v on v.part_id=s.part_id and v.location_id=s.location_id and v.bucket=s.bucket
  where s.grs+coalesce(v.var_qty,0) < 0;
$$ language sql security definer;

-- one-call health check for an admin screen
create or replace function engine_health() returns table(check_name text, status text, detail text) as $$
  select 'cache_drift',
    case when exists(select 1 from reconcile_stock()) then 'FAIL' else 'OK' end,
    coalesce((select count(*)::text||' cell(s) drifted' from reconcile_stock()),'0')
  union all
  select 'negative_balances',
    case when exists(select 1 from audit_negatives()) then 'FAIL' else 'OK' end,
    coalesce((select count(*)::text||' negative cell(s)' from audit_negatives()),'0');
$$ language sql security definer;

-- build the cache now so reads are instant from first use
select recache_all();


-- =====================================================================
--  FEATURE PACK (appended after hardening). Per-vendor weights,
--  voucher enable/disable, ledger/part admin edit+delete, dashboard
--  metrics, editable validity pricing helpers, column-config store.
-- =====================================================================

-- ---- 8. Per-vendor weights live on part_price (purchase rows) ----
alter table part_price add column if not exists input_weight_pc numeric default 0;
alter table part_price add column if not exists output_weight_pc numeric default 0;
alter table part_price add column if not exists scrap_weight_pc numeric default 0;
alter table part_price add column if not exists allowance_pct numeric default 0;
alter table part_price add column if not exists qty_variation numeric default 0;

-- get the weight profile for a part+vendor valid on a date (for package validation)
create or replace function get_weight_profile(p_part uuid, p_ledger uuid, p_date date)
returns table(input_weight_pc numeric, allowance_pct numeric, qty_variation numeric) as $$
  select coalesce(input_weight_pc,0), coalesce(allowance_pct,0), coalesce(qty_variation,0)
  from part_price where part_id=p_part and ledger_id=p_ledger and price_type='purchase'
    and (valid_from is null or valid_from<=p_date) and (valid_upto is null or valid_upto>=p_date)
  order by valid_from desc nulls last limit 1;
$$ language sql;

-- ---- 9. Validity-enforced price lookup with voucher-type mapping ----
-- DC variants = sale price; DN = purchase; CN = sale; Purchase = purchase; Sales = sale
create or replace function price_for_voucher(p_part uuid, p_ledger uuid, p_vtype text, p_date date)
returns numeric as $$
declare t text; begin
  t := case
    when p_vtype in ('PURCHASE','PURCHASE_ORDER','DEBIT_NOTE_RC','DEBIT_NOTE_DN') then 'purchase'
    when p_vtype in ('SALES_LOCAL','SALES_ORDER','CREDIT_NOTE','SCRAP_SALES',
                     'DC_OUT_JW','DC_OUT_RET','DC_OUT_REPLACE','DC_OUT_NONRET','RC_IN_JW','RC_IN_RET','RC_IN_REPLACE') then 'sale'
    else 'sale' end;
  return get_price(p_part, p_ledger, t, p_date);
end; $$ language plpgsql;

-- ---- 4. Voucher enable/disable (settings) ----
create table if not exists voucher_enabled (voucher_type text primary key, enabled boolean default true);
create or replace function set_voucher_enabled(p_type text, p_on boolean) returns void as $$
  insert into voucher_enabled(voucher_type,enabled) values(p_type,p_on)
  on conflict(voucher_type) do update set enabled=excluded.enabled; $$ language sql security definer;
create or replace function list_voucher_enabled() returns table(voucher_type text, enabled boolean) as $$
  select ve.voucher_type, ve.enabled from voucher_enabled ve; $$ language sql;
-- block posting of a disabled voucher type at the engine level
create or replace function assert_voucher_enabled(p_type text) returns void as $$
declare on_flag boolean; begin
  select enabled into on_flag from voucher_enabled where voucher_type=p_type;
  if on_flag is not null and on_flag=false then
    raise exception 'Voucher type % is disabled in Settings.', p_type using errcode='42501';
  end if;
end; $$ language plpgsql;

-- ---- 6. Ledger & Part admin edit + delete (guarded: block delete if in use) ----
create or replace function admin_save_ledger(p_id uuid, p_type text, p_name text, p_gst text, p_email text, p_tax text, p_status text)
returns uuid as $$
declare i uuid; begin
  if p_id is null then
    insert into ledger(ledger_type,ledger_code,ledger_name,gst_no,contact_email,tax,status)
    values(p_type,next_ledger_code(p_type),p_name,nullif(p_gst,''),nullif(p_email,''),p_tax,coalesce(p_status,'Active')) returning id into i;
  else
    update ledger set ledger_name=p_name,gst_no=nullif(p_gst,''),contact_email=nullif(p_email,''),tax=p_tax,status=p_status where id=p_id returning id into i;
  end if; return i; end; $$ language plpgsql security definer;
create or replace function admin_delete_ledger(p_id uuid) returns jsonb as $$
begin
  if exists(select 1 from vouchers where ledger_id=p_id) or exists(select 1 from part_price where ledger_id=p_id) then
    return jsonb_build_object('ok',false,'msg','Ledger is in use (vouchers or pricing) — set Inactive instead.');
  end if;
  delete from ledger where id=p_id; return jsonb_build_object('ok',true,'msg','Ledger deleted.');
end; $$ language plpgsql security definer;

create or replace function admin_save_part(p_id uuid, p_name text, p_number text, p_uom text, p_group uuid, p_status text, p_cumulative text default null, p_lb numeric default 0)
returns uuid as $$
declare i uuid; begin
  if p_id is null then
    insert into part(part_code,part_name,part_number,uom,part_group_id,status,cumulative_group,lb_price)
    values(next_part_code(),p_name,nullif(p_number,''),coalesce(p_uom,'Nos'),p_group,coalesce(p_status,'Active'),nullif(trim(p_cumulative),''),coalesce(p_lb,0)) returning id into i;
  else
    update part set part_name=p_name,part_number=nullif(p_number,''),uom=p_uom,part_group_id=p_group,status=p_status,cumulative_group=nullif(trim(p_cumulative),''),lb_price=coalesce(p_lb,0) where id=p_id returning id into i;
  end if; return i; end; $$ language plpgsql security definer;
create or replace function admin_delete_part(p_id uuid) returns jsonb as $$
begin
  if exists(select 1 from voucher_lines where part_id=p_id) or exists(select 1 from stock_ledger where part_id=p_id) then
    return jsonb_build_object('ok',false,'msg','Part is in use (vouchers or stock) — set Inactive instead.');
  end if;
  delete from part_price where part_id=p_id;
  delete from opening_stock where part_id=p_id;
  delete from part where id=p_id; return jsonb_build_object('ok',true,'msg','Part deleted.');
end; $$ language plpgsql security definer;

-- save a part_price row (purchase carries weights; sale is price-only)
create or replace function save_part_price(
  p_id uuid, p_part uuid, p_ledger uuid, p_type text, p_price numeric, p_from date, p_upto date,
  p_inw numeric, p_outw numeric, p_allow numeric, p_qvar numeric, p_lb numeric default 0) returns uuid as $$
declare i uuid; begin
  if p_id is null then
    insert into part_price(part_id,ledger_id,price_type,unit_price,lb_price,valid_from,valid_upto,
      input_weight_pc,output_weight_pc,scrap_weight_pc,allowance_pct,qty_variation)
    values(p_part,p_ledger,p_type,p_price,coalesce(p_lb,0),p_from,p_upto,
      coalesce(p_inw,0),coalesce(p_outw,0),greatest(coalesce(p_inw,0)-coalesce(p_outw,0),0),coalesce(p_allow,0),coalesce(p_qvar,0))
    returning id into i;
  else
    update part_price set ledger_id=p_ledger,unit_price=p_price,lb_price=coalesce(p_lb,0),valid_from=p_from,valid_upto=p_upto,
      input_weight_pc=coalesce(p_inw,0),output_weight_pc=coalesce(p_outw,0),
      scrap_weight_pc=greatest(coalesce(p_inw,0)-coalesce(p_outw,0),0),allowance_pct=coalesce(p_allow,0),qty_variation=coalesce(p_qvar,0)
    where id=p_id returning id into i;
  end if; return i; end; $$ language plpgsql security definer;
create or replace function delete_part_price(p_id uuid) returns void as $$ delete from part_price where id=p_id; $$ language sql security definer;
create or replace function list_part_prices(p_type text) returns table(
  id uuid, part_id uuid, part_code text, part_name text, ledger_id uuid, ledger_name text,
  unit_price numeric, lb_price numeric, valid_from date, valid_upto date,
  input_weight_pc numeric, output_weight_pc numeric, scrap_weight_pc numeric, allowance_pct numeric, qty_variation numeric, active_now boolean) as $$
  select pp.id, pp.part_id, p.part_code, p.part_name, pp.ledger_id, l.ledger_name,
    pp.unit_price, coalesce(pp.lb_price,0), pp.valid_from, pp.valid_upto,
    pp.input_weight_pc, pp.output_weight_pc, pp.scrap_weight_pc, pp.allowance_pct, pp.qty_variation,
    (coalesce(pp.valid_from,'-infinity')<=current_date and coalesce(pp.valid_upto,'infinity')>=current_date)
  from part_price pp join part p on p.id=pp.part_id left join ledger l on l.id=pp.ledger_id
  where pp.price_type=p_type order by p.part_code, l.ledger_name, pp.valid_from desc nulls last;
$$ language sql;

-- ---- 3. Dashboard metrics: totals + rejection % vs production ----
create or replace function dashboard_metrics() returns table(
  total_purchase numeric, total_jobwork numeric, total_sales numeric, total_production numeric,
  process_rej numeric, material_rej numeric, process_pct numeric, material_pct numeric,
  process_allow numeric, material_allow numeric) as $$
  with t as (
    select
      coalesce(sum(l.qty) filter (where l.voucher_type='PURCHASE' and l.to_bucket='RC'),0) tp,
      coalesce(sum(l.qty) filter (where l.voucher_type='RC_IN_JW' and l.to_bucket='CC'),0) tjw,
      coalesce(sum(l.qty) filter (where l.voucher_type='SALES_LOCAL' and l.from_bucket='MG'),0) ts,
      coalesce(sum(l.qty) filter (where l.voucher_type='PRODUCTION' and l.to_bucket='MG'),0) tprod,
      coalesce(sum(l.qty) filter (where l.voucher_type='PROCESS_REJECTION' and l.to_bucket='PR'),0) prej,
      coalesce(sum(l.qty) filter (where l.voucher_type='MATERIAL_REJECTION' and l.to_bucket='MR'),0) mrej
    from stock_ledger l left join vouchers v on v.id=l.voucher_id where coalesce(v.cancelled,false)=false
  )
  select tp, tjw, ts, tprod, prej, mrej,
    case when tprod>0 then round(100.0*prej/tprod,2) else 0 end,
    case when tprod>0 then round(100.0*mrej/tprod,2) else 0 end,
    0.50, 3.00 from t;
$$ language sql;

-- ---- 14. Column / feature config store (per voucher type) ----
create table if not exists ui_column_config (
  voucher_type text, col_key text, label text, visible boolean default true, sort_order int default 0,
  primary key(voucher_type,col_key));
create or replace function get_column_config(p_type text) returns table(col_key text, label text, visible boolean, sort_order int) as $$
  select col_key,label,visible,sort_order from ui_column_config where voucher_type=p_type order by sort_order; $$ language sql;
create or replace function set_column_config(p_type text, p_key text, p_label text, p_visible boolean, p_sort int) returns void as $$
  insert into ui_column_config(voucher_type,col_key,label,visible,sort_order) values(p_type,p_key,p_label,p_visible,p_sort)
  on conflict(voucher_type,col_key) do update set label=excluded.label,visible=excluded.visible,sort_order=excluded.sort_order; $$ language sql security definer;

-- ---- 12/13. Full voucher detail (header + lines + packages) for Books drill-down ----
create or replace function voucher_detail(p_id uuid) returns jsonb as $$
  select jsonb_build_object(
    'header',(select to_jsonb(v) from vouchers v where v.id=p_id),
    'ledger',(select ledger_name from ledger l join vouchers v on v.ledger_id=l.id where v.id=p_id),
    'location',(select loc.loc_name from location loc join vouchers v on v.location_id=loc.id where v.id=p_id),
    'lines',coalesce((select jsonb_agg(jsonb_build_object(
        'sno',vl.sno,'part_code',p.part_code,'part_name',p.part_name,'ref_no',vl.ref_no,
        'invoice_qty',vl.invoice_qty,'actual_qty',vl.actual_qty,'qty',vl.qty,'uom',vl.uom,
        'weight',vl.weight,'unit_price',vl.unit_price,'po_price',vl.po_price,'basic_value',vl.basic_value,
        'disposition',vl.disposition,'source_bucket',vl.source_bucket,'return_bucket',vl.return_bucket,
        'defect_type',vl.defect_type,'root_cause',vl.root_cause,'line_note',vl.line_note,'packages',vl.packages)
        order by vl.sno) from voucher_lines vl left join part p on p.id=vl.part_id where vl.voucher_id=p_id),'[]'::jsonb)
  );
$$ language sql security definer;

-- enrich list_vouchers with periods + posting (11)
create or replace function list_vouchers_full(p_type text) returns table(
  id uuid, voucher_id_code text, voucher_no text, voucher_period text, voucher_date date,
  posting_period text, posting_date date, vehicle_no text, valid_thru date, ledger_name text, total_qty numeric, total_value numeric, line_count bigint,
  status text, generated boolean, cancelled boolean, rec_copy boolean, grn boolean, gstr1 boolean, gstr2b boolean,
  price_approved text, approved_mgmt text, approved_acc boolean, remarks text, delete_requested boolean, modify_requested boolean,
  created_at timestamptz, lines jsonb) as $$
  select v.id,v.voucher_id_code,v.voucher_no,v.voucher_period,v.voucher_date,
    to_char(coalesce(v.posting_date,v.voucher_date),'Mon YYYY'),v.posting_date,v.vehicle_no,v.valid_thru,l.ledger_name,
    coalesce((select sum(qty) from voucher_lines x where x.voucher_id=v.id),0),
    coalesce((select sum(basic_value) from voucher_lines x where x.voucher_id=v.id),0),
    (select count(*) from voucher_lines x where x.voucher_id=v.id),
    v.status,v.generated,v.cancelled,v.rec_copy,coalesce(v.grn,false),v.gstr1,v.gstr2b,v.price_approved,v.approved_mgmt,v.approved_acc,v.narration,
    v.delete_requested,v.modify_requested, v.created_at,
    coalesce((select jsonb_agg(jsonb_build_object(
        'sno',vl.sno,'part_code',p.part_code,'part_name',p.part_name,'ref_no',vl.ref_no,
        'invoice_qty',vl.invoice_qty,'actual_qty',vl.actual_qty,'qty',vl.qty,'uom',vl.uom,
        'weight',vl.weight,'unit_price',vl.unit_price,'po_price',vl.po_price,'basic_value',vl.basic_value,
        'lb_price', case when v.voucher_type='SALES_LOCAL' then coalesce(nullif((
            select pp.lb_price from part_price pp
            where pp.part_id=vl.part_id and pp.ledger_id=v.ledger_id and pp.price_type='sale'
              and (pp.valid_from is null or pp.valid_from<=v.voucher_date)
              and (pp.valid_upto is null or pp.valid_upto>=v.voucher_date)
            order by pp.valid_from desc nulls last limit 1),0), p.lb_price, 0) end,
        'pkg_count', coalesce(nullif(vl.pkg_count,0), nullif(substring(vl.line_note from 'Packages: (\\d+)'),'')::numeric, 0),
        'lot_alloc', vl.lot_alloc,
        'packages',vl.packages) order by vl.sno)
      from voucher_lines vl join part p on p.id=vl.part_id where vl.voucher_id=v.id),'[]'::jsonb)
  from vouchers v left join ledger l on l.id=v.ledger_id where v.voucher_type=p_type and coalesce(v.rec_hold,false)=false order by v.created_at desc;
$$ language sql;

-- RLS for the new tables
do $$ declare t text; begin
  foreach t in array array['voucher_enabled','ui_column_config'] loop
    execute format('alter table %I enable row level security;',t);
    execute format('drop policy if exists pol_%s on %I;',t,t);
    execute format('create policy pol_%s on %I for all using(true) with check(true);',t,t);
  end loop; end $$;


-- =====================================================================
--  PER-VOUCHER SPEC PACK (appended after feature pack)
--  FY voucher numbers, date calcs, supervisor & defect stores,
--  chained PO/SO auto-lookup, DC allocation, DC due-date alerts.
-- =====================================================================

-- ---- Financial year from a date (Apr-Mar). Jun 2026 -> 2026-27 ----
create or replace function fy_start_year(p_date date) returns int as $$
  select case when extract(month from p_date) >= 4 then extract(year from p_date)::int
              else extract(year from p_date)::int - 1 end; $$ language sql immutable;
-- "2627" form
create or replace function fy_compact(p_date date) returns text as $$
  select to_char(fy_start_year(p_date) % 100, 'FM00') || to_char((fy_start_year(p_date)+1) % 100, 'FM00'); $$ language sql immutable;
-- "26-27" form
create or replace function fy_dashed(p_date date) returns text as $$
  select to_char(fy_start_year(p_date) % 100, 'FM00') || '-' || to_char((fy_start_year(p_date)+1) % 100, 'FM00'); $$ language sql immutable;

-- ---- DC Out (JW) number: DCJ + FYFY + MM + NNN (resets monthly) ----
create or replace function next_dcjw_no(p_date date) returns text as $$
declare mm text; fy text; seq int; prefix text; fmonth int;
begin
  fy := fy_compact(p_date);
  -- fiscal month: Apr=01, May=02, ... Dec=09, Jan=10, Feb=11, Mar=12
  fmonth := ((extract(month from p_date)::int + 8) % 12) + 1;
  mm := to_char(fmonth,'FM00');
  prefix := 'DDCJ'||fy||mm;
  select coalesce(max(substring(voucher_no from '...$')::int),0)+1 into seq
  from vouchers where voucher_type='DC_OUT_JW' and voucher_no like prefix||'%';
  -- admin can raise the floor via Settings (key dcjw_nnn_floor)
  seq := greatest(seq, coalesce((select nullif(value,'')::int from app_settings where key='dcjw_nnn_floor'),1));
  return prefix || to_char(seq,'FM000');
end; $$ language plpgsql;

-- ---- RC In (JW) number: CST/XXXXX/YY-YY (XXXXX user 5-digit) ----
create or replace function rcjw_no(p_serial text, p_date date) returns text as $$
  select 'CST/'||lpad(regexp_replace(coalesce(p_serial,''),'[^0-9]','','g'),5,'0')||'/'||fy_dashed(p_date); $$ language sql;

-- ---- Valid-through / due-date calculators ----
-- PO: up to 5th of next month (already valid_thru_5th)
-- SO: last day of voucher month
create or replace function valid_thru_eom(p_date date) returns date as $$
  select (date_trunc('month',p_date)+interval '1 month'-interval '1 day')::date; $$ language sql immutable;
-- DC Out (JW): voucher date + 3 days
create or replace function due_date_3d(p_date date) returns date as $$
  select (p_date + interval '3 days')::date; $$ language sql immutable;

-- ---- DC Out (JW) due-date gate: block new DCs if any overdue, unless admin-cleared ----
create or replace function dcjw_overdue_block(p_ledger uuid) returns void as $$
declare n int;
begin
  select count(*) into n from vouchers v
   where v.voucher_type='DC_OUT_JW' and coalesce(v.cancelled,false)=false
     and v.valid_thru < current_date
     and coalesce(v.status,'OPEN') <> 'CLOSED'
     and exists (select 1 from dc_fulfilment d where d.dc_id=v.id and d.pending_qty>0)
     and coalesce(v.approved_mgmt,'APPROVED') <> 'DC_OVERRIDE';
  if n > 0 then
    raise exception 'Overdue DC Out (JW) exist (% past due, still pending). Admin must clear before new DCs.', n using errcode='42501';
  end if;
end; $$ language plpgsql;

-- ---- Supervisors (Production) ----
create table if not exists supervisor (id uuid primary key default gen_random_uuid(), name text unique not null, active boolean default true);
create or replace function list_supervisors() returns table(id uuid, name text) as $$ select id,name from supervisor where active order by name; $$ language sql;
create or replace function create_supervisor(p_name text) returns uuid as $$
  insert into supervisor(name) values(p_name) on conflict(name) do update set active=true returning id; $$ language sql security definer;

-- ---- Defect types (Process / Material rejection) with Create + Others ----
create table if not exists defect_type (id uuid primary key default gen_random_uuid(), name text unique not null, active boolean default true);
create or replace function list_defect_types() returns table(id uuid, name text) as $$ select id,name from defect_type where active order by name; $$ language sql;
create or replace function create_defect_type(p_name text) returns uuid as $$
  insert into defect_type(name) values(p_name) on conflict(name) do update set active=true returning id; $$ language sql security definer;

-- ---- Chained auto-population: parts for a given vendor/customer ----
-- parts that have a purchase price row for this vendor (Purchase auto-populate)
create or replace function parts_for_vendor(p_ledger uuid) returns table(part_id uuid, part_code text, part_name text) as $$
  select distinct p.id, p.part_code, p.part_name from part p
  join part_price pp on pp.part_id=p.id and pp.price_type='purchase' and pp.ledger_id=p_ledger
  where p.status='Active' order by p.part_code; $$ language sql;
-- parts for a customer (Sales auto-populate)
create or replace function parts_for_customer(p_ledger uuid) returns table(part_id uuid, part_code text, part_name text) as $$
  select distinct p.id, p.part_code, p.part_name from part p
  join part_price pp on pp.part_id=p.id and pp.price_type='sale' and pp.ledger_id=p_ledger
  where p.status='Active' order by p.part_code; $$ language sql;

-- open POs for a vendor+part (Purchase Ref dropdown — chained on vendor AND part)
create or replace function open_pos_for(p_ledger uuid, p_part uuid) returns table(voucher_no text, pending_qty numeric, po_price numeric, voucher_date date) as $$
  select o.voucher_no, o.pending_qty,
    coalesce((select unit_price from voucher_lines vl join vouchers v on v.id=vl.voucher_id
      where v.voucher_no=o.voucher_no and vl.part_id=p_part limit 1),0),
    o.voucher_date
  from open_orders o
  where o.voucher_type='PURCHASE_ORDER' and o.ledger_id=p_ledger and o.part_id=p_part and o.pending_qty>0
  order by o.voucher_date; $$ language sql;

-- open SOs for a customer+part (Sales Ref dropdown — chained on customer AND part)
create or replace function open_sos_for(p_ledger uuid, p_part uuid) returns table(voucher_no text, pending_qty numeric, so_price numeric, voucher_date date) as $$
  select o.voucher_no, o.pending_qty,
    coalesce((select unit_price from voucher_lines vl join vouchers v on v.id=vl.voucher_id
      where v.voucher_no=o.voucher_no and vl.part_id=p_part limit 1),0),
    o.voucher_date
  from open_orders o
  where o.voucher_type='SALES_ORDER' and o.ledger_id=p_ledger and o.part_id=p_part and o.pending_qty>0
  order by o.voucher_date; $$ language sql;

-- open DCs for RC In (JW) allocation — by vendor + part, active & pending>0
create or replace function open_dcs_for(p_ledger uuid, p_part uuid) returns table(voucher_no text, pending_qty numeric, voucher_date date, due_date date) as $$
  select d.voucher_no, d.pending_qty, d.voucher_date, d.due_date
  from dc_fulfilment d
  where d.voucher_type='DC_OUT_JW' and d.ledger_id=p_ledger and d.part_id=p_part and d.pending_qty>0
  order by d.voucher_date; $$ language sql;


-- =====================================================================
--  SPEC PACK 2 (appended last). Implements:
--   - Price-pending Purchase (save, no stock; post on approve; discard on reject)
--   - Averaged RM weight profile per part
--   - DC Out (JW) overdue admin-approval page support
--   - Per-machine #10/#20/#30 enable in machine_config
-- =====================================================================

-- ---- Averaged RM weight profile across all the part's RM vendor rows ----
create or replace function avg_weight_profile(p_part uuid)
returns table(input_weight_pc numeric, output_weight_pc numeric, allowance_pct numeric, qty_variation numeric, scrap_weight_pc numeric) as $$
  select coalesce(avg(nullif(input_weight_pc,0)),0),
         coalesce(avg(nullif(output_weight_pc,0)),0),
         coalesce(avg(nullif(allowance_pct,0)),0),
         coalesce(avg(nullif(qty_variation,0)),0),
         coalesce(avg(nullif(scrap_weight_pc,0)),0)
  from part_price where part_id=p_part and price_type='purchase';
$$ language sql;

-- ---- Per-machine operation enable (#10/#20/#30) ----
alter table machine_config add column if not exists op10_enabled boolean default true;
alter table machine_config add column if not exists op20_enabled boolean default true;
alter table machine_config add column if not exists op30_enabled boolean default true;

-- extend mc_save to carry the three flags (keep old signature working via overload)
create or replace function mc_save(p_id uuid, p_group uuid, p_machine text, p_operation text, p_sort int,
  p_op10 boolean default true, p_op20 boolean default true, p_op30 boolean default true) returns uuid as $$
declare i uuid; begin
  if p_id is null then
    insert into machine_config(part_group_id,machine,operation,sort_order,op10_enabled,op20_enabled,op30_enabled)
    values(p_group,p_machine,p_operation,coalesce(p_sort,0),p_op10,p_op20,p_op30) returning id into i;
  else
    update machine_config set part_group_id=p_group, machine=p_machine, operation=p_operation, sort_order=coalesce(p_sort,0),
      op10_enabled=p_op10, op20_enabled=p_op20, op30_enabled=p_op30 where id=p_id returning id into i;
  end if; return i; end; $$ language plpgsql security definer;

-- production_layout must expose the per-machine flags
drop function if exists production_layout();
create or replace function production_layout() returns table(
  group_id uuid, group_name text, machine_id uuid, machine text, operation text, sort_order int,
  op10_enabled boolean, op20_enabled boolean, op30_enabled boolean) as $$
  select g.id, g.group_name, m.id, m.machine, m.operation, m.sort_order,
         coalesce(m.op10_enabled,true), coalesce(m.op20_enabled,true), coalesce(m.op30_enabled,true)
  from part_group g left join machine_config m on m.part_group_id=g.id
  order by g.group_name, m.sort_order, m.machine;
$$ language sql;

-- ---- DC Out (JW) overdue list + admin clear (Administration approval page) ----
create or replace function overdue_dcjw() returns table(
  id uuid, voucher_no text, voucher_date date, due_date date, ledger_name text, part_code text, pending_qty numeric, days_overdue int) as $$
  select v.id, v.voucher_no, v.voucher_date, v.valid_thru, l.ledger_name, p.part_code, d.pending_qty,
    (current_date - v.valid_thru)::int
  from vouchers v
  join dc_fulfilment d on d.dc_id=v.id and d.pending_qty>0
  left join ledger l on l.id=v.ledger_id
  left join part p on p.id=d.part_id
  where v.voucher_type='DC_OUT_JW' and coalesce(v.cancelled,false)=false
    and v.valid_thru < current_date
    and coalesce(v.approved_mgmt,'APPROVED') <> 'DC_OVERRIDE'
  order by v.valid_thru;
$$ language sql;

-- admin clears an overdue DC so new DCs can post again
create or replace function clear_overdue_dcjw(p_id uuid, p_user text) returns void as $$
  update vouchers set approved_mgmt='DC_OVERRIDE' where id=p_id;
$$ language sql security definer;

-- ---- PRICE-PENDING PURCHASE -----------------------------------------
-- A purchase whose unit price <> PO price is saved WITHOUT any stock
-- movement, flagged price_approved='PENDING'. On approval the held
-- lines post to stock through the sealed gate; on reject it is removed.
-- We store nothing special beyond the voucher+lines already inserted and
-- the PENDING flag; the held qty lives in voucher_lines.

-- post the held stock for a previously price-pending purchase
create or replace function approve_price_post(p_id uuid, p_user text) returns jsonb as $$
declare v record; ln record; lot_on boolean; lid uuid; new_lot text;
begin
  select * into v from vouchers where id=p_id;
  if v is null then return jsonb_build_object('ok',false,'msg','Voucher not found'); end if;
  if v.price_approved <> 'PENDING' then return jsonb_build_object('ok',false,'msg','Not in pending state'); end if;
  if v.voucher_type <> 'PURCHASE' then
    -- non-purchase pending: just clear the flag
    update vouchers set price_approved='OK' where id=p_id; return jsonb_build_object('ok',true,'msg','Approved');
  end if;
  select (value='true') into lot_on from app_settings where key='lot_enabled';
  -- post each line VENDOR->RC through the gate (no negative possible for inflow)
  for ln in select * from voucher_lines where voucher_id=p_id order by sno loop
    perform post_stock_move(coalesce(v.posting_date,v.voucher_date), ln.part_id, 'VENDOR','RC',
      ln.actual_qty, p_id, 'PURCHASE', v.voucher_no, 'price approved', 0, coalesce(v.location_id,default_location()), coalesce(v.location_id,default_location()));
    if lot_on and ln.actual_qty>0 then
      new_lot:=next_lot_no(ln.part_id, v.ledger_id);
      insert into lot_master(lot_no,part_id,ledger_id,current_bucket,original_qty,ref_voucher)
        values(new_lot,ln.part_id,v.ledger_id,'RC',ln.actual_qty,v.voucher_no) returning id into lid;
      insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values(lid,'VENDOR','RC',ln.actual_qty,p_id,'PURCHASE',v.voucher_no);
    end if;
  end loop;
  update vouchers set price_approved='OK' where id=p_id;
  perform log_audit('PRICE APPROVE PURCHASE', p_user, v.voucher_no);
  return jsonb_build_object('ok',true,'msg','Approved & posted to stock');
end; $$ language plpgsql security definer;

-- reject a price-pending purchase: discard voucher entirely (no stock was posted)
create or replace function reject_price(p_id uuid, p_user text) returns jsonb as $$
declare v record;
begin
  select * into v from vouchers where id=p_id;
  if v is null then return jsonb_build_object('ok',false,'msg','Not found'); end if;
  if v.price_approved <> 'PENDING' then return jsonb_build_object('ok',false,'msg','Not pending'); end if;
  delete from voucher_lines where voucher_id=p_id;
  delete from vouchers where id=p_id;
  perform log_audit('PRICE REJECT', p_user, v.voucher_no);
  return jsonb_build_object('ok',true,'msg','Rejected & discarded');
end; $$ language plpgsql security definer;

-- richer pending list for the Price Approval screen
create or replace function price_pending_full() returns table(
  id uuid, voucher_type text, voucher_no text, voucher_date date, ledger_name text,
  total_qty numeric, total_value numeric) as $$
  select v.id, v.voucher_type, v.voucher_no, v.voucher_date, l.ledger_name,
    coalesce((select sum(actual_qty) from voucher_lines x where x.voucher_id=v.id),0),
    coalesce((select sum(basic_value) from voucher_lines x where x.voucher_id=v.id),0)
  from vouchers v left join ledger l on l.id=v.ledger_id
  where v.price_approved='PENDING' and coalesce(v.cancelled,false)=false order by v.created_at;
$$ language sql;

-- per-line detail for the price-approval screen (part + entered vs PO price)
create or replace function price_pending_lines(p_voucher uuid) returns table(
  part_code text, part_name text, qty numeric, unit_price numeric, po_price numeric, basic_value numeric) as $$
  select p.part_code, p.part_name, coalesce(nullif(vl.actual_qty,0),vl.qty), vl.unit_price, vl.po_price, vl.basic_value
  from voucher_lines vl left join part p on p.id=vl.part_id
  where vl.voucher_id=p_voucher order by vl.sno;
$$ language sql;



-- =====================================================================
--  PROFESSIONAL LEDGER FUNCTIONS (part ledger + stock ledger journal)
-- =====================================================================

-- Part Ledger: one part + one bucket, chronological with running balance,
-- counterparty (other bucket), reference, and line value where available.
create or replace function part_ledger_full(p_part uuid, p_bucket text, p_from date default null, p_to date default null)
returns table(seq int, ledger_date date, voucher_type text, voucher_no text, counterparty text,
  ref_no text, inward numeric, outward numeric, running numeric, value numeric, vendor text) as $$
declare opening numeric; all_b boolean := (p_bucket = 'ALL');
begin
  if all_b then
    select coalesce(sum(qty),0) into opening from opening_stock where part_id=p_part;
  else
    select coalesce(sum(qty),0) into opening from opening_stock where part_id=p_part and bucket=p_bucket;
  end if;
  if opening is null then opening:=0; end if;
  return query
  with moves as (
    select l.ledger_date, l.voucher_type, l.voucher_no,
      case when all_b then coalesce(l.from_bucket,'') || '→' || coalesce(l.to_bucket,'')
           when l.to_bucket=p_bucket then l.from_bucket else l.to_bucket end counterparty,
      vl.vref,
      case when all_b then (case when l.to_bucket is not null and coalesce((select not is_external from buckets where code=l.to_bucket),false) then l.qty else 0 end)
           when l.to_bucket=p_bucket then l.qty else 0 end inward,
      case when all_b then (case when l.from_bucket is not null and coalesce((select not is_external from buckets where code=l.from_bucket),false) then l.qty else 0 end)
           when l.from_bucket=p_bucket then l.qty else 0 end outward,
      coalesce(vl.basic_value,0) value,
      led.ledger_name vendor
    from stock_ledger l
    left join vouchers v on v.id=l.voucher_id
    left join ledger led on led.id=v.ledger_id
    left join lateral (select coalesce(nullif(vx.ref_no,''), nullif(v.voucher_no,''), v.voucher_id_code) vref, vx.basic_value from voucher_lines vx
       where vx.voucher_id=l.voucher_id and vx.part_id=l.part_id
       order by case when vx.qty=l.qty then 0 else 1 end, vx.sno limit 1) vl on true
    where l.part_id=p_part
      and (all_b or l.to_bucket=p_bucket or l.from_bucket=p_bucket)
      and coalesce(v.cancelled,false)=false
      and (p_from is null or l.ledger_date>=p_from) and (p_to is null or l.ledger_date<=p_to)
  ),
  ordered as (
    select 0 so, null::date ld, 'OPENING BALANCE'::text vt, ''::text vn, ''::text cp, ''::text rf, opening inw, 0::numeric outw, 0::numeric val, null::text ven
    union all
    select 1, mv.ledger_date, mv.voucher_type, mv.voucher_no, mv.counterparty, mv.vref, mv.inward, mv.outward, mv.value, mv.vendor from moves mv
  )
  select row_number() over (order by o.so, o.ld nulls first)::int,
    o.ld, o.vt, o.vn, o.cp, o.rf, o.inw, o.outw,
    sum(o.inw-o.outw) over (order by o.so, o.ld nulls first rows between unbounded preceding and current row),
    o.val, o.ven
  from ordered o order by o.so, o.ld nulls first;
end; $$ language plpgsql;

-- Two-way purchase summary (vendor only lives on PURCHASE + the two returns)
create or replace function part_vendor_summary(p_part uuid, p_from date default null, p_to date default null)
returns table(ledger_id uuid, vendor_code text, vendor_name text,
  purchased numeric, returned numeric, net numeric, value numeric, purchases bigint) as $$
  select v.ledger_id, l.ledger_code, l.ledger_name,
    coalesce(sum(case when v.voucher_type='PURCHASE' then vl.qty else 0 end),0),
    coalesce(sum(case when v.voucher_type in ('DEBIT_NOTE_RC','DEBIT_NOTE_DN') then vl.qty else 0 end),0),
    coalesce(sum(case when v.voucher_type='PURCHASE' then vl.qty else -vl.qty end),0),
    coalesce(sum(case when v.voucher_type='PURCHASE' then vl.basic_value else -vl.basic_value end),0),
    count(distinct case when v.voucher_type='PURCHASE' then v.id end)
  from vouchers v
  join voucher_lines vl on vl.voucher_id=v.id and vl.part_id=p_part
  left join ledger l on l.id=v.ledger_id
  where v.voucher_type in ('PURCHASE','DEBIT_NOTE_RC','DEBIT_NOTE_DN')
    and coalesce(v.cancelled,false)=false
    and (p_from is null or v.voucher_date>=p_from) and (p_to is null or v.voucher_date<=p_to)
  group by v.ledger_id, l.ledger_code, l.ledger_name
  order by l.ledger_name;
$$ language sql;

create or replace function vendor_part_summary(p_ledger uuid, p_from date default null, p_to date default null, p_part uuid default null)
returns table(part_id uuid, part_code text, part_name text,
  purchased numeric, returned numeric, net numeric, value numeric, purchases bigint) as $$
  select vl.part_id, p.part_code, p.part_name,
    coalesce(sum(case when v.voucher_type='PURCHASE' then vl.qty else 0 end),0),
    coalesce(sum(case when v.voucher_type in ('DEBIT_NOTE_RC','DEBIT_NOTE_DN') then vl.qty else 0 end),0),
    coalesce(sum(case when v.voucher_type='PURCHASE' then vl.qty else -vl.qty end),0),
    coalesce(sum(case when v.voucher_type='PURCHASE' then vl.basic_value else -vl.basic_value end),0),
    count(distinct case when v.voucher_type='PURCHASE' then v.id end)
  from vouchers v
  join voucher_lines vl on vl.voucher_id=v.id
  join part p on p.id=vl.part_id
  where v.ledger_id=p_ledger and v.voucher_type in ('PURCHASE','DEBIT_NOTE_RC','DEBIT_NOTE_DN')
    and coalesce(v.cancelled,false)=false
    and (p_part is null or vl.part_id=p_part)
    and (p_from is null or v.voucher_date>=p_from) and (p_to is null or v.voucher_date<=p_to)
  group by vl.part_id, p.part_code, p.part_name
  order by p.part_code;
$$ language sql;

-- Document-wise: each Purchase / Debit Note line for a vendor (optionally one part)
create or replace function vendor_doc_lines(p_ledger uuid, p_from date default null, p_to date default null, p_part uuid default null)
returns table(voucher_date date, doc_type text, voucher_no text, part_code text, part_name text,
  qty numeric, unit_price numeric, value numeric, is_return boolean) as $$
  select v.voucher_date,
    case v.voucher_type when 'PURCHASE' then 'Purchase' when 'DEBIT_NOTE_RC' then 'Debit Note (RC)' when 'DEBIT_NOTE_DN' then 'Debit Note' else v.voucher_type end,
    v.voucher_no, p.part_code, p.part_name,
    vl.qty, vl.unit_price, vl.basic_value,
    (v.voucher_type in ('DEBIT_NOTE_RC','DEBIT_NOTE_DN'))
  from vouchers v
  join voucher_lines vl on vl.voucher_id=v.id
  join part p on p.id=vl.part_id
  where v.ledger_id=p_ledger and v.voucher_type in ('PURCHASE','DEBIT_NOTE_RC','DEBIT_NOTE_DN')
    and coalesce(v.cancelled,false)=false
    and (p_part is null or vl.part_id=p_part)
    and (p_from is null or v.voucher_date>=p_from) and (p_to is null or v.voucher_date<=p_to)
  order by v.voucher_date, v.voucher_no, p.part_code;
$$ language sql;


-- Cumulative-group ledger: same shape as part_ledger_full but rolled up across
-- every part sharing the given cumulative_group. View-only.
create or replace function part_ledger_group(p_group text, p_bucket text, p_from date default null, p_to date default null)
returns table(seq int, ledger_date date, voucher_type text, voucher_no text, counterparty text,
  ref_no text, inward numeric, outward numeric, running numeric, value numeric, vendor text) as $$
declare opening numeric;
begin
  select coalesce(sum(o.qty),0) into opening
  from opening_stock o join part p on p.id=o.part_id
  where coalesce(nullif(trim(p.cumulative_group),''),p.part_name)=p_group and o.bucket=p_bucket;
  return query
  with grp_parts as (
    select id from part where coalesce(nullif(trim(cumulative_group),''),part_name)=p_group
  ), moves as (
    select l.ledger_date, l.voucher_type, l.voucher_no,
      case when l.to_bucket=p_bucket then l.from_bucket else l.to_bucket end counterparty,
      vl.vref,
      case when l.to_bucket=p_bucket then l.qty else 0 end inward,
      case when l.from_bucket=p_bucket then l.qty else 0 end outward,
      coalesce(vl.basic_value,0) value,
      led.ledger_name vendor
    from stock_ledger l
    join grp_parts gp on gp.id=l.part_id
    left join vouchers v on v.id=l.voucher_id
    left join ledger led on led.id=v.ledger_id
    left join lateral (select coalesce(nullif(vx.ref_no,''), nullif(v.voucher_no,''), v.voucher_id_code) vref, vx.basic_value from voucher_lines vx
       where vx.voucher_id=l.voucher_id and vx.part_id=l.part_id
       order by case when vx.qty=l.qty then 0 else 1 end, vx.sno limit 1) vl on true
    where (l.to_bucket=p_bucket or l.from_bucket=p_bucket)
      and coalesce(v.cancelled,false)=false
      and (p_from is null or l.ledger_date>=p_from) and (p_to is null or l.ledger_date<=p_to)
  ), ordered as (
    select 0 so, null::date ld, 'OPENING BALANCE'::text vt, ''::text vn, ''::text cp, ''::text rf, opening inw, 0::numeric outw, 0::numeric val, null::text ven
    union all
    select 1, mv.ledger_date, mv.voucher_type, mv.voucher_no, mv.counterparty, mv.vref, mv.inward, mv.outward, mv.value, mv.vendor from moves mv
  )
  select row_number() over (order by o.so, o.ld nulls first)::int,
    o.ld, o.vt, o.vn, o.cp, o.rf, o.inw, o.outw,
    sum(o.inw-o.outw) over (order by o.so, o.ld nulls first rows between unbounded preceding and current row),
    o.val, o.ven
  from ordered o order by o.so, o.ld nulls first;
end; $$ language plpgsql;

-- Stock Ledger journal: every movement across all parts, joined with part
-- and ledger names, with optional filters. Returns newest first.
create or replace function stock_ledger_full(
  p_part uuid default null, p_bucket text default null, p_vtype text default null,
  p_from date default null, p_to date default null)
returns table(ledger_date date, voucher_no text, voucher_type text, part_code text, part_name text,
  ledger_name text, from_bucket text, to_bucket text, qty numeric, note text) as $$
  select l.ledger_date, l.voucher_no, l.voucher_type, p.part_code, p.part_name,
    ln.ledger_name, l.from_bucket, l.to_bucket, l.qty, l.note
  from stock_ledger l
  left join vouchers v on v.id=l.voucher_id
  left join part p on p.id=l.part_id
  left join ledger ln on ln.id=v.ledger_id
  where coalesce(v.cancelled,false)=false
    and (p_part is null or l.part_id=p_part)
    and (p_bucket is null or l.from_bucket=p_bucket or l.to_bucket=p_bucket)
    and (p_vtype is null or l.voucher_type=p_vtype)
    and (p_from is null or l.ledger_date>=p_from)
    and (p_to is null or l.ledger_date<=p_to)
  order by l.ledger_date desc, l.created_at desc;
$$ language sql;

-- =====================================================================
--  ADD-ON: voucher document counts, audit reader
-- =====================================================================

-- Count of (non-cancelled) documents per voucher type — for the Books tile.
create or replace function voucher_counts() returns table(voucher_type text, doc_count bigint) as $$
  select voucher_type, count(*) from vouchers where coalesce(cancelled,false)=false group by voucher_type
  union all
  select 'PRODUCTION', count(*) from production_log;
$$ language sql;

-- total documents across all types
create or replace function voucher_count_total() returns bigint as $$
  select (select count(*) from vouchers where coalesce(cancelled,false)=false) + (select count(*) from production_log);
$$ language sql;

-- Audit log reader (most recent first), optional limit.
create or replace function audit_log_recent(p_limit int default 500) returns table(
  ts timestamptz, action text, app_user text, details text) as $$
  select ts, action, app_user, details from audit_log order by ts desc limit coalesce(p_limit,500);
$$ language sql;

-- =====================================================================
--  DASHBOARD+ / REORDER / AGEING MODULE  (material mgmt scope)
-- =====================================================================

-- reorder level + (optional) monthly production target on the part master
alter table part add column if not exists reorder_level numeric default 0;
alter table part add column if not exists reorder_bucket text default 'MG';   -- which bucket to watch
alter table part add column if not exists monthly_target numeric default 0;    -- production target/month

-- ---- LOW STOCK: parts whose watched-bucket balance <= reorder_level (>0) ----
create or replace function low_stock_parts() returns table(
  part_id uuid, part_code text, part_name text, bucket text, balance numeric, reorder_level numeric, shortfall numeric) as $$
  select p.id, p.part_code, p.part_name, coalesce(p.reorder_bucket,'MG'),
         coalesce(c.bal,0), p.reorder_level,
         greatest(p.reorder_level - coalesce(c.bal,0),0)
  from part p
  left join stock_cache c on c.part_id=p.id and c.bucket=coalesce(p.reorder_bucket,'MG')
  where p.status='Active' and coalesce(p.reorder_level,0) > 0
    and coalesce(c.bal,0) <= p.reorder_level
  order by (p.reorder_level - coalesce(c.bal,0)) desc;
$$ language sql;

-- ---- STUCK / AGEING STOCK: how long since the LAST inward move into a bucket,
--      for buckets that still hold a positive balance. Flags material sitting too long. ----
create or replace function stuck_stock(p_min_days int default 0) returns table(
  part_id uuid, part_code text, part_name text, bucket text, balance numeric,
  last_in_date date, days_idle int) as $$
  select p.id, p.part_code, p.part_name, c.bucket, c.bal,
         li.last_in,
         (current_date - coalesce(li.last_in, current_date))::int
  from stock_cache c
  join part p on p.id=c.part_id
  left join lateral (
     select coalesce(max(l.ledger_date), min(v.voucher_date)) last_in
     from stock_ledger l left join vouchers v on v.id=l.voucher_id
     where l.part_id=c.part_id and l.to_bucket=c.bucket
  ) li on true
  where c.bal > 0
    and c.bucket in ('RC','RCJW','CC','MG','PR','MR','JOBOUT')
    and (current_date - coalesce(li.last_in, current_date)) >= coalesce(p_min_days,0)
  order by (current_date - coalesce(li.last_in, current_date)) desc;
$$ language sql;

-- ---- STOCK VALUATION: qty in each internal bucket * latest purchase price ----
create or replace function stock_valuation() returns table(
  part_id uuid, part_code text, part_name text, on_hand numeric, unit_price numeric, value numeric) as $$
  with px as (
    select pp.part_id, pp.unit_price,
           row_number() over (partition by pp.part_id order by pp.valid_from desc nulls last) rn
    from part_price pp where pp.price_type='purchase'
  ),
  oh as (
    select c.part_id, sum(c.bal) on_hand
    from stock_cache c
    where c.bucket in ('RC','RCJW','CC','MG','PR','MR','JOBOUT')
    group by c.part_id
  )
  select p.id, p.part_code, p.part_name,
         coalesce(oh.on_hand,0),
         coalesce((select unit_price from px where px.part_id=p.id and rn=1),0),
         round(coalesce(oh.on_hand,0) * coalesce((select unit_price from px where px.part_id=p.id and rn=1),0), 2)
  from part p
  left join oh on oh.part_id=p.id
  where p.status='Active'
  order by round(coalesce(oh.on_hand,0) * coalesce((select unit_price from px where px.part_id=p.id and rn=1),0), 2) desc nulls last;
$$ language sql;

create or replace function stock_valuation_total() returns numeric as $$
  select coalesce(sum(value),0) from stock_valuation();
$$ language sql;

-- ---- PENDING APPROVALS COUNT (price-pending + overdue DC + mod/del requests) ----
create or replace function pending_approvals() returns table(kind text, cnt bigint) as $$
  select 'Price Approval', count(*) from price_pending_full()
  union all
  select 'Overdue DC', count(*) from overdue_dcjw()
  union all
  select 'Mod/Del Requests', count(*) from marked_requests();
$$ language sql;

-- ---- PRODUCTION VS TARGET (this month) ----
create or replace function production_vs_target() returns table(
  produced_month numeric, target_month numeric, pct numeric, produced_today numeric) as $$
  with prod as (
    select coalesce(sum(l.qty) filter (where l.voucher_type='PRODUCTION' and l.to_bucket='MG'
              and date_trunc('month',l.ledger_date)=date_trunc('month',current_date)),0) pm,
           coalesce(sum(l.qty) filter (where l.voucher_type='PRODUCTION' and l.to_bucket='MG'
              and l.ledger_date=current_date),0) pt
    from stock_ledger l left join vouchers v on v.id=l.voucher_id where coalesce(v.cancelled,false)=false
  ),
  tgt as (select coalesce(sum(monthly_target),0) tm from part where status='Active')
  select prod.pm, tgt.tm,
         case when tgt.tm>0 then round(100.0*prod.pm/tgt.tm,1) else 0 end,
         prod.pt
  from prod, tgt;
$$ language sql;

-- ---- OVERDUE DC count for the dashboard headline ----
create or replace function overdue_dc_count() returns bigint as $$
  select count(*) from overdue_dcjw();
$$ language sql;

-- save reorder / target settings from the Part form
create or replace function save_part_reorder(p_part uuid, p_level numeric, p_bucket text, p_target numeric) returns void as $$
  update part set reorder_level=coalesce(p_level,0), reorder_bucket=coalesce(nullif(p_bucket,''),'MG'),
                  monthly_target=coalesce(p_target,0) where id=p_part;
$$ language sql security definer;

-- =====================================================================
--  PERIOD CLOSE / FREEZE MODULE
--  A month, once closed, refuses any stock movement dated within it.
--  Closing snapshots each (part,bucket) balance as the locked opening
--  for the period; reopening lifts the lock. Admin-only via app flag.
-- =====================================================================

create table if not exists period_lock(
  period_month date primary key,           -- always the 1st of the month
  closed_at timestamptz default now(),
  closed_by text,
  note text);

-- snapshot of balances captured at close, so a closed period's opening is frozen
create table if not exists period_opening(
  period_month date, part_id uuid, location_id uuid, bucket text, qty numeric,
  primary key(period_month, part_id, location_id, bucket));

-- is the month containing p_date locked?
create or replace function period_is_locked(p_date date) returns boolean as $$
  select exists(select 1 from period_lock where period_month = date_trunc('month',p_date)::date);
$$ language sql stable;

-- list of closed periods (newest first) for the admin screen
create or replace function closed_periods() returns table(period_month date, closed_at timestamptz, closed_by text, note text) as $$
  select period_month, closed_at, closed_by, note from period_lock order by period_month desc;
$$ language sql;

-- close a month: lock it + snapshot every current (part,bucket) balance
create or replace function close_period(p_month date, p_user text, p_note text default null) returns jsonb as $$
declare mth date := date_trunc('month', p_month)::date; n int;
begin
  if exists(select 1 from period_lock where period_month=mth) then
    raise exception 'Period % is already closed.', to_char(mth,'Mon YYYY');
  end if;
  -- cannot close a month that still has a future/open month already closed before it is fine;
  -- but disallow closing a month in the future
  if mth > date_trunc('month', current_date)::date then
    raise exception 'Cannot close a future month (%).', to_char(mth,'Mon YYYY');
  end if;
  insert into period_lock(period_month, closed_by, note) values(mth, p_user, p_note);
  -- snapshot balances as the frozen opening for the NEXT period
  insert into period_opening(period_month, part_id, location_id, bucket, qty)
    select (mth + interval '1 month')::date, c.part_id, c.location_id, c.bucket, c.bal
    from stock_cache c where c.bal <> 0;
  get diagnostics n = row_count;
  perform log_audit('PERIOD_CLOSE', p_user, 'Closed '||to_char(mth,'Mon YYYY')||' ('||n||' balances snapshot)');
  return jsonb_build_object('ok',true,'period',to_char(mth,'Mon YYYY'),'snapshot_rows',n);
end; $$ language plpgsql security definer;

-- reopen (admin): lift the lock and drop the frozen opening it produced
create or replace function reopen_period(p_month date, p_user text) returns jsonb as $$
declare mth date := date_trunc('month', p_month)::date;
begin
  if not exists(select 1 from period_lock where period_month=mth) then
    raise exception 'Period % is not closed.', to_char(mth,'Mon YYYY');
  end if;
  delete from period_lock where period_month=mth;
  delete from period_opening where period_month=(mth + interval '1 month')::date;
  perform log_audit('PERIOD_REOPEN', p_user, 'Reopened '||to_char(mth,'Mon YYYY'));
  return jsonb_build_object('ok',true,'period',to_char(mth,'Mon YYYY'));
end; $$ language plpgsql security definer;

-- =====================================================================
--  STOCK TRANSFER  (the only cross-location movement)
--  Moves the same (part,bucket) from one location to another. Enforces
--  the allow-list at BOTH ends and the per-location no-negative rule.
-- =====================================================================
create or replace function post_stock_transfer(
  p_date date, p_part uuid, p_bucket text, p_from_loc uuid, p_to_loc uuid, p_qty numeric, p_user text, p_note text default null
) returns jsonb as $$
declare vno text; v_id uuid; rid uuid;
begin
  if p_from_loc = p_to_loc then raise exception 'Transfer source and destination locations must differ.'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Transfer qty must be > 0.'; end if;
  -- period lock check on the transfer date
  if to_regclass('public.period_lock') is not null and period_is_locked(p_date) then
    raise exception 'PERIOD CLOSED: % is in a locked month.', to_char(p_date,'DD Mon YYYY') using errcode='23514';
  end if;
  vno := 'XFER'||to_char(clock_timestamp(),'YYMMDDHH24MISSMS')||substr(md5(random()::text),1,4);
  insert into vouchers(voucher_type,voucher_id_code,voucher_no,voucher_period,voucher_date,posting_date,
    narration,created_by,status,location_id)
  values('STOCK_TRANSFER','XFER',vno,to_char(p_date,'Mon YYYY'),p_date,p_date,p_note,p_user,'OPEN',p_from_loc)
  returning id into v_id;
  -- single move with differing from/to locations (same bucket both sides)
  rid := post_stock_move(p_date,p_part,p_bucket,p_bucket,p_qty,v_id,'STOCK_TRANSFER',vno,
           coalesce(p_note,'stock transfer'),0,p_from_loc,p_to_loc);
  perform log_audit('STOCK_TRANSFER',p_user,
    'Transferred '||p_qty||' '||p_bucket||' between locations ('||vno||')');
  return jsonb_build_object('ok',true,'voucher_no',vno,'id',v_id);
end; $$ language plpgsql security definer;

-- transfer history for the UI
create or replace function stock_transfers(p_limit int default 200) returns table(
  voucher_no text, xfer_date date, part_code text, bucket text, from_loc text, to_loc text, qty numeric) as $$
  select v.voucher_no, l.ledger_date, p.part_code, l.from_bucket,
         fl.loc_name, tl.loc_name, l.qty
  from stock_ledger l
  join vouchers v on v.id=l.voucher_id and v.voucher_type='STOCK_TRANSFER'
  left join part p on p.id=l.part_id
  left join location fl on fl.id=l.from_location
  left join location tl on tl.id=l.to_location
  order by l.created_at desc limit coalesce(p_limit,200);
$$ language sql;

-- =====================================================================
--  LOCATION ADMIN + READS (for Settings UI and location-aware screens)
-- =====================================================================
create or replace function list_locations(p_active_only boolean default false) returns table(
  id uuid, loc_code text, loc_name text, status text, is_default boolean, sort_order int) as $$
  select id, loc_code, loc_name, status, is_default, sort_order from location
  where (not p_active_only or status='Active') order by sort_order, loc_name;
$$ language sql;

create or replace function save_location(p_id uuid, p_code text, p_name text, p_status text, p_sort int) returns uuid as $$
declare i uuid; begin
  if p_id is null then
    insert into location(loc_code,loc_name,status,sort_order)
      values(nullif(p_code,''),p_name,coalesce(p_status,'Active'),coalesce(p_sort,0)) returning id into i;
  else
    update location set loc_code=nullif(p_code,''),loc_name=p_name,status=coalesce(p_status,'Active'),sort_order=coalesce(p_sort,0) where id=p_id returning id into i;
  end if;
  return i;
end; $$ language plpgsql security definer;

-- set the full bucket allow-list for a location in one call
create or replace function set_location_buckets(p_loc uuid, p_buckets text[]) returns void as $$
  delete from location_bucket where location_id=p_loc;
  insert into location_bucket(location_id,bucket) select p_loc, unnest(p_buckets);
$$ language sql security definer;

create or replace function location_buckets(p_loc uuid) returns table(bucket text) as $$
  select bucket from location_bucket where location_id=p_loc order by bucket;
$$ language sql;

-- per-location stock summary (part x bucket, for one location)
create or replace function stock_summary_loc(p_loc uuid) returns table(
  part_id uuid, part_code text, part_name text, bucket text, balance numeric) as $$
  select p.id, p.part_code, p.part_name, c.bucket, c.bal
  from stock_cache c join part p on p.id=c.part_id
  where c.location_id=p_loc and c.bal<>0
  order by p.part_code, c.bucket;
$$ language sql;

-- =====================================================================
--  RC In (variant) allocation source — open DC Out (Ret/Replacement)
--  vouchers, so RC In (Ret/Replacement) can pick the DC and inherit its
--  party name (free_ledger). Item 7.
-- =====================================================================
create or replace function open_variant_dcs(p_kind text) returns table(
  voucher_no text, voucher_date date, party text, qty numeric) as $$
  select v.voucher_no, v.voucher_date, coalesce(v.free_ledger, l.ledger_name),
    coalesce((select sum(coalesce(nullif(x.qty,0),x.actual_qty)) from voucher_lines x where x.voucher_id=v.id),0)
  from vouchers v left join ledger l on l.id=v.ledger_id
  where coalesce(v.cancelled,false)=false
    and v.voucher_type = case when p_kind='replace' then 'DC_OUT_REPLACE' else 'DC_OUT_RET' end
  order by v.voucher_date desc;
$$ language sql;

-- ---- cumulative stock summary (defined late: needs stock_cache) ----
-- Rolled up by cumulative group; parts without a group appear under their own
-- part name so nothing is lost. Summed across all locations and member parts.
create or replace function stock_summary_cumulative() returns table(
  grp text, members bigint, rc_bal numeric, rcjw_bal numeric, cc_bal numeric,
  mg_bal numeric, pr_bal numeric, mr_bal numeric, jobout_bal numeric) as $$
  select
    coalesce(nullif(trim(p.cumulative_group),''), p.part_name) grp,
    count(distinct p.id) members,
    coalesce(sum(case when c.bucket='RC' then c.bal end),0),
    coalesce(sum(case when c.bucket='RCJW' then c.bal end),0),
    coalesce(sum(case when c.bucket='CC' then c.bal end),0),
    coalesce(sum(case when c.bucket='MG' then c.bal end),0),
    coalesce(sum(case when c.bucket='PR' then c.bal end),0),
    coalesce(sum(case when c.bucket='MR' then c.bal end),0),
    coalesce(sum(case when c.bucket='JOBOUT' then c.bal end),0)
  from part p left join stock_cache c on c.part_id=p.id
  where p.status='Active'
  group by 1 order by 1;
$$ language sql;


-- ---- Production logs for the Books screen ----
create or replace function list_production_books() returns table(
  id uuid, log_code text, log_date date, log_period text, shift text, supervisor_1 text, supervisor_2 text,
  created_by text, machine_count bigint, total_op10 numeric, total_op20 numeric, total_op30 numeric,
  downtime_min numeric, rejected_qty numeric, rows jsonb, downtime jsonb, quality jsonb) as $$
  select pl.id, pl.log_code, pl.log_date, pl.log_period, pl.shift, pl.supervisor_1, pl.supervisor_2, pl.created_by,
    (select count(*) from production_rows pr where pr.production_id=pl.id),
    coalesce((select sum(pr.op10_actual) from production_rows pr where pr.production_id=pl.id),0),
    coalesce((select sum(pr.op20_actual) from production_rows pr where pr.production_id=pl.id),0),
    coalesce((select sum(pr.op30_actual) from production_rows pr where pr.production_id=pl.id),0),
    coalesce((select sum(d.duration_min) from downtime_log d where d.production_id=pl.id),0),
    coalesce((select sum(q.qty_rejected) from quality_log q where q.production_id=pl.id),0),
    coalesce((select jsonb_agg(jsonb_build_object(
      'section',pr.section,'machine_no',pr.machine_no,'operator',pr.operator,
      'part_name',p.part_name,'part_code',p.part_code,
      'lot_no',lm.lot_no,'lot_alloc',pr.lot_alloc,
      'op10',pr.op10_actual,'op20',pr.op20_actual,'op30',pr.op30_actual,
      'setting_time',pr.setting_time,'tool_change_time',pr.tool_change_time,
      'breakdown_time',pr.breakdown_time,'idle_time',pr.idle_time,'remarks',pr.remarks)
      order by pr.section, pr.machine_no)
      from production_rows pr left join part p on p.id=pr.part_id left join lot_master lm on lm.id=pr.lot_id
      where pr.production_id=pl.id), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
      'section',d.section,'machine_no',d.machine_no,'start_time',d.start_time,'end_time',d.end_time,
      'duration_min',d.duration_min,'reason',d.reason,'action_taken',d.action_taken)
      order by d.machine_no) from downtime_log d where d.production_id=pl.id), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
      'section',q.section,'machine_no',q.machine_no,'part_name',qp.part_name,'part_code',qp.part_code,
      'qty_rejected',q.qty_rejected,'rejection_type',q.rejection_type,'defect_type',q.defect_type,
      'root_cause',q.root_cause,'corrective_action',q.corrective_action)
      order by q.machine_no) from quality_log q left join part qp on qp.id=q.part_id
      where q.production_id=pl.id), '[]'::jsonb)
  from production_log pl
  order by pl.log_date desc, pl.created_at desc;
$$ language sql security definer;




-- ---- Production SUMMARY: part x operation x machine ----
create or replace function production_summary(p_from date default null, p_to date default null) returns table(
  part_code text, part_name text, section text, machine_no text,
  op10 numeric, op20 numeric, op30 numeric, days bigint, rejected numeric) as $$
  select p.part_code, p.part_name, pr.section, pr.machine_no,
    coalesce(sum(pr.op10_actual),0), coalesce(sum(pr.op20_actual),0), coalesce(sum(pr.op30_actual),0),
    count(distinct pl.log_date),
    coalesce((select sum(q.qty_rejected) from quality_log q join production_log ql on ql.id=q.production_id
      where q.part_id=pr.part_id and q.machine_no=pr.machine_no
        and (p_from is null or ql.log_date>=p_from) and (p_to is null or ql.log_date<=p_to)),0)
  from production_rows pr
  join production_log pl on pl.id=pr.production_id
  join part p on p.id=pr.part_id
  where pr.part_id is not null
    and (p_from is null or pl.log_date>=p_from) and (p_to is null or pl.log_date<=p_to)
  group by p.part_code, p.part_name, pr.section, pr.machine_no, pr.part_id
  order by p.part_code, pr.machine_no;
$$ language sql security definer;

-- ---- Production SUMMARY: machine-wise (with downtime) ----
create or replace function production_summary_machines(p_from date default null, p_to date default null) returns table(
  section text, machine_no text, parts bigint,
  op10 numeric, op20 numeric, op30 numeric, downtime_min numeric, rejected numeric, days bigint) as $$
  select pr.section, pr.machine_no, count(distinct pr.part_id),
    coalesce(sum(pr.op10_actual),0), coalesce(sum(pr.op20_actual),0), coalesce(sum(pr.op30_actual),0),
    coalesce((select sum(d.duration_min) from downtime_log d join production_log dl on dl.id=d.production_id
      where d.machine_no=pr.machine_no
        and (p_from is null or dl.log_date>=p_from) and (p_to is null or dl.log_date<=p_to)),0),
    coalesce((select sum(q.qty_rejected) from quality_log q join production_log ql on ql.id=q.production_id
      where q.machine_no=pr.machine_no
        and (p_from is null or ql.log_date>=p_from) and (p_to is null or ql.log_date<=p_to)),0),
    count(distinct pl.log_date)
  from production_rows pr
  join production_log pl on pl.id=pr.production_id
  where (p_from is null or pl.log_date>=p_from) and (p_to is null or pl.log_date<=p_to)
  group by pr.section, pr.machine_no
  order by pr.section, pr.machine_no;
$$ language sql security definer;
