-- =====================================================================
--  DMS ERP V13.0 — PHASE 5: GOVERNANCE
--  Run AFTER schema_phase4.sql.
--  Adds: rec-copy approval gate, price-approval gate, mark for
--  deletion/modification, 8-hour edit window, audit & undo logs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Governance columns on vouchers
-- ---------------------------------------------------------------------
alter table vouchers add column if not exists rec_copy boolean default false;
alter table vouchers add column if not exists price_approved text default 'OK';   -- 'OK' | 'PENDING'
alter table vouchers add column if not exists approved_acc boolean default false;
alter table vouchers add column if not exists gstr_flag2 boolean default false;
alter table vouchers add column if not exists delete_requested boolean default false;
alter table vouchers add column if not exists modify_requested boolean default false;
alter table vouchers add column if not exists request_reason text;
alter table vouchers add column if not exists requested_by text;
alter table vouchers add column if not exists request_date timestamptz;
-- approved_mgmt already exists ('APPROVED' default; 'PENDING' when gated)
-- po_price for purchase price-mismatch comparison
alter table voucher_lines add column if not exists po_price numeric default 0;

-- ---------------------------------------------------------------------
-- 2. AUDIT + UNDO logs
-- ---------------------------------------------------------------------
create table if not exists audit_log (
  id uuid primary key default gen_random_uuid(),
  ts timestamptz default now(),
  action text, app_user text, details text
);
create table if not exists undo_log (
  id uuid primary key default gen_random_uuid(),
  ts timestamptz default now(),
  voucher_type text, voucher_id uuid, original_data jsonb, undone_by text
);
create or replace function log_audit(p_action text, p_user text, p_details text)
returns void as $$ insert into audit_log(action,app_user,details) values (p_action,p_user,p_details); $$ language sql;

-- ---------------------------------------------------------------------
-- 3. REC-COPY GATE
--    Config: which voucher types are gated, the date column, grace days.
--      JW_DC_OUT (DUE_DATE, 0), DC_OUT_RET (DUE_DATE,0),
--      DC_OUT_REPLACE (DUE_DATE,0), SALES (VOUCHER_DATE, 2)
--    has_overdue_rec_copies: any non-cancelled, rec_copy=false row whose
--    (date + grace) < today → gate is tripped.
-- ---------------------------------------------------------------------
create or replace function has_overdue_rec_copies(p_type text)
returns boolean as $$
declare grace int; usecol text; trip boolean;
begin
  grace := case p_type when 'SALES' then 2 else 0 end;
  usecol := case p_type when 'SALES' then 'voucher_date' else 'valid_thru' end; -- valid_thru holds due_date for DC types
  if p_type not in ('JW_DC_OUT','DC_OUT_RET','DC_OUT_REPLACE','SALES') then return false; end if;
  execute format($f$
    select exists(
      select 1 from vouchers
      where voucher_type = %L and cancelled = false and coalesce(rec_copy,false) = false
        and %I is not null and (%I + %s) < current_date
    )$f$, p_type, usecol, usecol, grace) into trip;
  return coalesce(trip,false);
end; $$ language plpgsql;

