-- =====================================================================
--  DMS ERP — FACTORY RESET (ERASES *EVERYTHING*)
-- =====================================================================
--  Wipes ALL data: vouchers, stock, lots, production, parts, ledgers,
--  prices, locations, users — everything. Then restores fresh-install
--  state: default buckets, settings, Main Store location, and the
--  admin/admin123 user.
--
--  >>> THIS CANNOT BE UNDONE. BACK UP FIRST. <<<
--  (Supabase Dashboard -> Database -> Backups, or pg_dump)
--
--  SAFETY LATCH: nothing runs unless you uncomment the SET line below.
--  The entire wipe is inside ONE guarded block - if the latch is not
--  armed, the block aborts and NOTHING is touched.
-- =====================================================================

-- UNCOMMENT THE NEXT LINE TO ARM THE RESET:
-- set session app.confirm_factory_reset = 'ERASE-EVERYTHING';

do $factory_reset$
declare lid uuid;
begin
  -- ---- safety latch ----
  if coalesce(current_setting('app.confirm_factory_reset', true), '') <> 'ERASE-EVERYTHING' then
    raise exception E'FACTORY RESET ABORTED (safety latch).\nTo really erase everything, uncomment the "set session app.confirm_factory_reset" line at the top and run again.';
  end if;

  -- ---- 1) wipe everything ----
  execute 'truncate table
    audit_log, downtime_log, quality_log, production_rows, production_log,
    lot_ledger, lot_master, stock_variance, physical_stock, period_opening,
    period_lock, opening_stock, stock_cache, stock_ledger, voucher_lines,
    vouchers, part_price, part, part_group, ledger, supervisor, machine_config,
    defect_type, location_bucket, location, bucket_map, buckets,
    ui_column_config, voucher_enabled, checkbox_perms, user_module_rights,
    app_users, app_settings
  restart identity cascade';

  -- ---- 2) restore fresh-install state ----
  insert into app_settings(key,value) values ('lot_enabled','true'), ('lot_mandatory','false');

  insert into buckets(code,name,is_external) values
   ('RC','Raw Casting',false),('RCJW','RC@JW',false),('CC','Coated Casting',false),
   ('MG','Machined Goods',false),('PR','Process Rejection',false),('MR','Material Rejection',false),
   ('JOBOUT','Sent Out (expected back)',false),
   ('VENDOR','Vendor',true),('CUSTOMER','Customer',true),('DCNOUT','Sent Out (non-returnable)',true);

  insert into bucket_map(voucher_type,from_bucket,to_bucket,note) values
   ('PURCHASE','VENDOR','RC','+RC -PO'),
   ('DEBIT_NOTE_RC','RC','VENDOR','-RC'),
   ('DC_OUT_JW','RC','RCJW','-RC +RCJW'),
   ('RC_IN_JW','RCJW','CC','-RCJW +CC'),
   ('PRODUCTION','CC','MG','-CC +MG'),
   ('SALES_LOCAL','MG','CUSTOMER','-MG -SO'),
   ('CREDIT_NOTE','CUSTOMER',null,'sales return: per-line disposition -> PR/MR/MG'),
   ('PROCESS_REJECTION','MG','PR','-MG +PR'),
   ('SCRAP_SALES','PR','CUSTOMER','-PR'),
   ('MATERIAL_REJECTION','MG','MR','-MG +MR'),
   ('DEBIT_NOTE_DN','MR','VENDOR','-MR'),
   ('DC_OUT_RET',null,'JOBOUT','source -> JOBOUT (returnable)'),
   ('DC_OUT_REPLACE',null,'JOBOUT','source -> JOBOUT (replacement)'),
   ('DC_OUT_NONRET',null,'DCNOUT','source -> out (permanent subtract)'),
   ('RC_IN_RET','JOBOUT',null,'JOBOUT -> source (returnable)'),
   ('RC_IN_REPLACE','JOBOUT',null,'JOBOUT -> user-picked bucket (replacement)');

  insert into location(loc_code,loc_name,status,is_default,sort_order)
    values('MAIN','Main Store','Active',true,0) returning id into lid;
  insert into location_bucket(location_id,bucket)
    select lid, code from buckets where is_external=false;

  perform create_app_user('admin','admin123','admin');

  raise notice 'FACTORY RESET COMPLETE. Fresh-install state restored (login: admin / admin123).';
end $factory_reset$;
