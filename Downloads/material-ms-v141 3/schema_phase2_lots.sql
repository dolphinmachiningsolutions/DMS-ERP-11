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
