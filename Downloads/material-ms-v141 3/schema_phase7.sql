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
