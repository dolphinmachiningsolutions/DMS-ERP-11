-- =====================================================================
--  DMS ERP V13.0 — PHASE 1A: STOCK SUMMARY ENGINE + PHYSICAL STOCK
--  Run AFTER schema_v13.sql (or its clean-install variant).
--  Adds: opening stock, physical reconciliation (cumulative VAR),
--  expanded per-bucket breakdown, and reconciliation posting.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. OPENING STOCK  (per part + bucket)  — folds into GRS
-- ---------------------------------------------------------------------
create table if not exists opening_stock (
  part_id uuid references parts(id) on delete cascade,
  bucket text references buckets(code),
  qty numeric not null default 0,
  primary key (part_id, bucket)
);

-- ---------------------------------------------------------------------
-- 2. PHYSICAL STOCK reconciliation rows.
--    Each row records a counted physical qty vs system qty at a date.
--    VARIANCE = physical - system. Stock VAR = cumulative sum of these.
-- ---------------------------------------------------------------------
create table if not exists physical_stock (
  id uuid primary key default gen_random_uuid(),
  recon_date date not null default current_date,
  part_id uuid references parts(id),
  bucket text references buckets(code),
  system_qty numeric not null default 0,
  physical_qty numeric not null default 0,
  variance numeric not null default 0,        -- physical - system
  remarks text,
  created_by text,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 3. Redefine GRS to INCLUDE opening stock.
--    GRS = opening + inwards(to_bucket) - outwards(from_bucket)
-- ---------------------------------------------------------------------
create or replace view stock_grs as
select p.id as part_id, b.code as bucket,
  coalesce((select qty from opening_stock o where o.part_id=p.id and o.bucket=b.code),0)
  + coalesce((select sum(qty) from stock_ledger l where l.part_id=p.id and l.to_bucket=b.code),0)
  - coalesce((select sum(qty) from stock_ledger l where l.part_id=p.id and l.from_bucket=b.code),0) as grs
from parts p cross join buckets b where b.is_external=false;

-- ---------------------------------------------------------------------
-- 4. VAR = cumulative physical variance per part+bucket (live).
--    Replaces the manual stock_variance table as the source of truth,
--    but we keep BAL reading from a unified variance source.
-- ---------------------------------------------------------------------
create or replace view stock_var as
select p.id as part_id, b.code as bucket,
  coalesce((select sum(variance) from physical_stock ps where ps.part_id=p.id and ps.bucket=b.code),0)
  + coalesce((select var_qty from stock_variance v where v.part_id=p.id and v.bucket=b.code),0) as var_qty
from parts p cross join buckets b where b.is_external=false;

-- ---------------------------------------------------------------------
-- 5. BAL view = GRS + VAR  (single enforcement point)
-- ---------------------------------------------------------------------
create or replace view stock_balance as
select g.part_id, g.bucket, g.grs,
  coalesce(v.var_qty,0) as var_qty,
  g.grs + coalesce(v.var_qty,0) as bal
from stock_grs g
left join stock_var v on v.part_id=g.part_id and v.bucket=g.bucket;

-- check_stock already reads stock_balance.bal — unchanged, still valid.

-- ---------------------------------------------------------------------
-- 6. STOCK SUMMARY breakdown view (the DB_STOCK_SUMMARY grid).
--    One row per active part with, per bucket: OPEN, inwards, outwards,
--    GRS, VAR, BAL. Inward/outward are derived from the ledger by
--    bucket role, so it survives new voucher types automatically.
-- ---------------------------------------------------------------------
create or replace view stock_summary as
with led as (
  select part_id,
    -- inward into each bucket
    sum(qty) filter (where to_bucket='RC')    as rc_in,
    sum(qty) filter (where from_bucket='RC')   as rc_out,
    sum(qty) filter (where to_bucket='RCCST')  as rccst_in,
    sum(qty) filter (where from_bucket='RCCST') as rccst_out,
    sum(qty) filter (where to_bucket='CC')     as cc_in,
    sum(qty) filter (where from_bucket='CC')    as cc_out,
    sum(qty) filter (where to_bucket='WIPFG')  as wipfg_in,
    sum(qty) filter (where from_bucket='WIPFG') as wipfg_out,
    sum(qty) filter (where to_bucket='PR')     as pr_in,
    sum(qty) filter (where from_bucket='PR')    as pr_out,
    sum(qty) filter (where to_bucket='MRM')    as mrm_in,
    sum(qty) filter (where from_bucket='MRM')   as mrm_out,
    sum(qty) filter (where to_bucket='FGR')    as fgr_in,
    sum(qty) filter (where from_bucket='FGR')   as fgr_out,
    sum(qty) filter (where to_bucket='RWD')    as rwd_in,
    sum(qty) filter (where from_bucket='RWD')   as rwd_out
  from stock_ledger group by part_id
)
select p.id as part_id, p.part_code, p.part_name,
  bal_rc.bal as rc_bal, bal_rccst.bal as rccst_bal, bal_cc.bal as cc_bal,
  bal_wipfg.bal as wipfg_bal, bal_pr.bal as pr_bal, bal_mrm.bal as mrm_bal,
  bal_fgr.bal as fgr_bal, bal_rwd.bal as rwd_bal,
  coalesce(l.rc_in,0) rc_in, coalesce(l.rc_out,0) rc_out,
  coalesce(l.cc_in,0) cc_in, coalesce(l.cc_out,0) cc_out,
  coalesce(l.wipfg_in,0) wipfg_in, coalesce(l.wipfg_out,0) wipfg_out
from parts p
left join led l on l.part_id=p.id
left join stock_balance bal_rc    on bal_rc.part_id=p.id    and bal_rc.bucket='RC'
left join stock_balance bal_rccst on bal_rccst.part_id=p.id and bal_rccst.bucket='RCCST'
left join stock_balance bal_cc    on bal_cc.part_id=p.id    and bal_cc.bucket='CC'
left join stock_balance bal_wipfg on bal_wipfg.part_id=p.id and bal_wipfg.bucket='WIPFG'
left join stock_balance bal_pr    on bal_pr.part_id=p.id    and bal_pr.bucket='PR'
left join stock_balance bal_mrm   on bal_mrm.part_id=p.id   and bal_mrm.bucket='MRM'
left join stock_balance bal_fgr   on bal_fgr.part_id=p.id   and bal_fgr.bucket='FGR'
left join stock_balance bal_rwd   on bal_rwd.part_id=p.id   and bal_rwd.bucket='RWD'
where p.status='Active';

-- ---------------------------------------------------------------------
-- 7. getStockForReconciliation — current BAL for every active part+bucket
-- ---------------------------------------------------------------------
create or replace function get_recon_grid()
returns table(part_id uuid, part_code text, part_name text, bucket text, system_qty numeric) as $$
  select p.id, p.part_code, p.part_name, b.code, check_stock(p.id, b.code)
  from parts p cross join buckets b
  where p.status='Active' and b.is_external=false
  order by p.part_code, b.code;
$$ language sql;

-- ---------------------------------------------------------------------
-- 8. processStockReconciliation — saves counted rows; variance = phys - sys.
--    p_rows: [{"part_id":..,"bucket":"RC","physical_qty":10}, ...]
--    Only rows where physical differs from system are stored (others skipped).
-- ---------------------------------------------------------------------
create or replace function post_reconciliation(p_date date, p_user text, p_rows jsonb)
returns int as $$
declare r jsonb; sys numeric; phys numeric; n int := 0;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    sys := check_stock((r->>'part_id')::uuid, r->>'bucket');
    phys := coalesce((r->>'physical_qty')::numeric, sys);
    if phys <> sys then
      insert into physical_stock(recon_date,part_id,bucket,system_qty,physical_qty,variance,remarks,created_by)
      values (p_date,(r->>'part_id')::uuid,r->>'bucket',sys,phys,phys-sys,r->>'remarks',p_user);
      n := n + 1;
    end if;
  end loop;
  return n;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 9. RLS for new tables
-- ---------------------------------------------------------------------
alter table opening_stock  enable row level security;
alter table physical_stock enable row level security;
drop policy if exists pol_opening on opening_stock;
drop policy if exists pol_physical on physical_stock;
create policy pol_opening  on opening_stock  for all using (true) with check (true);
create policy pol_physical on physical_stock for all using (true) with check (true);
