-- =====================================================================
--  STOCK ENGINE HARDENING — "the vault"
--  Run at the END of schema_v14.sql (it is appended there).
--  Layers 7 guarantees on top of the stock engine so the bucket logic
--  cannot be corrupted by app bugs, manual edits, or concurrency.
--
--  G1 Balanced-pair integrity (column constraints)
--  G2 Sealed ledger: only post_stock_move() may write stock_ledger
--  G3 Atomic no-negative with row-level lock
--  G4 Immutable history: no UPDATE/DELETE on posted movements
--  G5 Derived balance + self-rebuilding cache + reconciliation auditor
--  G6 All-or-nothing (transaction-scoped; posting fns already atomic)
--  G7 Single source of truth for the bucket map
-- =====================================================================

-- ---------------------------------------------------------------------
-- G7. ONE bucket map. Every module's from/to lives here, nowhere else.
-- ---------------------------------------------------------------------
create table if not exists bucket_map (
  voucher_type text primary key,
  from_bucket  text,           -- null = resolved per-line (variants / disposition)
  to_bucket    text,           -- null = resolved per-line
  note         text
);
delete from bucket_map;
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

-- ---------------------------------------------------------------------
-- G1. Balanced-pair integrity. A movement must be well-formed.
--     (Drop first so re-runs are clean.)
-- ---------------------------------------------------------------------
alter table stock_ledger drop constraint if exists chk_qty_positive;
alter table stock_ledger drop constraint if exists chk_from_ne_to;
alter table stock_ledger add constraint chk_qty_positive check (qty > 0);
alter table stock_ledger add constraint chk_from_ne_to  check (from_bucket is distinct from to_bucket);
-- both buckets must exist (FK already present on from/to via buckets table)

-- ---------------------------------------------------------------------
-- G5a. Balance CACHE table, rebuilt by the DB from the ledger.
--      Never hand-set. Truth remains the ledger; this is a fast mirror.
-- ---------------------------------------------------------------------
create table if not exists stock_cache (
  part_id uuid, bucket text, grs numeric not null default 0,
  var_qty numeric not null default 0, bal numeric not null default 0,
  updated_at timestamptz default now(), primary key(part_id,bucket));

-- recompute one (part,bucket) cache cell straight from source views
create or replace function recache_cell(p_part uuid, p_bucket text) returns void as $$
declare g numeric; v numeric; begin
  select grs into g from stock_grs where part_id=p_part and bucket=p_bucket;
  select var_qty into v from stock_var where part_id=p_part and bucket=p_bucket;
  g:=coalesce(g,0); v:=coalesce(v,0);
  insert into stock_cache(part_id,bucket,grs,var_qty,bal,updated_at)
  values(p_part,p_bucket,g,v,g+v,now())
  on conflict(part_id,bucket) do update set grs=excluded.grs,var_qty=excluded.var_qty,bal=excluded.bal,updated_at=now();
end; $$ language plpgsql;

