-- =====================================================================
--  V14.1 ADD-ON: Part Groups, Machine Config (Production layout),
--  Undo transactions, helper reads. Run AFTER schema_v14.sql.
-- =====================================================================

-- ---- Part Groups (tabs in Production Log) ----
create table if not exists part_group (
  id uuid primary key default gen_random_uuid(),
  group_name text unique not null,
  sort_order int default 0,
  created_at timestamptz default now()
);
create or replace function list_part_groups() returns table(id uuid, group_name text, sort_order int) as $$
  select id, group_name, sort_order from part_group order by sort_order, group_name; $$ language sql;
create or replace function create_part_group(p_name text) returns uuid as $$
declare i uuid; begin
  insert into part_group(group_name) values(p_name) on conflict(group_name) do nothing;
  select id into i from part_group where group_name=p_name; return i; end; $$ language plpgsql security definer;

-- ---- Part master: add part_group ----
alter table part add column if not exists part_group_id uuid references part_group(id);

-- ---- Machine Config: redefine as full Production layout ----
--  (part_group -> machine -> operation, with ordering)
drop table if exists machine_config cascade;
create table machine_config (
  id uuid primary key default gen_random_uuid(),
  part_group_id uuid references part_group(id) on delete cascade,
  machine text not null,         -- e.g. VMC 10
  operation text,                -- optional label
  sort_order int default 0,
  created_at timestamptz default now()
);
alter table machine_config enable row level security;
drop policy if exists pol_machine_config on machine_config;
create policy pol_machine_config on machine_config for all using(true) with check(true);

-- read the full production layout: tabs + machines per tab
create or replace function production_layout() returns table(
  group_id uuid, group_name text, group_sort int,
  machine_id uuid, machine text, operation text, machine_sort int) as $$
  select g.id, g.group_name, g.sort_order,
         m.id, m.machine, m.operation, coalesce(m.sort_order,0)
  from part_group g
  left join machine_config m on m.part_group_id=g.id
  order by g.sort_order, g.group_name, coalesce(m.sort_order,0), m.machine; $$ language sql;

-- machine config CRUD helpers
create or replace function mc_save(p_id uuid, p_group uuid, p_machine text, p_operation text, p_sort int) returns uuid as $$
declare i uuid; begin
  if p_id is null then insert into machine_config(part_group_id,machine,operation,sort_order) values(p_group,p_machine,p_operation,coalesce(p_sort,0)) returning id into i;
  else update machine_config set part_group_id=p_group, machine=p_machine, operation=p_operation, sort_order=coalesce(p_sort,0) where id=p_id returning id into i; end if;
  return i; end; $$ language plpgsql security definer;
create or replace function mc_delete(p_id uuid) returns void as $$ delete from machine_config where id=p_id; $$ language sql security definer;

-- ---- Undo transactions: cancel a voucher and reverse its stock ----
create or replace function undo_voucher(p_id uuid, p_user text, p_role text) returns jsonb as $$
declare vt text; vn text; begin
  if p_role <> 'admin' then return jsonb_build_object('ok',false,'msg','Only admin can undo transactions'); end if;
  select voucher_type, voucher_no into vt, vn from vouchers where id=p_id;
  if vt is null then return jsonb_build_object('ok',false,'msg','Voucher not found'); end if;
  perform reverse_voucher_stock(p_id);
  update vouchers set cancelled=true, status='CANCELLED' where id=p_id;
  perform log_audit('UNDO '||vt, p_user, vn);
  return jsonb_build_object('ok',true,'msg','Transaction '||vn||' undone (cancelled & stock reversed)');
end; $$ language plpgsql security definer;

-- recent transactions for the Undo screen
create or replace function recent_transactions(p_limit int default 100) returns table(
  id uuid, voucher_type text, voucher_id_code text, voucher_no text, voucher_date date,
  ledger_name text, total_value numeric, cancelled boolean, created_by text, created_at timestamptz) as $$
  select v.id, v.voucher_type, v.voucher_id_code, v.voucher_no, v.voucher_date, l.ledger_name,
    coalesce((select sum(basic_value) from voucher_lines x where x.voucher_id=v.id),0), v.cancelled, v.created_by, v.created_at
  from vouchers v left join ledger l on l.id=v.ledger_id
  order by v.created_at desc limit p_limit; $$ language sql;

-- Open PO / DC / SO summary for the Books page banner
create or replace function open_documents() returns table(
  doc text, voucher_no text, voucher_date date, ledger_name text, part_code text, pending numeric) as $$
  select 'PO', o.voucher_no, o.voucher_date, l.ledger_name, p.part_code, o.pending_qty
    from open_orders o left join ledger l on l.id=o.ledger_id left join part p on p.id=o.part_id where o.voucher_type='PURCHASE_ORDER'
  union all
  select 'SO', o.voucher_no, o.voucher_date, l.ledger_name, p.part_code, o.pending_qty
    from open_orders o left join ledger l on l.id=o.ledger_id left join part p on p.id=o.part_id where o.voucher_type='SALES_ORDER'
  union all
  select 'DC', d.voucher_no, d.voucher_date, l.ledger_name, p.part_code, d.pending_qty
    from open_dcs d left join ledger l on l.id=d.ledger_id left join part p on p.id=d.part_id; $$ language sql;

-- Opening stock editable grid read (reuse get_recon_grid shape but with stored opening)
create or replace function opening_grid() returns table(part_id uuid, part_code text, part_name text, bucket text, qty numeric) as $$
  select p.id, p.part_code, p.part_name, b.code, coalesce((select qty from opening_stock o where o.part_id=p.id and o.bucket=b.code),0)
  from part p cross join buckets b where p.status='Active' and b.is_external=false order by p.part_code, b.code; $$ language sql;
