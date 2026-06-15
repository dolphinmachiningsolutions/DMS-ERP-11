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
declare mm text; fy text; seq int; prefix text;
begin
  fy := fy_compact(p_date);
  mm := to_char(p_date,'MM');
  prefix := 'DCJ'||fy||mm;
  select coalesce(max(substring(voucher_no from '...$')::int),0)+1 into seq
  from vouchers where voucher_type='DC_OUT_JW' and voucher_no like prefix||'%';
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
