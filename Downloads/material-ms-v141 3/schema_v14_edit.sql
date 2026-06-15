-- =====================================================================
--  V14 ADD-ON: voucher EDIT support + GST validation + checkbox perms
--  Run AFTER schema_v14.sql (idempotent where possible).
-- =====================================================================

-- ---- load one voucher with its lines (for the edit form) ----
create or replace function get_voucher(p_id uuid)
returns jsonb as $$
  select jsonb_build_object(
    'header', (select to_jsonb(v) from vouchers v where v.id=p_id),
    'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.sno) from voucher_lines l where l.voucher_id=p_id),'[]'::jsonb)
  );
$$ language sql security definer;

-- ---- reverse a voucher's stock + lot moves (used by edit/cancel) ----
create or replace function reverse_voucher_stock(p_id uuid) returns void as $$
begin
  delete from stock_ledger where voucher_id=p_id;
  delete from lot_ledger where voucher_id=p_id;
  -- drop any lots that were *created* by this voucher (purchase) and now have no ledger rows
  delete from lot_master m where m.ref_voucher=(select voucher_no from vouchers where id=p_id)
    and not exists (select 1 from lot_ledger ll where ll.lot_id=m.id);
end; $$ language plpgsql security definer;

-- ---- edit: permission + window check, then reverse old & repost new lines ----
create or replace function edit_voucher(
  p_id uuid, p_no text, p_date date, p_posting date, p_valid date, p_ledger uuid,
  p_ref_no text, p_tax numeric, p_narration text, p_user text, p_role text, p_lines jsonb
) returns jsonb as $$
declare vt text; created timestamptz; age interval; from_b text; to_b text; ln jsonb; i int:=0;
  is_variant boolean:=false; vdir text; src text; lqty numeric; move_date date; on_hand numeric;
  lot_on boolean; lid uuid; lbal numeric; new_lot text; valid_edit boolean;