-- ---------------------------------------------------------------------
-- 4. Wrap post_voucher with gate decisions (rec-copy + price).
--    We keep the Phase-4 core and add a thin pre/post layer by adding a
--    new entry function the app calls; it sets approved_mgmt/price_approved
--    after the core insert.
-- ---------------------------------------------------------------------
create or replace function post_voucher_governed(
  p_type text, p_no text, p_date date, p_posting date, p_valid date,
  p_party uuid, p_ref_voucher uuid, p_ref_no text, p_remarks text,
  p_user text, p_lines jsonb
) returns jsonb as $$
declare v_id uuid; gated boolean; price_pending boolean := false; ln jsonb; po_pend numeric; po_price numeric;
begin
  v_id := post_voucher(p_type,p_no,p_date,p_posting,p_valid,p_party,p_ref_voucher,p_ref_no,p_remarks,p_user,p_lines);

  -- rec-copy gate: if tripped, hold this new entry as PENDING
  gated := has_overdue_rec_copies(p_type);
  if gated then
    update vouchers set approved_mgmt = 'PENDING' where id = v_id;
  end if;

  -- price gate (RM Purchase): if any line unit_price <> PO price → PENDING
  if p_type = 'RM_PURCHASE' then
    for ln in select * from jsonb_array_elements(p_lines) loop
      if nullif(ln->>'ref_no','') is not null then
        select unit_price into po_price from voucher_lines pl
          join vouchers pv on pv.id = pl.voucher_id
          where pv.voucher_type='PURCHASE_ORDER' and pv.voucher_no = ln->>'ref_no'
            and pl.part_id = (ln->>'part_id')::uuid limit 1;
        if po_price is not null and coalesce((ln->>'unit_price')::numeric,0) <> po_price then
          price_pending := true;
        end if;
      end if;
    end loop;
    if price_pending then
      update vouchers set price_approved = 'PENDING' where id = v_id;
    end if;
  end if;

  perform log_audit('POST '||p_type, p_user, p_no);
  return jsonb_build_object('id', v_id, 'rec_gated', gated, 'price_pending', price_pending);
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 5. REC-COPY APPROVAL admin functions
-- ---------------------------------------------------------------------
create or replace function rec_copy_pending()
returns table(id uuid, voucher_type text, voucher_no text, voucher_date date, party_id uuid) as $$
  select id, voucher_type, voucher_no, voucher_date, party_id
  from vouchers where approved_mgmt = 'PENDING' and cancelled = false
  order by created_at;
$$ language sql;

create or replace function approve_rec_copy(p_ids uuid[])
returns int as $$
  with u as (update vouchers set approved_mgmt = 'APPROVED' where id = any(p_ids) returning 1)
  select count(*)::int from u;
$$ language sql security definer;

-- toggle the physical rec-copy received flag (clears a row from the gate)
create or replace function set_rec_copy(p_id uuid, p_val boolean)
returns void as $$ update vouchers set rec_copy = p_val where id = p_id; $$ language sql security definer;

-- ---------------------------------------------------------------------
-- 6. PRICE APPROVAL admin functions
-- ---------------------------------------------------------------------
create or replace function price_pending()
returns table(id uuid, voucher_no text, voucher_date date, party_id uuid) as $$
  select id, voucher_no, voucher_date, party_id
  from vouchers where price_approved = 'PENDING' and cancelled = false and voucher_type='RM_PURCHASE'
  order by created_at;
$$ language sql;

create or replace function approve_price(p_id uuid)
returns void as $$ update vouchers set price_approved='OK' where id=p_id; $$ language sql security definer;

create or replace function cancel_price_mismatch(p_id uuid)
returns void as $$ update vouchers set cancelled=true where id=p_id; $$ language sql security definer;

-- ---------------------------------------------------------------------
-- 7. MARK for Deletion / Modification + resolve
--    8-hour rule for Modify (non-admin); Delete always allowed for
--    admin/can_edit. Enforced in the marking function via role + age.
-- ---------------------------------------------------------------------
create or replace function mark_record(p_id uuid, p_mark text, p_reason text, p_user text, p_role text)
returns jsonb as $$
declare age interval; created timestamptz;
begin
  select created_at into created from vouchers where id = p_id;
  if created is null then return jsonb_build_object('ok',false,'msg','Record not found'); end if;
  age := now() - created;

  if p_role not in ('admin','can_edit') then
    return jsonb_build_object('ok',false,'msg','You do not have permission to mark records.');
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    return jsonb_build_object('ok',false,'msg','A reason is required.');
  end if;

  if p_mark = 'modify' and p_role <> 'admin' and age > interval '8 hours' then
    return jsonb_build_object('ok',false,'msg','Modify window (8 hours) has passed.');
  end if;

  update vouchers set
    delete_requested = (p_mark='delete') or delete_requested,
    modify_requested = (p_mark='modify') or modify_requested,
    request_reason = p_reason, requested_by = p_user, request_date = now()
  where id = p_id;
  perform log_audit('MARK '||p_mark, p_user, p_id::text||' : '||p_reason);
  return jsonb_build_object('ok',true,'msg','Request submitted for admin approval.');
