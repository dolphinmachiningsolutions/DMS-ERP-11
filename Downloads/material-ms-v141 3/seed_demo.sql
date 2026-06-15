-- =====================================================================
--  DEMO SEED — run AFTER schema_v14.sql to populate a realistic
--  Stock Summary. Creates ledgers, parts (BRKT MTG / BRKT BEARING),
--  opening stock, and a batch of Purchases + DC Out + Production so the
--  exploded grid shows live numbers. Safe to re-run is NOT guaranteed —
--  run once on a fresh DB.
-- =====================================================================
do $$
declare
  v_rmv uuid; v_cust uuid; v_jw uuid;
  pid uuid; po_id uuid;
  parts text[] := array[
    'BRKT MTG BI3 LH','BRKT MTG BI3 RH','BRKT MTG BJ1 LH','BRKT MTG BJ1 RH',
    'BRKT MTG SP2I LH','BRKT MTG SP2I RH','BRKT MTG SU2I LH','BRKT MTG SU2I RH',
    'BRKT MTG SU2I LWB LH','BRKT MTG SU2I LWB RH','BRKT BEARING QU2I CC000',
    'BRKT BEARING QU2I CC100','BRKT BEARING QU2I CC200','BRKT BEARING QU2I CC300',
    'BRKT BEARING SP3I BM150','BRKT BEARING SP3I BM200','BRKT HINGE DH1 LH',
    'BRKT HINGE DH1 RH','BRKT HINGE DH2 LH','BRKT HINGE DH2 RH',
    'PLATE TORQUE TP1','PLATE TORQUE TP2','COVER REAR CR1','COVER REAR CR2',
    'HOUSING GEAR GH1','HOUSING GEAR GH2'];
  openings int[] := array[0,2,0,0,4,1,13,9,0,1,0,0,8,742,0,3,0,0,5,0,11,0,0,2,0,6];
  purch    int[] := array[570,630,9123,8922,28246,28128,1580,1780,1400,1900,5873,1051,16537,1400,5105,2200,3400,3100,900,1200,4500,3800,2600,1500,7200,4100];
  i int;
begin
  -- ledgers
  insert into ledger(ledger_type,ledger_code,ledger_name,tax,status) values
    ('Vendor RM', next_ledger_code('Vendor RM'),'Sundaram Castings','Local','Active') returning id into v_rmv;
  insert into ledger(ledger_type,ledger_code,ledger_name,tax,status) values
    ('Customer', next_ledger_code('Customer'),'Ashok Leyland','Local','Active') returning id into v_cust;
  insert into ledger(ledger_type,ledger_code,ledger_name,tax,status) values
    ('Vendor JW', next_ledger_code('Vendor JW'),'Precision Coaters','Local','Active') returning id into v_jw;

  for i in 1..array_length(parts,1) loop
    insert into part(part_code,part_name,uom,status)
    values(next_part_code(), parts[i]||' '||('{RMV5,RMV5,RMV3,RMV3,RMV3,RMV3,RMV4,RMV4,RMV4,RMV4,RMV3,RMV3,RMV3,RMV3,RMV3,RMV3,RMV2,RMV2,RMV2,RMV2,RMV1,RMV1,RMV6,RMV6,RMV7,RMV7}'::text[])[i],
      'Nos', 'Active') returning id into pid;
    -- price + per-vendor weights on the purchase row; sale price for customer
    insert into part_price(part_id,ledger_id,price_type,unit_price,valid_from,input_weight_pc,output_weight_pc,scrap_weight_pc,allowance_pct,qty_variation) values
      (pid, v_rmv,'purchase', 50+i, current_date-30, 1.2,1.05,0.15,5,2);
    insert into part_price(part_id,ledger_id,price_type,unit_price,valid_from) values
      (pid, v_cust,'sale', 120+i, current_date-30);
    -- opening
    if openings[i] > 0 then
      insert into opening_stock(part_id,bucket,qty) values(pid,'RC',openings[i]) on conflict do nothing;
    end if;
    -- a purchase into RC (direct ledger insert to keep seed simple & fast)
    insert into vouchers(voucher_type,voucher_id_code,voucher_no,voucher_date,ledger_id,created_by,status)
    values('PURCHASE', next_voucher_idcode('PURCHASE'), 'SEED-PUR-'||i, current_date-20, v_rmv,'seed','OPEN') returning id into po_id;
    insert into voucher_lines(voucher_id,sno,part_id,qty,actual_qty,uom,unit_price,basic_value)
    values(po_id,1,pid,purch[i],purch[i],'Nos',50+i,(50+i)*purch[i]);
    perform post_stock_move(current_date-20,pid,'VENDOR','RC',purch[i],po_id,'PURCHASE','SEED-PUR-'||i,'seed purchase',0);

    -- DC Out (JW): send the PURCHASED qty out, leaving any OPENING behind in RC
    -- (this reproduces the screenshot where Grs Bal == opening for several parts)
    declare dc_id uuid; dcqty int := purch[i];
    begin
      if dcqty > 0 then
        insert into vouchers(voucher_type,voucher_id_code,voucher_no,voucher_date,ledger_id,created_by,status)
        values('DC_OUT_JW', next_voucher_idcode('DC_OUT_JW'),'SEED-DC-'||i, current_date-10, v_jw,'seed','OPEN') returning id into dc_id;
        insert into voucher_lines(voucher_id,sno,part_id,qty,uom) values(dc_id,1,pid,dcqty,'Nos');
        perform post_stock_move(current_date-10,pid,'RC','RCJW',dcqty,dc_id,'DC_OUT_JW','SEED-DC-'||i,'seed dc',0);
      end if;
    end;
  end loop;
end $$;
