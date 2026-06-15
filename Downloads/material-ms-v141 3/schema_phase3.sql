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
