-- =====================================================================
--  ADVERSARIAL TEST HARNESS for the stock engine.
--  Run AFTER schema_v14.sql on a database (ideally fresh, no real data).
--  Each test tries to BREAK a guarantee. Expected result: the engine
--  refuses every illegal action and stays perfectly reconciled.
--  Output: a table of PASS / FAIL. Any FAIL = a hole to fix.
-- =====================================================================
do $$
declare loc uuid;
  tp uuid; v uuid; ok boolean; msg text; rid uuid; b1 numeric; b2 numeric;
  results text := '';
  procedure_note text;
begin
  create temp table _t(name text, pass boolean, detail text) on commit drop;

  -- a throwaway part to attack
  loc := default_location();
  insert into part(part_code,part_name,uom,status) values(next_part_code(),'TEST ENGINE PART','Nos','Active') returning id into tp;
  insert into opening_stock(part_id,location_id,bucket,qty) values(tp,loc,'RC',100) on conflict do nothing;
  perform recache_cell(tp,loc,'RC');
  insert into vouchers(voucher_type,voucher_id_code,voucher_no,voucher_date,created_by) values('PURCHASE',next_voucher_idcode('PURCHASE'),'TEST-V1',current_date,'test') returning id into v;

  -- T1: direct INSERT into stock_ledger must be REFUSED (seal)
  begin
    insert into stock_ledger(ledger_date,part_id,from_location,to_location,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
    values(current_date,tp,null,loc,'VENDOR','RC',10,v,'PURCHASE','HACK');
    insert into _t values('T1 seal blocks direct insert', false, 'direct insert SUCCEEDED — seal broken');
  exception when others then insert into _t values('T1 seal blocks direct insert', true, sqlerrm); end;

  -- T2: legitimate move via gate must SUCCEED and update cache
  begin
    rid := post_stock_move(current_date,tp,'VENDOR','RC',50,v,'PURCHASE','TEST-V1','t2',0,null,loc);
    b1 := check_stock_loc(tp,loc,'RC');
    insert into _t values('T2 gate move succeeds', (rid is not null and b1=150), 'RC now '||b1);
  exception when others then insert into _t values('T2 gate move succeeds', false, sqlerrm); end;

  -- T3: move that would drive a bucket NEGATIVE must be REFUSED
  begin
    perform post_stock_move(current_date,tp,'RC','RCJW',99999,v,'DC_OUT_JW','TEST-NEG','t3',0,loc,loc);
    insert into _t values('T3 negative blocked', false, 'oversize move SUCCEEDED — negative allowed');
  exception when others then insert into _t values('T3 negative blocked', true, sqlerrm); end;

  -- T4: qty <= 0 must be REFUSED (constraint + guard)
  begin
    perform post_stock_move(current_date,tp,'RC','RCJW',0,v,'DC_OUT_JW','TEST-ZERO','t4',0,loc,loc);
    insert into _t values('T4 zero/neg qty blocked', false, 'qty 0 accepted');
  exception when others then insert into _t values('T4 zero/neg qty blocked', true, sqlerrm); end;

  -- T5: from = to must be REFUSED
  begin
    perform post_stock_move(current_date,tp,'RC','RC',5,v,'X','TEST-SAME','t5',0,loc,loc);
    insert into _t values('T5 same-bucket blocked', false, 'from=to accepted');
  exception when others then insert into _t values('T5 same-bucket blocked', true, sqlerrm); end;

  -- T6: UPDATE of a posted movement must be REFUSED (immutability)
  begin
    update stock_ledger set qty=qty+1 where voucher_id=v;
    insert into _t values('T6 update blocked', false, 'UPDATE succeeded — not immutable');
  exception when others then insert into _t values('T6 update blocked', true, sqlerrm); end;

  -- T7: DELETE of a posted movement must be REFUSED (immutability)
  begin
    delete from stock_ledger where voucher_id=v;
    insert into _t values('T7 delete blocked', false, 'DELETE succeeded — not immutable');
  exception when others then insert into _t values('T7 delete blocked', true, sqlerrm); end;

  -- T8: controlled purge (cancel path) MUST work and recache correctly
  begin
    b1 := check_stock_loc(tp,loc,'RC');               -- 150
    perform purge_voucher_moves(v);                   -- removes the +50 move
    b2 := check_stock_loc(tp,loc,'RC');               -- back to 100
    insert into _t values('T8 controlled purge + recache', (b1=150 and b2=100), 'before '||b1||' after '||b2);
  exception when others then insert into _t values('T8 controlled purge + recache', false, sqlerrm); end;

  -- T9: cache must equal ledger everywhere (no drift)
  insert into _t values('T9 zero cache drift', not exists(select 1 from reconcile_stock()),
    coalesce((select string_agg(part_code||'/'||bucket||' drift '||drift,', ') from reconcile_stock()),'clean'));

  -- T10: no negative balances anywhere
  insert into _t values('T10 no negative balances', not exists(select 1 from audit_negatives()),
    coalesce((select string_agg(part_code||'/'||bucket||'='||bal,', ') from audit_negatives()),'clean'));

  -- T11: tampering with the cache is detected by the auditor
  begin
    update stock_cache set bal=bal+999 where part_id=tp and location_id=loc and bucket='RC';
    insert into _t values('T11 auditor catches tampering', exists(select 1 from reconcile_stock()), 'drift detected as expected');
    perform recache_cell(tp,loc,'RC');  -- self-heal
    insert into _t values('T11b recache self-heals', not exists(select 1 from reconcile_stock() where part_id=tp), 'healed');
  exception when others then insert into _t values('T11 auditor catches tampering', false, sqlerrm); end;

  -- cleanup test part's moves & rows so the DB is left clean
  perform purge_voucher_moves(v);
  delete from vouchers where id=v;
  delete from opening_stock where part_id=tp;
  delete from part where id=tp;
  perform recache_all();

  -- print results
  raise notice '================ STOCK ENGINE TEST RESULTS ================';
  for procedure_note in select (case when pass then 'PASS' else '*** FAIL ***' end)||'  '||name||'   ['||detail||']' from _t order by name loop
    raise notice '%', procedure_note;
  end loop;
  raise notice '===========================================================';
  if exists(select 1 from _t where not pass) then
    raise notice 'RESULT: ONE OR MORE TESTS FAILED — engine has a hole.';
  else
    raise notice 'RESULT: ALL TESTS PASSED — engine holds.';
  end if;
end $$;