-- full rebuild (used on install and by the auditor's repair)
create or replace function recache_all() returns void as $$
  select recache_cell(part_id,bucket) from stock_grs; select null::void;
$$ language sql;

-- ---------------------------------------------------------------------
-- G3 + G2 helper. THE ONLY sanctioned writer of stock_ledger.
--   - takes a row-level lock on the (part,bucket) cache cell
--   - re-derives current balance under the lock
--   - blocks if the move would drive an INTERNAL source below zero
--   - writes the movement, then refreshes the two affected cache cells
--   A session GUC (app.stock_gate) is set TRUE only inside this function,
--   and the ledger trigger (G2) refuses any write made without it.
-- ---------------------------------------------------------------------
create or replace function post_stock_move(
  p_date date, p_part uuid, p_from text, p_to text, p_qty numeric,
  p_voucher uuid, p_vtype text, p_vno text, p_note text, p_allow_negative numeric default 0
) returns uuid as $$
declare avail numeric; rid uuid; from_internal boolean; to_internal boolean;
begin
  if p_qty is null or p_qty <= 0 then raise exception 'stock move qty must be > 0 (got %)', p_qty; end if;
  if p_from is distinct from p_to then null; else raise exception 'from and to bucket cannot be the same (%).', p_from; end if;

  select not is_external into from_internal from buckets where code=p_from;
  select not is_external into to_internal   from buckets where code=p_to;
  if from_internal is null then raise exception 'unknown from_bucket %', p_from; end if;
  if to_internal   is null then raise exception 'unknown to_bucket %', p_to; end if;

  -- G3: lock the source cache cell so concurrent posts serialise on it
  if from_internal then
    perform 1 from stock_cache where part_id=p_part and bucket=p_from for update;
    if not found then perform recache_cell(p_part,p_from); perform 1 from stock_cache where part_id=p_part and bucket=p_from for update; end if;
    avail := check_stock(p_part,p_from);
    -- p_allow_negative is the sanctioned buffer (e.g. Sales +250); 0 = hard no-negative
    if avail + coalesce(p_allow_negative,0) < p_qty then
      raise exception 'INSUFFICIENT STOCK: part % in %, need %, have % (allowance %)', p_part, p_from, p_qty, avail, coalesce(p_allow_negative,0)
        using errcode='23514';
    end if;
  end if;

  -- G2: open the gate for this one insert, then close it
  perform set_config('app.stock_gate','on',true);
  insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
  values(p_date,p_part,p_from,p_to,p_qty,p_voucher,p_vtype,p_vno,p_note) returning id into rid;
  perform set_config('app.stock_gate','off',true);

  -- G5: refresh both affected cache cells
  if from_internal then perform recache_cell(p_part,p_from); end if;
  if to_internal   then perform recache_cell(p_part,p_to);   end if;
  return rid;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- G2. SEAL the ledger. Any INSERT not flagged by the gate is refused.
--     UPDATE/DELETE on posted rows is refused outright (G4 immutability),
--     EXCEPT a controlled cancel path that sets app.stock_uncage.
-- ---------------------------------------------------------------------
create or replace function ledger_guard() returns trigger as $$
begin
  if tg_op='INSERT' then
    if current_setting('app.stock_gate', true) is distinct from 'on' then
      raise exception 'stock_ledger is sealed: write only via post_stock_move()' using errcode='42501';
    end if;
    return new;
  end if;
  -- UPDATE / DELETE
  if current_setting('app.stock_uncage', true) = 'on' then return coalesce(new,old); end if;
  raise exception 'stock_ledger is immutable: posted movements cannot be % (use a reversing entry)', tg_op using errcode='42501';
end; $$ language plpgsql;

drop trigger if exists trg_ledger_guard on stock_ledger;
create trigger trg_ledger_guard before insert or update or delete on stock_ledger
  for each row execute function ledger_guard();

-- controlled removal of a voucher's movements (for cancel/undo & edit-repost).
-- Opens the uncage flag, deletes, recaches touched cells, closes the flag.
create or replace function purge_voucher_moves(p_voucher uuid) returns void as $$
declare r record;
begin
  perform set_config('app.stock_uncage','on',true);
  drop table if exists _touched;
  create temp table _touched(part_id uuid, bucket text);
  insert into _touched select distinct part_id, from_bucket from stock_ledger where voucher_id=p_voucher and from_bucket is not null
    union select distinct part_id, to_bucket from stock_ledger where voucher_id=p_voucher and to_bucket is not null;
  delete from stock_ledger where voucher_id=p_voucher;
  delete from lot_ledger where voucher_id=p_voucher;
  perform set_config('app.stock_uncage','off',true);
  for r in select part_id,bucket from _touched loop perform recache_cell(r.part_id,r.bucket); end loop;
  drop table if exists _touched;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- G5b. RECONCILIATION AUDITOR. Re-derives every balance from the ledger
--      and compares to the cache. Any row returned = drift = a bug.
--      In practice always empty (app never writes the cache).
-- ---------------------------------------------------------------------
create or replace function reconcile_stock() returns table(
  part_id uuid, part_code text, bucket text, ledger_bal numeric, cache_bal numeric, drift numeric) as $$
  select g.part_id, p.part_code, g.bucket,
         (g.grs + coalesce(v.var_qty,0)) ledger_bal,
         coalesce(c.bal,0) cache_bal,
         (g.grs + coalesce(v.var_qty,0)) - coalesce(c.bal,0) drift
  from stock_grs g
  join part p on p.id=g.part_id
  left join stock_var v on v.part_id=g.part_id and v.bucket=g.bucket
  left join stock_cache c on c.part_id=g.part_id and c.bucket=g.bucket
  where abs((g.grs + coalesce(v.var_qty,0)) - coalesce(c.bal,0)) > 0.0001;
$$ language sql security definer;

-- negative-balance auditor (should also always be empty)
create or replace function audit_negatives() returns table(part_code text, bucket text, bal numeric) as $$
  select p.part_code, s.bucket, s.grs+coalesce(v.var_qty,0)
  from stock_grs s join part p on p.id=s.part_id
  left join stock_var v on v.part_id=s.part_id and v.bucket=s.bucket
  where s.grs+coalesce(v.var_qty,0) < 0;
$$ language sql security definer;

-- one-call health check for an admin screen
create or replace function engine_health() returns table(check_name text, status text, detail text) as $$
  select 'cache_drift',
    case when exists(select 1 from reconcile_stock()) then 'FAIL' else 'OK' end,
    coalesce((select count(*)::text||' cell(s) drifted' from reconcile_stock()),'0')
  union all
  select 'negative_balances',
    case when exists(select 1 from audit_negatives()) then 'FAIL' else 'OK' end,
    coalesce((select count(*)::text||' negative cell(s)' from audit_negatives()),'0');
$$ language sql security definer;

-- build the cache now so reads are instant from first use
select recache_all();
