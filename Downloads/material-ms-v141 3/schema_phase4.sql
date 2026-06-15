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