begin
  select voucher_type, created_at into vt, created from vouchers where id=p_id;
  if vt is null then return jsonb_build_object('ok',false,'msg','Voucher not found'); end if;
  age := now()-created;
  if p_role not in ('admin','can_edit') then return jsonb_build_object('ok',false,'msg','No permission to edit'); end if;
  if p_role<>'admin' and age>interval '8 hours' then return jsonb_build_object('ok',false,'msg','8-hour edit window has passed'); end if;
  select (value='true') into lot_on from app_settings where key='lot_enabled';

  -- 1) reverse existing stock effects + remove old lines
  perform reverse_voucher_stock(p_id);
  delete from voucher_lines where voucher_id=p_id;

  -- 2) update header
  update vouchers set voucher_no=p_no, voucher_date=p_date, posting_date=p_posting, valid_thru=p_valid,
    ledger_id=p_ledger, ref_no=p_ref_no, tax_rate=coalesce(p_tax,18), narration=p_narration,
    voucher_period=to_char(p_date,'Mon YYYY') where id=p_id;

  -- 3) recompute bucket map (same as post_voucher)
  case vt
    when 'PURCHASE' then from_b:='VENDOR'; to_b:='RC';
    when 'DEBIT_NOTE_RC' then from_b:='RC'; to_b:='VENDOR';
    when 'DC_OUT_JW' then from_b:='RC'; to_b:='RCCST';
    when 'RC_IN_JW' then from_b:='RCCST'; to_b:='CC';
    when 'SALES_LOCAL' then from_b:='WIPFG'; to_b:='CUSTOMER';
    when 'CREDIT_NOTE' then from_b:='CUSTOMER'; to_b:='FGR';
    when 'PROCESS_REJECTION' then from_b:='WIPFG'; to_b:='PR';
    when 'MATERIAL_REJECTION' then from_b:='WIPFG'; to_b:='MRM';
    when 'SCRAP_SALES' then from_b:='PR'; to_b:='CUSTOMER';
    when 'DEBIT_NOTE_DN' then from_b:='MRM'; to_b:='VENDOR';
    else from_b:=null; to_b:=null; end case;
  if vt in ('DC_OUT_RET','DC_OUT_REPLACE','DC_OUT_NONRET') then is_variant:=true; vdir:='OUT';
  elsif vt in ('RC_IN_RET','RC_IN_REPLACE') then is_variant:=true; vdir:='IN'; end if;

  move_date:=coalesce(p_posting,p_date);
  for ln in select * from jsonb_array_elements(p_lines) loop
    i:=i+1; lqty:=coalesce((ln->>'qty')::numeric,0); src:=nullif(ln->>'source_bucket','');
    insert into voucher_lines(voucher_id,sno,part_id,lot_id,ref_no,source_bucket,qty,invoice_qty,actual_qty,uom,unit_price,po_price,basic_value,weight,defect_type,root_cause,line_note,packages)
    values(p_id,i,(ln->>'part_id')::uuid,nullif(ln->>'lot_id','')::uuid,ln->>'ref_no',src,lqty,
      coalesce((ln->>'invoice_qty')::numeric,0),coalesce((ln->>'actual_qty')::numeric,0),coalesce(ln->>'uom','Nos'),
      coalesce((ln->>'unit_price')::numeric,0),coalesce((ln->>'po_price')::numeric,0),coalesce((ln->>'basic_value')::numeric,0),
      coalesce((ln->>'weight')::numeric,0),ln->>'defect_type',ln->>'root_cause',ln->>'line_note',(ln->'packages'));

    if is_variant then
      if src is null then raise exception 'Source bucket required for %', vt; end if;
      if vdir='OUT' then if vt='DC_OUT_NONRET' then from_b:=src; to_b:='VENDOR'; else from_b:=src; to_b:='JOBOUT'; end if;
      else from_b:='JOBOUT'; to_b:=src; end if;
    end if;

    if from_b is not null then
      if from_b not in ('VENDOR','CUSTOMER') then
        on_hand:=check_stock((ln->>'part_id')::uuid,from_b);
        if on_hand<lqty then raise exception '% edit blocked: % balance %, requested %', vt, from_b, on_hand, lqty; end if;
      end if;
      insert into stock_ledger(ledger_date,part_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no,note)
      values(move_date,(ln->>'part_id')::uuid,from_b,to_b,lqty,p_id,vt,p_no,p_narration);
      if vt='PURCHASE' and lqty>0 and lot_on then
        new_lot:=next_lot_no((ln->>'part_id')::uuid,p_ledger);
        insert into lot_master(lot_no,part_id,ledger_id,current_bucket,original_qty,ref_voucher) values(new_lot,(ln->>'part_id')::uuid,p_ledger,'RC',lqty,p_no) returning id into lid;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,'VENDOR','RC',lqty,p_id,vt,p_no);
      elsif lot_on and nullif(ln->>'lot_id','') is not null then
        lid:=(ln->>'lot_id')::uuid; lbal:=lot_balance(lid,from_b);
        if lbal<lqty then raise exception 'Lot insufficient in %: have %, need %', from_b, lbal, lqty; end if;
        insert into lot_ledger(lot_id,from_bucket,to_bucket,qty,voucher_id,voucher_type,voucher_no) values(lid,from_b,to_b,lqty,p_id,vt,p_no);
        update lot_master set current_bucket=to_b where id=lid;
      end if;
    end if;
  end loop;

  update vouchers set modify_requested=false where id=p_id;
  perform log_audit('EDIT '||vt, p_user, p_no);
  return jsonb_build_object('ok',true,'msg','Voucher updated');
end; $$ language plpgsql security definer;

-- ---- GST format validation: NN AAAAA NNNN A N (A/N) ----
create or replace function valid_gst(p_gst text) returns boolean as $$
  select p_gst is null or p_gst='' or p_gst ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}[Z]{1}[0-9A-Z]{1}$';
$$ language sql;
-- enforce on ledger writes
create or replace function ledger_gst_check() returns trigger as $$
begin if not valid_gst(new.gst_no) then raise exception 'GST No format invalid (expected 22AAAAA0000A1Z5 style).'; end if; return new; end; $$ language plpgsql;
drop trigger if exists trg_ledger_gst on ledger;
create trigger trg_ledger_gst before insert or update on ledger for each row execute function ledger_gst_check();

-- ---- per-user checkbox permissions ----
create table if not exists checkbox_perms (
  user_id uuid references app_users(id) on delete cascade,
  flag text, allowed boolean default true, primary key(user_id,flag));
create or replace function get_checkbox_perms(p_user uuid) returns table(flag text, allowed boolean) as $$
  select flag, allowed from checkbox_perms where user_id=p_user; $$ language sql security definer;
create or replace function set_checkbox_perm(p_user uuid, p_flag text, p_allowed boolean) returns void as $$
  insert into checkbox_perms(user_id,flag,allowed) values(p_user,p_flag,p_allowed)
  on conflict(user_id,flag) do update set allowed=excluded.allowed; $$ language sql security definer;
alter table checkbox_perms enable row level security;
drop policy if exists pol_checkbox_perms on checkbox_perms;
create policy pol_checkbox_perms on checkbox_perms for all using(true) with check(true);
