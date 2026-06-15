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
