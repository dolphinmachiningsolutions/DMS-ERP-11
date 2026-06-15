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

create or replace function admin_save_part(p_id uuid, p_name text, p_number text, p_uom text, p_group uuid, p_status text)
returns uuid as $$
declare i uuid; begin
  if p_id is null then
    insert into part(part_code,part_name,part_number,uom,part_group_id,status)
    values(next_part_code(),p_name,nullif(p_number,''),coalesce(p_uom,'Nos'),p_group,coalesce(p_status,'Active')) returning id into i;
  else
    update part set part_name=p_name,part_number=nullif(p_number,''),uom=p_uom,part_group_id=p_group,status=p_status where id=p_id returning id into i;
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
  p_inw numeric, p_outw numeric, p_allow numeric, p_qvar numeric) returns uuid as $$
declare i uuid; begin
  if p_id is null then
    insert into part_price(part_id,ledger_id,price_type,unit_price,valid_from,valid_upto,
      input_weight_pc,output_weight_pc,scrap_weight_pc,allowance_pct,qty_variation)
    values(p_part,p_ledger,p_type,p_price,p_from,p_upto,
      coalesce(p_inw,0),coalesce(p_outw,0),greatest(coalesce(p_inw,0)-coalesce(p_outw,0),0),coalesce(p_allow,0),coalesce(p_qvar,0))
    returning id into i;
  else
    update part_price set ledger_id=p_ledger,unit_price=p_price,valid_from=p_from,valid_upto=p_upto,
      input_weight_pc=coalesce(p_inw,0),output_weight_pc=coalesce(p_outw,0),
      scrap_weight_pc=greatest(coalesce(p_inw,0)-coalesce(p_outw,0),0),allowance_pct=coalesce(p_allow,0),qty_variation=coalesce(p_qvar,0)
    where id=p_id returning id into i;
  end if; return i; end; $$ language plpgsql security definer;
create or replace function delete_part_price(p_id uuid) returns void as $$ delete from part_price where id=p_id; $$ language sql security definer;
create or replace function list_part_prices(p_type text) returns table(
  id uuid, part_id uuid, part_code text, part_name text, ledger_id uuid, ledger_name text,
  unit_price numeric, valid_from date, valid_upto date,
  input_weight_pc numeric, output_weight_pc numeric, scrap_weight_pc numeric, allowance_pct numeric, qty_variation numeric, active_now boolean) as $$
  select pp.id, pp.part_id, p.part_code, p.part_name, pp.ledger_id, l.ledger_name,
    pp.unit_price, pp.valid_from, pp.valid_upto,
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
  posting_period text, posting_date date, ledger_name text, total_qty numeric, total_value numeric,
  status text, generated boolean, cancelled boolean, rec_copy boolean, gstr1 boolean, gstr2b boolean,
  approved_mgmt text, approved_acc boolean, delete_requested boolean, modify_requested boolean) as $$
  select v.id,v.voucher_id_code,v.voucher_no,v.voucher_period,v.voucher_date,
    to_char(coalesce(v.posting_date,v.voucher_date),'Mon YYYY'),v.posting_date,l.ledger_name,
    coalesce((select sum(qty) from voucher_lines x where x.voucher_id=v.id),0),
    coalesce((select sum(basic_value) from voucher_lines x where x.voucher_id=v.id),0),
    v.status,v.generated,v.cancelled,v.rec_copy,v.gstr1,v.gstr2b,v.approved_mgmt,v.approved_acc,
    v.delete_requested,v.modify_requested
  from vouchers v left join ledger l on l.id=v.ledger_id where v.voucher_type=p_type order by v.created_at desc;
$$ language sql;

-- RLS for the new tables
do $$ declare t text; begin
  foreach t in array array['voucher_enabled','ui_column_config'] loop
    execute format('alter table %I enable row level security;',t);
    execute format('drop policy if exists pol_%s on %I;',t,t);
    execute format('create policy pol_%s on %I for all using(true) with check(true);',t,t);
  end loop; end $$;
