-- =====================================================================
--  DMS ERP V13.0 — PHASE 6: ADMINISTRATION MASTERS
--  Run AFTER schema_phase5.sql.
--  Adds: user-management flags, machine config, checkbox permissions,
--  and admin helper functions for users, mappings, opening stock,
--  price list, and machine config.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. USER flags (spec DB_USERS): access modules, weight-check,
--    valid-thru-edit, can-edit. role already exists (user/can_edit/admin).
-- ---------------------------------------------------------------------
alter table app_users add column if not exists access_modules text default 'ALL';
alter table app_users add column if not exists weight_check boolean default true;
alter table app_users add column if not exists valid_thru_edit boolean default false;

-- admin user CRUD
create or replace function admin_list_users()
returns table(id uuid, username text, role text, access_modules text,
  weight_check boolean, valid_thru_edit boolean, created_at timestamptz) as $$
  select id, username, role, access_modules, weight_check, valid_thru_edit, created_at
  from app_users order by username;
$$ language sql security definer;

create or replace function admin_save_user(
  p_id uuid, p_username text, p_password text, p_role text,
  p_access text, p_weight boolean, p_valid_edit boolean
) returns uuid as $$
declare uid uuid;
begin
  if p_id is null then
    insert into app_users(username,password,role,access_modules,weight_check,valid_thru_edit)
    values (p_username, crypt(coalesce(p_password,'changeme'),gen_salt('bf')), p_role, p_access, p_weight, p_valid_edit)
    returning id into uid;
  else
    update app_users set
      username=p_username, role=p_role, access_modules=p_access,
      weight_check=p_weight, valid_thru_edit=p_valid_edit,
      password = case when p_password is null or p_password='' then password else crypt(p_password,gen_salt('bf')) end
    where id=p_id returning id into uid;
  end if;
  return uid;
end; $$ language plpgsql security definer;

create or replace function admin_delete_user(p_id uuid)
returns void as $$ delete from app_users where id=p_id and username <> 'admin'; $$ language sql security definer;

-- verify_login: return the extra flags too
drop function if exists verify_login(text, text);
create or replace function verify_login(p_username text, p_password text)
returns table(id uuid, username text, role text, access_modules text, weight_check boolean, valid_thru_edit boolean) as $$
  select id, username, role, access_modules, weight_check, valid_thru_edit
  from app_users where username=p_username and password=crypt(p_password,password);
$$ language sql security definer;

-- ---------------------------------------------------------------------
-- 2. MACHINE CONFIG (section -> machine -> operation), drives Production grid
-- ---------------------------------------------------------------------
create table if not exists machine_config (
  id uuid primary key default gen_random_uuid(),
  section text not null,
  machine text not null,
  operation text,
  unique (section, machine, operation)
);

-- ---------------------------------------------------------------------
-- 3. CHECKBOX PERMISSIONS (per-user doc-control edit rights)
-- ---------------------------------------------------------------------
create table if not exists checkbox_perms (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  checkbox_field text not null,   -- REC_COPY, APPROVED_ACC, APPROVED_MGMT, GSTR_2A, GSTR_1
  can_edit boolean default false,
  unique (username, checkbox_field)
);

-- ---------------------------------------------------------------------
-- 4. Opening stock bulk upsert helper
--    p_rows: [{"part_id":..,"bucket":"RC","qty":100}, ...]
-- ---------------------------------------------------------------------
create or replace function admin_save_opening(p_rows jsonb)
returns int as $$
declare r jsonb; n int := 0;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into opening_stock(part_id,bucket,qty)
    values ((r->>'part_id')::uuid, r->>'bucket', coalesce((r->>'qty')::numeric,0))
    on conflict (part_id,bucket) do update set qty = excluded.qty;
    n := n + 1;
  end loop;
  return n;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 5. Price list upsert helper
--    p_rows: [{"part_id":..,"entity_id":..,"price_type":"purchase","month_key":"Jun 2026","unit_price":12}, ...]
-- ---------------------------------------------------------------------
create or replace function admin_save_prices(p_rows jsonb)
returns int as $$
declare r jsonb; n int := 0;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into price_list(part_id,entity_id,price_type,month_key,unit_price)
    values ((r->>'part_id')::uuid,(r->>'entity_id')::uuid,r->>'price_type',r->>'month_key',coalesce((r->>'unit_price')::numeric,0))
    on conflict (part_id,entity_id,price_type,month_key) do update set unit_price = excluded.unit_price;
    n := n + 1;
  end loop;
  return n;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 6. Mapping helpers — set the full part list for a vendor/customer
-- ---------------------------------------------------------------------
create or replace function admin_set_vendor_parts(p_vendor uuid, p_parts uuid[])
returns void as $$
begin
  delete from master_vendor_parts where vendor_id = p_vendor;
  insert into master_vendor_parts(vendor_id, part_id)
    select p_vendor, unnest(p_parts) on conflict do nothing;
end; $$ language plpgsql security definer;

create or replace function admin_set_customer_parts(p_customer uuid, p_parts uuid[])
returns void as $$
begin
  delete from master_customer_parts where customer_id = p_customer;
  insert into master_customer_parts(customer_id, part_id)
    select p_customer, unnest(p_parts) on conflict do nothing;
end; $$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 7. RLS
-- ---------------------------------------------------------------------
alter table machine_config enable row level security;
alter table checkbox_perms enable row level security;
drop policy if exists pol_machine on machine_config;
drop policy if exists pol_checkbox on checkbox_perms;
create policy pol_machine  on machine_config for all using (true) with check (true);
create policy pol_checkbox on checkbox_perms for all using (true) with check (true);
