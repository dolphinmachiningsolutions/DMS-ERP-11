-- =====================================================================
--  DMS ERP — FIX DUPLICATE FUNCTION SIGNATURES
-- =====================================================================
--  When a function gains new parameters, Postgres keeps the OLD version
--  alongside the new one (create-or-replace only replaces identical
--  signatures). Calls that omit the new optional parameters then match
--  BOTH and fail with "Could not choose the best candidate function".
--
--  This drops the stale old versions. Safe to run any time:
--  every drop is "if exists" and only targets outdated signatures.
-- =====================================================================

-- save_part_price: old 11-arg (before p_lb)
drop function if exists save_part_price(uuid, uuid, uuid, text, numeric, date, date, numeric, numeric, numeric, numeric);

-- admin_save_part: old 6-arg and 7-arg (before p_cumulative / p_lb)
drop function if exists admin_save_part(uuid, text, text, text, uuid, text);
drop function if exists admin_save_part(uuid, text, text, text, uuid, text, text);

-- admin_save_user: old 7-arg (before p_active)
drop function if exists admin_save_user(uuid, text, text, text, text, boolean, boolean);

-- set_module_right: old 5-arg (before edit / mark-delete / mark-edit rights)
drop function if exists set_module_right(uuid, text, boolean, boolean, boolean);

do $$ begin raise notice 'Stale function signatures removed.'; end $$;