end; $$ language plpgsql security definer;

create or replace function marked_requests()
returns table(id uuid, voucher_type text, voucher_no text, delete_requested boolean,
  modify_requested boolean, request_reason text, requested_by text, request_date timestamptz) as $$
  select id, voucher_type, voucher_no, delete_requested, modify_requested,
    request_reason, requested_by, request_date
  from vouchers where (delete_requested or modify_requested) and cancelled = false
  order by request_date;
$$ language sql;

create or replace function resolve_mark(p_id uuid, p_mark text, p_action text, p_admin text)
returns jsonb as $$
begin
  if p_action = 'approve' and p_mark = 'delete' then
    update vouchers set cancelled = true, delete_requested = false where id = p_id;       -- stock reverses via views
    perform log_audit('APPROVE DELETE', p_admin, p_id::text);
  elsif p_action = 'approve' and p_mark = 'modify' then
    update vouchers set modify_requested = false where id = p_id;                          -- now editable
    perform log_audit('APPROVE MODIFY', p_admin, p_id::text);
  else -- reject
    update vouchers set delete_requested = case when p_mark='delete' then false else delete_requested end,
                        modify_requested = case when p_mark='modify' then false else modify_requested end
      where id = p_id;
    perform log_audit('REJECT '||p_mark, p_admin, p_id::text);
  end if;
  return jsonb_build_object('ok',true);
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 8. CANCELLED stock reversal — exclude cancelled vouchers' ledger rows.
--    Stock views read stock_ledger; we filter cancelled at the ledger
--    by joining vouchers. Redefine GRS source to skip cancelled.
-- ---------------------------------------------------------------------
create or replace view stock_grs as
select p.id as part_id, b.code as bucket,
  coalesce((select qty from opening_stock o where o.part_id=p.id and o.bucket=b.code),0)
  + coalesce((select sum(l.qty) from stock_ledger l left join vouchers v on v.id=l.voucher_id
      where l.part_id=p.id and l.to_bucket=b.code and coalesce(v.cancelled,false)=false),0)
  - coalesce((select sum(l.qty) from stock_ledger l left join vouchers v on v.id=l.voucher_id
      where l.part_id=p.id and l.from_bucket=b.code and coalesce(v.cancelled,false)=false),0) as grs
from parts p cross join buckets b where b.is_external=false;

-- ---------------------------------------------------------------------
-- 9. EDIT WINDOW helper (used by app before allowing edit)
-- ---------------------------------------------------------------------
create or replace function can_edit_voucher(p_id uuid, p_user text, p_role text)
returns jsonb as $$
declare created timestamptz; owner text;
begin
  select created_at, created_by into created, owner from vouchers where id = p_id;
  if created is null then return jsonb_build_object('ok',false,'msg','Not found'); end if;
  if p_role = 'admin' then return jsonb_build_object('ok',true); end if;
  if p_role <> 'can_edit' then return jsonb_build_object('ok',false,'msg','No edit permission'); end if;
  if owner is distinct from p_user then return jsonb_build_object('ok',false,'msg','You can only edit your own entries'); end if;
  if now() - created > interval '8 hours' then return jsonb_build_object('ok',false,'msg','8-hour edit window passed'); end if;
  return jsonb_build_object('ok',true);
end; $$ language plpgsql;

-- ---------------------------------------------------------------------
-- 10. RLS for new tables
-- ---------------------------------------------------------------------
alter table audit_log enable row level security;
alter table undo_log  enable row level security;
drop policy if exists pol_audit on audit_log;
drop policy if exists pol_undo on undo_log;
create policy pol_audit on audit_log for all using (true) with check (true);
create policy pol_undo  on undo_log  for all using (true) with check (true);
