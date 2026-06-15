-- =====================================================================
--  DMS ERP — COMPREHENSIVE TEST RIG  (run on a SCRATCH database only)
--  Paste AFTER schema_v14.sql into a throwaway DB. It seeds its own
--  master data, exercises every business rule from the spec, and prints
--  a maximum-detail PASS/FAIL report with expected-vs-actual, a category
--  breakdown, and a final reconcile/health audit.
--
--  SAFE-BY-DESIGN: intended for a fresh/empty database. It writes test
--  rows; it does NOT clean up after itself (so you can inspect), which is
--  why it must only run on a scratch DB.
-- =====================================================================
\set ON_ERROR_STOP 0

-- result sink as a REAL table (survives even if a block aborts on a scratch DB)
drop table if exists _r;
create table _r(seq serial, category text, name text, pass boolean, expected text, actual text);

do $rig$
declare
  -- master-data handles
  ven_rm  uuid;  ven_rm2 uuid;  ven_jw  uuid;  cust uuid;
  p_main  uuid;  p_two uuid;  p_nopr uuid;
  po_no text; po_id uuid; so_no text; so_id uuid; dc_no text; dc_id uuid;
  r jsonb; v uuid; tmp numeric; tmp2 numeric; tmp_t text; tmp_d date; n int;
  cat text;
