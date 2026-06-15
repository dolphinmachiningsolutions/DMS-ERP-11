-- =====================================================================
--  SPEC PACK 2 (appended last). Implements:
--   - Price-pending Purchase (save, no stock; post on approve; discard on reject)
--   - Averaged RM weight profile per part
--   - DC Out (JW) overdue admin-approval page support
--   - Per-machine #10/#20/#30 enable in machine_config
-- =====================================================================

-- ---- Averaged RM weight profile across all the part's RM vendor rows ----
create or replace function avg_weight_profile(p_part uuid)
returns table(input_weight_pc numeric, output_weight_pc numeric, allowance_pct numeric, qty_variation numeric) as $$
  select coalesce(avg(nullif(input_weight_pc,0)),0),
         coalesce(avg(nullif(output_weight_pc,0)),0),
         coalesce(avg(nullif(allowance_pct,0)),0),
         coalesce(avg(nullif(qty_variation,0)),0)
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
      ln.actual_qty, p_id, 'PURCHASE', v.voucher_no, 'price approved', 0);
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
