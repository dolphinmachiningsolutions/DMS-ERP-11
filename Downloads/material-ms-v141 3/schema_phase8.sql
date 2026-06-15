-- =====================================================================
--  DMS ERP V13.0 — PHASE 8: FULL PRODUCTION MODULE
--  Run AFTER schema_phase7.sql.
--  Production header + machine grid rows (OP10/20/30), with OP10 only
--  moving CC -> WIPFG. Downtime & Quality sub-logs keyed to a header.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists production_log (
  id uuid primary key default gen_random_uuid(),
  log_period text,
  log_date date not null default current_date,
  shift text,
  supervisor_1 text not null,
  supervisor_2 text,
  created_by text,
  created_at timestamptz default now()
);

create table if not exists production_rows (
  id uuid primary key default gen_random_uuid(),
  production_id uuid references production_log(id) on delete cascade,
  section text,
  machine_no text,
  operator text,
  part_id uuid references parts(id),
  lot_id uuid references lot_master(id),
  op10_actual numeric default 0,
  op20_actual numeric default 0,
  op30_actual numeric default 0,
  setting_time numeric default 0,
  tool_change_time numeric default 0,
  breakdown_time numeric default 0,
  idle_time numeric default 0,
  remarks text
);

create table if not exists downtime_log (
  id uuid primary key default gen_random_uuid(),
  production_id uuid references production_log(id) on delete cascade,
  log_date date,
  section text,
  machine_no text,
  start_time text,
  end_time text,
  duration_min numeric,
  reason text,
  action_taken text,
  created_at timestamptz default now()
);

create table if not exists quality_log (
  id uuid primary key default gen_random_uuid(),
  production_id uuid references production_log(id) on delete cascade,
  log_date date,
  section text,
  machine_no text,
  part_id uuid references parts(id),
  qty_rejected numeric,
  rejection_type text,
  defect_type text,
  root_cause text,
  corrective_action text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 2. post_production — header + rows + sub-logs in one call.
--    Only OP10 > 0 moves stock CC -> WIPFG (checked against CC BAL),
--    and consumes the chosen lot CC -> WIPFG when a lot is given.
--    p_rows:     [{section,machine_no,operator,part_id,lot_id,op10_actual,op20_actual,op30_actual,
--                  setting_time,tool_change_time,breakdown_time,idle_time,remarks}]
--    p_downtime: [{section,machine_no,start_time,end_time,duration_min,reason,action_taken}]
--    p_quality:  [{section,machine_no,part_id,qty_rejected,rejection_type,defect_type,root_cause,corrective_action}]
-- ---------------------------------------------------------------------
create or replace function post_production(
  p_date date, p_shift text, p_sup1 text, p_sup2 text, p_user text,
  p_rows jsonb, p_downtime jsonb, p_quality jsonb
) returns uuid as $$
declare
  h_id uuid; r jsonb; pid uuid; lid uuid; op10 numeric; cc numeric; lbal numeric;
begin
  if p_sup1 is null or length(trim(p_sup1)) = 0 then
    raise exception 'Supervisor 1 is required.';
  end if;

  insert into production_log(log_period,log_date,shift,supervisor_1,supervisor_2,created_by)
  values (to_char(p_date,'Mon YYYY'), p_date, p_shift, p_sup1, p_sup2, p_user)
  returning id into h_id;

  -- machine rows
  for r in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    pid  := nullif(r->>'part_id','')::uuid;
    lid  := nullif(r->>'lot_id','')::uuid;
    op10 := coalesce((r->>'op10_actual')::numeric,0);

    insert into production_rows(production_id,section,machine_no,operator,part_id,lot_id,
      op10_actual,op20_actual,op30_actual,setting_time,tool_change_time,breakdown_time,idle_time,remarks)
    values (h_id, r->>'section', r->>'machine_no', r->>'operator', pid, lid,
      op10, coalesce((r->>'op20_actual')::numeric,0), coalesce((r->>'op30_actual')::numeric,0),
      coalesce((r->>'setting_time')::numeric,0), coalesce((r->>'tool_change_time')::numeric,0),
      coalesce((r->>'breakdown_time')::numeric,0), coalesce((r->>'idle_time')::numeric,0), r->>'remarks');

    -- only OP10 moves stock CC -> WIPFG
    if pid is not null and op10 > 0 then
      cc := check_stock(pid, 'CC');
      if cc < op10 then
        raise exception 'Production blocked: CC balance % < OP10 % for a part', cc, op10;
      end if;
      insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
      values (p_date, pid, 'CC', 'WIPFG', op10, h_id, 'PRODUCTION', 'PRD-'||to_char(p_date,'YYYYMMDD'), 'OP10');
      if lid is not null then
        lbal := lot_balance(lid,'CC');
        if lbal < op10 then raise exception 'Lot CC balance % < OP10 %', lbal, op10; end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no)
        values (lid,'CC','WIPFG',op10,h_id,'PRODUCTION','PRD-'||to_char(p_date,'YYYYMMDD'));
        update lot_master set current_bucket='WIPFG' where id=lid;
      end if;
    end if;
  end loop;

  -- downtime sub-log
  for r in select * from jsonb_array_elements(coalesce(p_downtime,'[]'::jsonb)) loop
    insert into downtime_log(production_id,log_date,section,machine_no,start_time,end_time,duration_min,reason,action_taken)
    values (h_id,p_date,r->>'section',r->>'machine_no',r->>'start_time',r->>'end_time',
      nullif(r->>'duration_min','')::numeric,r->>'reason',r->>'action_taken');
  end loop;

  -- quality sub-log
  for r in select * from jsonb_array_elements(coalesce(p_quality,'[]'::jsonb)) loop
    insert into quality_log(production_id,log_date,section,machine_no,part_id,qty_rejected,rejection_type,defect_type,root_cause,corrective_action)
    values (h_id,p_date,r->>'section',r->>'machine_no',nullif(r->>'part_id','')::uuid,
      nullif(r->>'qty_rejected','')::numeric,r->>'rejection_type',r->>'defect_type',r->>'root_cause',r->>'corrective_action');
  end loop;

  perform log_audit('POST PRODUCTION', p_user, h_id::text);
  return h_id;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------
alter table production_log  enable row level security;
alter table production_rows enable row level security;
alter table downtime_log    enable row level security;
alter table quality_log     enable row level security;
do $$ declare t text; begin
  foreach t in array array['production_log','production_rows','downtime_log','quality_log'] loop
    execute format('drop policy if exists pol_%s on %I;', t, t);
    execute format('create policy pol_%s on %I for all using (true) with check (true);', t, t);
  end loop;
end $$;