begin
  -- ============================================================
  --  SETUP — master data the rig will operate on
  -- ============================================================
  cat := 'SETUP';
  begin
    ven_rm  := admin_save_ledger(null,'Vendor RM','RIG RM Vendor A',null,null,'Local','Active');
    ven_rm2 := admin_save_ledger(null,'Vendor RM','RIG RM Vendor B',null,null,'Local','Active');
    ven_jw  := admin_save_ledger(null,'Vendor JW','RIG JW Coater',null,null,'Local','Active');
    cust    := admin_save_ledger(null,'Customer','RIG Customer',null,null,'Local','Active');
    p_main  := admin_save_part(null,'RIG MAIN PART','RIGM',  'Nos',null,'Active');
    p_two   := admin_save_part(null,'RIG SECOND PART','RIGS','Nos',null,'Active');
    p_nopr  := admin_save_part(null,'RIG NOPRICE PART','RIGN','Nos',null,'Active');
    -- prices: two RM vendors with different weights to test AVERAGING
    perform save_part_price(null,p_main,ven_rm,'purchase',100, current_date-10, current_date+60, 1.2,1.0,5,2);
    perform save_part_price(null,p_main,ven_rm2,'purchase',110,current_date-10, current_date+60, 1.4,1.2,7,4);
    perform save_part_price(null,p_main,cust,'sale',     250, current_date-10, current_date+60, 0,0,0,0);
    perform save_part_price(null,p_two, ven_rm,'purchase', 80, current_date-10, current_date+60, 2.0,1.8,4,3);
    perform save_part_price(null,p_two, cust,'sale',      160, current_date-10, current_date+60, 0,0,0,0);
    insert into _r(category,name,pass,expected,actual) values(cat,'master data created',true,'all handles non-null',
      'rm='||(ven_rm is not null)||' jw='||(ven_jw is not null)||' cust='||(cust is not null)||' part='||(p_main is not null));
  exception when others then
    insert into _r(category,name,pass,expected,actual) values(cat,'master data created',false,'no error',sqlerrm);
  end;

  -- ============================================================
  --  FINANCIAL YEAR + VOUCHER NUMBERING
  -- ============================================================
  cat := 'FY & NUMBERING';
  -- FY compact / dashed for Jun 2026 -> 2627 / 26-27
  insert into _r(category,name,pass,expected,actual) values(cat,'fy_compact(Jun-2026)',
    fy_compact('2026-06-15')='2627','2627',fy_compact('2026-06-15'));
  insert into _r(category,name,pass,expected,actual) values(cat,'fy_dashed(Jun-2026)',
    fy_dashed('2026-06-15')='26-27','26-27',fy_dashed('2026-06-15'));
  -- Jan belongs to previous FY start (Apr 2026 - Mar 2027)
  insert into _r(category,name,pass,expected,actual) values(cat,'fy_compact(Jan-2027) stays 2627',
    fy_compact('2027-01-10')='2627','2627',fy_compact('2027-01-10'));

  -- DCJW fiscal-month mapping: Apr=01, May=02, Jun=03, Dec=09, Jan=10, Mar=12
  insert into _r(category,name,pass,expected,actual) values(cat,'DCJW Apr -> month 01',
    next_dcjw_no('2026-04-05') like 'DDCJ262701%','DDCJ262701xxx',next_dcjw_no('2026-04-05'));
  insert into _r(category,name,pass,expected,actual) values(cat,'DCJW Jun -> month 03',
    next_dcjw_no('2026-06-05') like 'DDCJ262703%','DDCJ262703xxx',next_dcjw_no('2026-06-05'));
  insert into _r(category,name,pass,expected,actual) values(cat,'DCJW Dec -> month 09',
    next_dcjw_no('2026-12-05') like 'DDCJ262709%','DDCJ262709xxx',next_dcjw_no('2026-12-05'));
  insert into _r(category,name,pass,expected,actual) values(cat,'DCJW Mar -> month 12',
    next_dcjw_no('2027-03-05') like 'DDCJ262712%','DDCJ262712xxx',next_dcjw_no('2027-03-05'));
  insert into _r(category,name,pass,expected,actual) values(cat,'DCJW sequence ends 001 when empty',
    next_dcjw_no('2026-06-05') like '%001','...001',next_dcjw_no('2026-06-05'));

  -- RC In (JW) number format CST/00042/26-27
  insert into _r(category,name,pass,expected,actual) values(cat,'rcjw_no pads serial + FY',
    rcjw_no('42','2026-06-05')='CST/00042/26-27','CST/00042/26-27',rcjw_no('42','2026-06-05'));

  -- Valid-through calculators
  insert into _r(category,name,pass,expected,actual) values(cat,'PO valid_thru = 5th next month',
    valid_thru_5th('2026-06-20')='2026-07-05','2026-07-05',valid_thru_5th('2026-06-20')::text);
  insert into _r(category,name,pass,expected,actual) values(cat,'SO valid_thru = end of month',
    valid_thru_eom('2026-06-10')='2026-06-30','2026-06-30',valid_thru_eom('2026-06-10')::text);
  insert into _r(category,name,pass,expected,actual) values(cat,'DC due date = +3 days',
    due_date_3d('2026-06-10')='2026-06-13','2026-06-13',due_date_3d('2026-06-10')::text);

  -- ============================================================
  --  WEIGHT PROFILE AVERAGING (across RM vendors)
  -- ============================================================
  cat := 'WEIGHT PROFILE';
  -- p_main has two RM vendors: input 1.2 & 1.4 -> avg 1.3; allowance 5 & 7 -> 6; qvar 2 & 4 -> 3; output 1.0 & 1.2 -> 1.1
  select input_weight_pc into tmp from avg_weight_profile(p_main);
  insert into _r(category,name,pass,expected,actual) values(cat,'avg input weight (1.2,1.4)->1.3',
    round(tmp,2)=1.30,'1.30',round(tmp,2)::text);
  select allowance_pct into tmp from avg_weight_profile(p_main);
  insert into _r(category,name,pass,expected,actual) values(cat,'avg allowance (5,7)->6',
    round(tmp,2)=6.00,'6.00',round(tmp,2)::text);
  select output_weight_pc into tmp from avg_weight_profile(p_main);
  insert into _r(category,name,pass,expected,actual) values(cat,'avg output weight (1.0,1.2)->1.1',
    round(tmp,2)=1.10,'1.10',round(tmp,2)::text);
  select qty_variation into tmp from avg_weight_profile(p_main);
  insert into _r(category,name,pass,expected,actual) values(cat,'avg qty variation (2,4)->3',
    round(tmp,2)=3.00,'3.00',round(tmp,2)::text);

  -- ============================================================
  --  CORE STOCK FLOW  Purchase->DC->RC->Production->Sales
  -- ============================================================
  cat := 'STOCK FLOW';
  -- PO for 1000 (commitment ledger only, no stock)
  po_no := 'RIG-PO-1';
  r := post_voucher('PURCHASE_ORDER','PO',po_no,current_date,current_date,valid_thru_5th(current_date),
        ven_rm,null,null,18,'rig po','rig', jsonb_build_array(jsonb_build_object('part_id',p_main,'qty',1000,'unit_price',100,'basic_value',100000)));
  insert into _r(category,name,pass,expected,actual) values(cat,'PO posts (no stock move)',
    (r->>'ok')::boolean is not false and check_stock(p_main,'RC')=0,'RC=0 after PO',check_stock(p_main,'RC')::text);

  -- Purchase 900 against PO at PO price -> RC +900
  r := post_voucher('PURCHASE','PUR','RIG-PUR-1',current_date,current_date,null,ven_rm,null,po_no,18,'rig pur','rig',
        jsonb_build_array(jsonb_build_object('part_id',p_main,'ref_no',po_no,'invoice_qty',900,'actual_qty',900,'qty',900,'unit_price',100,'po_price',100,'basic_value',90000)));
  insert into _r(category,name,pass,expected,actual) values(cat,'Purchase 900 -> RC=900',
    check_stock(p_main,'RC')=900,'900',check_stock(p_main,'RC')::text);

  -- PO pending should now be 100 (1000-900) via Actual Qty
  select pending_qty into tmp from open_orders where voucher_no=po_no and part_id=p_main;
  insert into _r(category,name,pass,expected,actual) values(cat,'PO pending = 100 after purchase',
    coalesce(tmp,-1)=100,'100',coalesce(tmp,-1)::text);

  -- DC Out (JW) 400 RC->RCJW
  dc_no := next_dcjw_no(current_date);
  r := post_voucher('DC_OUT_JW','DCO',dc_no,current_date,current_date,due_date_3d(current_date),ven_jw,null,null,18,'rig dc','rig',
        jsonb_build_array(jsonb_build_object('part_id',p_main,'qty',400)));
  insert into _r(category,name,pass,expected,actual) values(cat,'DC Out 400 -> RC=500, RCJW=400',
    check_stock(p_main,'RC')=500 and check_stock(p_main,'RCJW')=400,'RC500/RCJW400',
    check_stock(p_main,'RC')::text||'/'||check_stock(p_main,'RCJW')::text);

  -- RC In (JW) 250 against DC -> RCJW->CC, DC pending 150
  r := post_voucher('RC_IN_JW','RCI',rcjw_no('1',current_date),current_date,current_date,null,ven_jw,null,dc_no,18,'rig rcin','rig',
        jsonb_build_array(jsonb_build_object('part_id',p_main,'ref_no',dc_no,'invoice_qty',250,'actual_qty',250,'qty',250)));
  insert into _r(category,name,pass,expected,actual) values(cat,'RC In 250 -> RCJW=150, CC=250',
    check_stock(p_main,'RCJW')=150 and check_stock(p_main,'CC')=250,'RCJW150/CC250',
    check_stock(p_main,'RCJW')::text||'/'||check_stock(p_main,'CC')::text);
  select pending_qty into tmp from dc_fulfilment where voucher_no=dc_no and part_id=p_main;
  insert into _r(category,name,pass,expected,actual) values(cat,'DC pending = 150 after RC In',
    coalesce(tmp,-1)=150,'150',coalesce(tmp,-1)::text);

  -- Production 200 CC->MG via the dedicated production poster (op10)
  begin
    perform post_production(current_date,'Day','RIG Supervisor',null,'rig',
      jsonb_build_array(jsonb_build_object('section','RIG','machine_no','M1','part_id',p_main,'op10_actual',200)),
      '[]'::jsonb,'[]'::jsonb);
    insert into _r(category,name,pass,expected,actual) values(cat,'Production 200 -> CC=50, MG=200',
      check_stock(p_main,'CC')=50 and check_stock(p_main,'MG')=200,'CC50/MG200',
      check_stock(p_main,'CC')::text||'/'||check_stock(p_main,'MG')::text);
  exception when others then
    insert into _r(category,name,pass,expected,actual) values(cat,'Production 200 -> CC=50, MG=200',false,'CC50/MG200','ERROR: '||left(sqlerrm,60));
  end;

  -- SO then Sales (Local) 120 MG->CUSTOMER
  so_no := 'RIG-SO-1';
  r := post_voucher('SALES_ORDER','SO',so_no,current_date,current_date,valid_thru_eom(current_date),cust,null,null,18,'rig so','rig',
        jsonb_build_array(jsonb_build_object('part_id',p_main,'qty',120,'unit_price',250,'basic_value',30000)));
  r := post_voucher('SALES_LOCAL','SAL','RIG-SAL-1',current_date,current_date,null,cust,null,so_no,18,'rig sal','rig',
        jsonb_build_array(jsonb_build_object('part_id',p_main,'ref_no',so_no,'qty',120,'unit_price',250,'basic_value',30000)));
  insert into _r(category,name,pass,expected,actual) values(cat,'Sales 120 -> MG=80',
    check_stock(p_main,'MG')=80,'80',check_stock(p_main,'MG')::text);

  -- ============================================================
  --  GUARDRAILS — illegal actions must be REFUSED
  -- ============================================================
  cat := 'GUARDRAILS';
  -- Sales beyond stock+buffer must block. MG=80, buffer=250, ceiling 330.
  -- Post 500 (clearly over) and expect a hard block, leaving the book clean.
  begin
    perform post_voucher('SALES_LOCAL','SAL','RIG-OVERSELL',current_date,current_date,null,cust,null,so_no,18,'x','rig',
      jsonb_build_array(jsonb_build_object('part_id',p_main,'ref_no',so_no,'qty',500,'unit_price',250,'basic_value',125000)));
    insert into _r(category,name,pass,expected,actual) values(cat,'sales beyond stock+buffer blocked',false,'exception','posted 500 over buffer (hole!)');
  exception when others then
    insert into _r(category,name,pass,expected,actual) values(cat,'sales beyond stock+buffer blocked',true,'exception raised',left(sqlerrm,55));
  end;
  -- DC Out beyond RC (RC=500) must block
  begin
    perform post_voucher('DC_OUT_JW','DCO',next_dcjw_no(current_date),current_date,current_date,due_date_3d(current_date),ven_jw,null,null,18,'x','rig',
      jsonb_build_array(jsonb_build_object('part_id',p_main,'qty',999999)));
    insert into _r(category,name,pass,expected,actual) values(cat,'DC beyond RC blocked',false,'exception','move SUCCEEDED (hole!)');
  exception when others then
    insert into _r(category,name,pass,expected,actual) values(cat,'DC beyond RC blocked',true,'exception raised',left(sqlerrm,60));
  end;
  -- Direct ledger insert must be sealed
  begin
    insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_type,voucher_no)
      values(current_date,p_main,'VENDOR','RC',10,'PURCHASE','HACK');
    insert into _r(category,name,pass,expected,actual) values(cat,'ledger seal blocks direct insert',false,'exception','insert SUCCEEDED (seal broken!)');
  exception when others then
    insert into _r(category,name,pass,expected,actual) values(cat,'ledger seal blocks direct insert',true,'exception raised',left(sqlerrm,50));
  end;
  -- Voucher disable: turn PURCHASE off, attempt, expect block, then re-enable
  begin
    perform set_voucher_enabled('PURCHASE',false);
    begin
      perform post_voucher('PURCHASE','PUR','RIG-DISABLED',current_date,current_date,null,ven_rm,null,po_no,18,'x','rig',
        jsonb_build_array(jsonb_build_object('part_id',p_main,'ref_no',po_no,'invoice_qty',1,'actual_qty',1,'qty',1,'unit_price',100,'po_price',100,'basic_value',100)));
      insert into _r(category,name,pass,expected,actual) values(cat,'disabled voucher blocked',false,'exception','posted while disabled (hole!)');
    exception when others then
      insert into _r(category,name,pass,expected,actual) values(cat,'disabled voucher blocked',true,'exception raised',left(sqlerrm,50));
    end;
    perform set_voucher_enabled('PURCHASE',true);
  end;

  -- ============================================================
  --  PRICE-PENDING LIFECYCLE
  -- ============================================================
  cat := 'PRICE PENDING';
  tmp := check_stock(p_two,'RC');
  -- purchase p_two at price <> PO price, flagged price_pending -> NO stock
  r := post_voucher('PURCHASE','PUR','RIG-PP-1',current_date,current_date,null,ven_rm,null,null,18,'pp','rig',
        jsonb_build_array(jsonb_build_object('part_id',p_two,'invoice_qty',50,'actual_qty',50,'qty',50,'unit_price',95,'po_price',80,'basic_value',4750)), true);
  v := (r->>'id')::uuid;
  insert into _r(category,name,pass,expected,actual) values(cat,'price-pending posts NO stock',
    check_stock(p_two,'RC')=tmp,'RC unchanged ('||tmp||')',check_stock(p_two,'RC')::text);
  select count(*) into n from price_pending_full() where id=v;
  insert into _r(category,name,pass,expected,actual) values(cat,'appears in price-approval queue',
    n=1,'1',n::text);
  -- approve -> stock now posts
  r := approve_price_post(v,'rig');
  insert into _r(category,name,pass,expected,actual) values(cat,'approve posts stock (+50)',
    check_stock(p_two,'RC')=tmp+50,(tmp+50)::text,check_stock(p_two,'RC')::text);
  -- reject path: new pending then reject -> discarded, no stock
  tmp2 := check_stock(p_two,'RC');
  r := post_voucher('PURCHASE','PUR','RIG-PP-2',current_date,current_date,null,ven_rm,null,null,18,'pp2','rig',
        jsonb_build_array(jsonb_build_object('part_id',p_two,'invoice_qty',30,'actual_qty',30,'qty',30,'unit_price',70,'po_price',80,'basic_value',2100)), true);
  v := (r->>'id')::uuid;
  r := reject_price(v,'rig');
  select count(*) into n from vouchers where id=v;
  insert into _r(category,name,pass,expected,actual) values(cat,'reject discards voucher',
    n=0 and check_stock(p_two,'RC')=tmp2,'voucher gone, RC unchanged','rows='||n||' RC='||check_stock(p_two,'RC'));

  -- ============================================================
  --  OVERDUE DC OUT (JW)
  -- ============================================================
  cat := 'OVERDUE DC';
  -- craft an overdue, still-pending DC via the gate (past due date)
  declare odc uuid;
  begin
    insert into vouchers(voucher_type,voucher_id_code,voucher_no,voucher_date,valid_thru,ledger_id,created_by,status)
      values('DC_OUT_JW',next_voucher_idcode('DC_OUT_JW'),'RIG-ODC-1',current_date-10,current_date-7,ven_jw,'rig','OPEN') returning id into odc;
    insert into voucher_lines(voucher_id,sno,part_id,qty,uom) values(odc,1,p_main,50,'Nos');
    perform set_config('app.stock_gate','on',true);
    insert into stock_ledger(ledger_date,part_id,from_location,to_location,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
      values(current_date-10,p_main,default_location(),default_location(),'RC','RCJW',50,odc,'DC_OUT_JW','RIG-ODC-1');
    perform set_config('app.stock_gate','off',true);
    perform recache_cell(p_main,default_location(),'RC'); perform recache_cell(p_main,default_location(),'RCJW');
    select count(*) into n from overdue_dcjw();
    insert into _r(category,name,pass,expected,actual) values(cat,'overdue DC detected',n>=1,'>=1',n::text);
    -- new DC must be blocked while overdue exists
    begin
      perform dcjw_overdue_block(ven_jw);
      insert into _r(category,name,pass,expected,actual) values(cat,'new DC blocked while overdue',false,'exception','not blocked (hole!)');
    exception when others then
      insert into _r(category,name,pass,expected,actual) values(cat,'new DC blocked while overdue',true,'exception raised',left(sqlerrm,50));
    end;
    -- admin clears, then allowed
    perform clear_overdue_dcjw(odc,'admin');
    begin
      perform dcjw_overdue_block(ven_jw);
      insert into _r(category,name,pass,expected,actual) values(cat,'after clear, DC allowed',true,'no exception','allowed');
    exception when others then
      insert into _r(category,name,pass,expected,actual) values(cat,'after clear, DC allowed',false,'no exception',sqlerrm);
    end;
  end;

  -- ============================================================
  --  LEDGERS
  -- ============================================================
  cat := 'LEDGERS';
  -- Part ledger for p_main / RC: +900 purchase, -400 DC, and -50 from the
  -- overdue-DC fixture (RIG-ODC-1) created earlier => running 450.
  select running into tmp from part_ledger_full(p_main,'RC') order by seq desc limit 1;
  insert into _r(category,name,pass,expected,actual) values(cat,'part ledger RC closing = 450',
    coalesce(tmp,-1)=450,'450',coalesce(tmp,-1)::text);
  -- first row is opening balance
  select voucher_type into tmp_t from part_ledger_full(p_main,'RC') order by seq limit 1;
  insert into _r(category,name,pass,expected,actual) values(cat,'part ledger first row = opening',
    tmp_t='OPENING BALANCE','OPENING BALANCE',tmp_t);
  -- stock ledger journal returns rows for p_main
  select count(*) into n from stock_ledger_full(p_main,null,null);
  insert into _r(category,name,pass,expected,actual) values(cat,'stock ledger journal non-empty',
    n>0,'>0',n::text);
  -- filter by voucher type works
  select count(*) into n from stock_ledger_full(null,null,'PURCHASE');
  insert into _r(category,name,pass,expected,actual) values(cat,'stock ledger filter by type',
    n>0,'>0',n::text);

  -- ============================================================
  --  DASHBOARD METRICS
  -- ============================================================
  cat := 'DASHBOARD';
  begin
    perform dashboard_metrics();
    insert into _r(category,name,pass,expected,actual) values(cat,'dashboard_metrics runs',true,'no error','ran');
  exception when others then
    insert into _r(category,name,pass,expected,actual) values(cat,'dashboard_metrics runs',false,'no error',sqlerrm);
  end;

  -- ============================================================
  --  MULTI-LOCATION (per-location balances, allow-list, transfer)
  -- ============================================================
  cat := 'MULTI-LOCATION';
  declare mloc uuid; floc uuid; mrc numeric; frc numeric; xfer jsonb;
  begin
    mloc := default_location();
    -- a second location that allows only RC, CC, MG
    floc := save_location(null,'RIGFL','Rig Floor','Active',5);
    perform set_location_buckets(floc, array['RC','CC','MG']);
    -- purchase 200 RC into Main for p_two (capture pre-existing balance first)
    declare pre_rc numeric; begin
    pre_rc := check_stock(p_two,'RC');
    perform post_voucher('PURCHASE','PUR','RIG-ML-1',current_date,current_date,null,ven_rm,null,null,18,'ml','rig',
      jsonb_build_array(jsonb_build_object('part_id',p_two,'invoice_qty',200,'actual_qty',200,'qty',200,'unit_price',80,'po_price',80,'basic_value',16000)), false, mloc);
    mrc := check_stock_loc(p_two,mloc,'RC'); frc := check_stock_loc(p_two,floc,'RC');
    insert into _r(category,name,pass,expected,actual) values(cat,'purchase lands at chosen location only',
      mrc>=200 and frc=0,'Main>=200, Floor=0','Main='||mrc||' Floor='||frc);
    end;
    -- allow-list: purchasing RC at a location without RC must be blocked
    declare noloc uuid; begin
      noloc := save_location(null,'RIGNO','Rig NoRC','Active',6);
      perform set_location_buckets(noloc, array['MG']);  -- RC not allowed
      begin
        perform post_voucher('PURCHASE','PUR','RIG-ML-2',current_date,current_date,null,ven_rm,null,null,18,'x','rig',
          jsonb_build_array(jsonb_build_object('part_id',p_two,'invoice_qty',5,'actual_qty',5,'qty',5,'unit_price',80,'po_price',80,'basic_value',400)), false, noloc);
        insert into _r(category,name,pass,expected,actual) values(cat,'allow-list blocks disallowed bucket',false,'exception','posted (hole!)');
      exception when others then
        insert into _r(category,name,pass,expected,actual) values(cat,'allow-list blocks disallowed bucket',true,'exception raised',left(sqlerrm,45));
      end;
    end;
    -- stock transfer Main -> Floor (120 RC)
    xfer := post_stock_transfer(current_date,p_two,'RC',mloc,floc,120,'rig','rig xfer');
    mrc := check_stock_loc(p_two,mloc,'RC'); frc := check_stock_loc(p_two,floc,'RC');
    insert into _r(category,name,pass,expected,actual) values(cat,'transfer moves qty between locations',
      frc=120,'Floor=120','Floor='||frc);
    insert into _r(category,name,pass,expected,actual) values(cat,'transfer conserves total',
      (mrc+frc)=check_stock(p_two,'RC'),check_stock(p_two,'RC')::text,(mrc+frc)::text);
    -- over-transfer must block
    begin
      perform post_stock_transfer(current_date,p_two,'RC',mloc,floc,99999,'rig','x');
      insert into _r(category,name,pass,expected,actual) values(cat,'over-transfer blocked',false,'exception','moved (hole!)');
    exception when others then
      insert into _r(category,name,pass,expected,actual) values(cat,'over-transfer blocked',true,'exception raised',left(sqlerrm,45));
    end;
    -- aggregate check_stock equals sum across locations
    insert into _r(category,name,pass,expected,actual) values(cat,'aggregate check_stock = sum of locations',
      check_stock(p_two,'RC')=(mrc+frc),(mrc+frc)::text,check_stock(p_two,'RC')::text);
  end;

  -- ============================================================
  --  DATA INTEGRITY INVARIANTS
  -- ============================================================
  cat := 'INTEGRITY';
  -- no negative balances anywhere
  select count(*) into n from stock_cache where bal < 0;
  insert into _r(category,name,pass,expected,actual) values(cat,'no negative balances',
    n=0,'0',n::text);
  -- cache integrity: use the engine's own authoritative reconcile (gross+var vs cache).
  -- Zero drift rows across the WHOLE database is the correct invariant.
  select count(*) into n from reconcile_stock();
  insert into _r(category,name,pass,expected,actual) values(cat,'cache reconciles to ledger (all parts)',
    n=0,'0 drift rows',n::text||' drift rows');

  -- ============================================================
  --  FINAL ENGINE HEALTH / RECONCILE AUDIT
  -- ============================================================
  cat := 'HEALTH AUDIT';
  for tmp_t, tmp2 in select check_name, (case when status='OK' then 1 else 0 end) from engine_health() loop
    insert into _r(category,name,pass,expected,actual) values(cat,'engine_health: '||tmp_t, tmp2=1,'OK',case when tmp2=1 then 'OK' else 'FAIL' end);
  end loop;
  select count(*) into n from reconcile_stock();
  insert into _r(category,name,pass,expected,actual) values(cat,'reconcile: zero drift rows',
    n=0,'0',n::text);

end $rig$;

-- =====================================================================
--  REPORT
-- =====================================================================
\echo ''
\echo '================ DMS ERP — TEST RIG REPORT ================'
\echo ''
\echo '---- DETAIL (every assertion) ----'
select seq as "#", category, name as test,
  case when pass then 'PASS' else 'FAIL' end as result,
  expected, actual
from _r order by seq;

\echo ''
\echo '---- CATEGORY BREAKDOWN ----'
select category,
  count(*) filter (where pass) as passed,
  count(*) filter (where not pass) as failed,
  count(*) as total
from _r group by category order by min(seq);

\echo ''
\echo '---- FAILURES ONLY ----'
select category, name as failed_test, expected, actual from _r where not pass order by seq;

\echo ''
\echo '---- GRAND TOTAL ----'
select count(*) filter (where pass) as passed,
       count(*) filter (where not pass) as failed,
       count(*) as total,
       round(100.0*count(*) filter (where pass)/nullif(count(*),0),1) as pass_pct
from _r;
