-- Store Day Cruise and Night / Overnight Cruise pricing independently.
-- This migration is additive and aborts before changing data when existing
-- pricing rows cannot be mapped safely to the new model.

do $$
begin
  if to_regclass('public.listing_pricing_rules') is null then
    raise exception 'public.listing_pricing_rules does not exist; apply the base pricing migration first';
  end if;
end
$$;

alter table public.listing_pricing_rules
  add column if not exists cruise_type text default 'night';

alter table public.listing_pricing_rules
  add column if not exists rule_type text;
alter table public.listing_pricing_rules
  add column if not exists start_date date;
alter table public.listing_pricing_rules
  add column if not exists end_date date;
alter table public.listing_pricing_rules
  add column if not exists valid_from date;
alter table public.listing_pricing_rules
  add column if not exists valid_to date;
alter table public.listing_pricing_rules
  add column if not exists weekday_price numeric(12, 2);
alter table public.listing_pricing_rules
  add column if not exists weekend_price numeric(12, 2);

-- Existing pricing rows represent the legacy nightly model. Keep them as
-- night rules; new day rules are created explicitly by the pricing editor.
update public.listing_pricing_rules
set cruise_type = 'night'
where cruise_type is null;

-- Recover the rule type only when the existing row already contains enough
-- information to distinguish a default from a date rule.
update public.listing_pricing_rules
set rule_type = case
  when start_date is not null or end_date is not null
    or valid_from is not null or valid_to is not null
    or is_blocked = true or price is not null then 'date'
  else 'default'
end
where rule_type is null;

-- The old valid_price constraint rejects valid default rows because their
-- price column is intentionally NULL. Remove only the obsolete validation;
-- the complete model-specific constraint is added below in the same
-- transaction.
alter table public.listing_pricing_rules
  drop constraint if exists listing_pricing_rules_valid_price;
alter table public.listing_pricing_rules
  drop constraint if exists listing_pricing_rules_valid_range;
alter table public.listing_pricing_rules
  drop constraint if exists listing_pricing_rules_date_fields_check;
alter table public.listing_pricing_rules
  drop constraint if exists listing_pricing_rules_range_check;
alter table public.listing_pricing_rules
  drop constraint if exists listing_pricing_rules_positive_prices;

alter table public.listing_pricing_rules
  alter column start_date drop not null;
alter table public.listing_pricing_rules
  alter column end_date drop not null;
alter table public.listing_pricing_rules
  alter column valid_from drop not null;
alter table public.listing_pricing_rules
  alter column valid_to drop not null;

-- Keep both date pairs synchronized for compatibility with older clients.
update public.listing_pricing_rules
set
  start_date = coalesce(start_date, valid_from),
  end_date = coalesce(end_date, valid_to),
  valid_from = coalesce(valid_from, start_date),
  valid_to = coalesce(valid_to, end_date)
where rule_type = 'date';

do $$
begin
  if exists (
    select 1 from public.listing_pricing_rules
    where cruise_type not in ('day', 'night')
  ) then
    raise exception 'listing_pricing_rules contains an unsupported cruise_type';
  end if;

  if exists (
    select 1 from public.listing_pricing_rules
    where rule_type not in ('default', 'date') or rule_type is null
  ) then
    raise exception 'listing_pricing_rules contains an unsupported or NULL rule_type';
  end if;

  if exists (
    select 1 from public.listing_pricing_rules
    where rule_type = 'default'
      and (
        is_blocked is distinct from false
        or price is not null
        or weekday_price is null or weekday_price <= 0
        or weekend_price is null or weekend_price <= 0
        or start_date is not null or end_date is not null
        or valid_from is not null or valid_to is not null
      )
  ) then
    raise exception 'listing_pricing_rules contains an incompatible default pricing row';
  end if;

  if exists (
    select 1 from public.listing_pricing_rules
    where rule_type = 'date'
      and (
        start_date is null or end_date is null
        or valid_from is null or valid_to is null
        or start_date <> valid_from or end_date <> valid_to
        or end_date < start_date or valid_to < valid_from
        or (is_blocked = true and price is not null)
        or (is_blocked = false and (price is null or price <= 0))
      )
  ) then
    raise exception 'listing_pricing_rules contains an incompatible date pricing or blocked row';
  end if;

  if exists (
    select 1
    from public.listing_pricing_rules a
    join public.listing_pricing_rules b
      on b.id > a.id
     and b.listing_id = a.listing_id
     and b.cruise_type = a.cruise_type
     and b.rule_type = a.rule_type
     and (a.rule_type = 'default'
       or (a.valid_from, a.valid_to) = (b.valid_from, b.valid_to))
  ) then
    raise exception 'listing_pricing_rules contains duplicate rules for a listing and cruise type';
  end if;

  if exists (
    select 1
    from public.listing_pricing_rules a
    join public.listing_pricing_rules b
      on b.id > a.id
     and a.rule_type = 'date'
     and b.rule_type = 'date'
     and b.listing_id = a.listing_id
     and b.cruise_type = a.cruise_type
     and a.valid_from <= b.valid_to
     and b.valid_from <= a.valid_to
  ) then
    raise exception 'listing_pricing_rules contains overlapping date ranges for a listing and cruise type';
  end if;
end
$$;

alter table public.listing_pricing_rules
  alter column cruise_type set default 'night';
alter table public.listing_pricing_rules
  alter column cruise_type set not null;
alter table public.listing_pricing_rules
  alter column rule_type set not null;
alter table public.listing_pricing_rules
  alter column is_blocked set default false;
alter table public.listing_pricing_rules
  alter column is_blocked set not null;

alter table public.listing_pricing_rules
  add constraint listing_pricing_rules_valid_price check (
    cruise_type in ('day', 'night')
    and (
      (
        rule_type = 'default'
        and is_blocked is false
        and price is null
        and weekday_price is not null and weekday_price > 0 and weekday_price <= 9999999999.99
        and weekend_price is not null and weekend_price > 0 and weekend_price <= 9999999999.99
        and start_date is null and end_date is null
        and valid_from is null and valid_to is null
      )
      or
      (
        rule_type = 'date'
        and is_blocked is false
        and price is not null and price > 0 and price <= 9999999999.99
        and start_date is not null and end_date is not null and end_date >= start_date
        and valid_from is not null and valid_to is not null and valid_to >= valid_from
        and start_date = valid_from and end_date = valid_to
      )
      or
      (
        rule_type = 'date'
        and is_blocked is true
        and price is null
        and start_date is not null and end_date is not null and end_date >= start_date
        and valid_from is not null and valid_to is not null and valid_to >= valid_from
        and start_date = valid_from and end_date = valid_to
      )
    )
  );

drop index if exists public.listing_pricing_rules_default_uq;
drop index if exists public.listing_pricing_rules_date_range_uq;
create unique index listing_pricing_rules_default_uq
  on public.listing_pricing_rules (listing_id, cruise_type)
  where rule_type = 'default';
create unique index listing_pricing_rules_date_range_uq
  on public.listing_pricing_rules (listing_id, cruise_type, valid_from, valid_to)
  where rule_type = 'date';
create index if not exists listing_pricing_rules_lookup_idx
  on public.listing_pricing_rules (listing_id, cruise_type, valid_from, valid_to);

create or replace function public.sync_listing_pricing_rule_dates()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.cruise_type not in ('day', 'night') then
    raise exception 'cruise_type must be day or night';
  end if;

  if new.rule_type = 'default' then
    if new.start_date is not null or new.end_date is not null
       or new.valid_from is not null or new.valid_to is not null then
      raise exception 'Default pricing rules cannot have a date range';
    end if;
  elsif new.rule_type = 'date' then
    if new.start_date is null then new.start_date := new.valid_from; end if;
    if new.end_date is null then new.end_date := new.valid_to; end if;
    if new.valid_from is null then new.valid_from := new.start_date; end if;
    if new.valid_to is null then new.valid_to := new.end_date; end if;
    if new.start_date is distinct from new.valid_from
       or new.end_date is distinct from new.valid_to then
      raise exception 'start/end dates must match valid_from/valid_to';
    end if;
  else
    raise exception 'rule_type must be default or date';
  end if;
  return new;
end;
$$;

create or replace function public.prevent_listing_pricing_rule_overlap()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  new_from date := coalesce(new.valid_from, new.start_date);
  new_to date := coalesce(new.valid_to, new.end_date);
begin
  if new.rule_type = 'date' and new_from is not null and new_to is not null then
    if exists (
      select 1
      from public.listing_pricing_rules existing
      where existing.id is distinct from new.id
        and existing.listing_id = new.listing_id
        and existing.cruise_type = new.cruise_type
        and existing.rule_type = 'date'
        and coalesce(existing.valid_from, existing.start_date) <= new_to
        and new_from <= coalesce(existing.valid_to, existing.end_date)
    ) then
      raise exception 'Date range overlaps an existing rule for this listing and cruise type';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists listing_pricing_rules_sync_dates on public.listing_pricing_rules;
drop trigger if exists listing_pricing_rules_prevent_overlap on public.listing_pricing_rules;
drop trigger if exists listing_pricing_rules_00_sync_dates on public.listing_pricing_rules;
drop trigger if exists listing_pricing_rules_10_prevent_overlap on public.listing_pricing_rules;
create trigger listing_pricing_rules_00_sync_dates
before insert or update on public.listing_pricing_rules
for each row execute function public.sync_listing_pricing_rule_dates();
create trigger listing_pricing_rules_10_prevent_overlap
before insert or update on public.listing_pricing_rules
for each row execute function public.prevent_listing_pricing_rule_overlap();

create or replace function public.set_listing_pricing_rules_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

drop trigger if exists listing_pricing_rules_updated_at on public.listing_pricing_rules;
create trigger listing_pricing_rules_updated_at
before update on public.listing_pricing_rules
for each row execute function public.set_listing_pricing_rules_updated_at();

alter table public.listing_pricing_rules enable row level security;
grant select on table public.listing_pricing_rules to anon, authenticated;
grant insert, update, delete on table public.listing_pricing_rules to authenticated;

drop policy if exists "pricing_rules_public_select" on public.listing_pricing_rules;
create policy "pricing_rules_public_select"
on public.listing_pricing_rules
for select to anon, authenticated
using (true);

drop policy if exists "pricing_rules_admin_insert" on public.listing_pricing_rules;
create policy "pricing_rules_admin_insert"
on public.listing_pricing_rules
for insert to authenticated
with check (exists (select 1 from public.admin_users au where au.user_id = (select auth.uid())));

drop policy if exists "pricing_rules_admin_update" on public.listing_pricing_rules;
create policy "pricing_rules_admin_update"
on public.listing_pricing_rules
for update to authenticated
using (exists (select 1 from public.admin_users au where au.user_id = (select auth.uid())))
with check (exists (select 1 from public.admin_users au where au.user_id = (select auth.uid())));

drop policy if exists "pricing_rules_admin_delete" on public.listing_pricing_rules;
create policy "pricing_rules_admin_delete"
on public.listing_pricing_rules
for delete to authenticated
using (exists (select 1 from public.admin_users au where au.user_id = (select auth.uid())));

do $$
declare
  pricing_sequence regclass := pg_get_serial_sequence('public.listing_pricing_rules', 'id');
begin
  if pricing_sequence is not null then
    execute format('revoke all on sequence %s from anon, authenticated', pricing_sequence);
    execute format('grant usage, select on sequence %s to authenticated', pricing_sequence);
  end if;
end
$$;

-- Atomic admin save: defaults and date rules for one listing/type are changed
-- together, so a failed insert cannot leave a half-saved calendar behind.
create or replace function public.save_listing_pricing(
  p_listing_id bigint,
  p_cruise_type text,
  p_weekday_price numeric,
  p_weekend_price numeric,
  p_rules jsonb default '[]'::jsonb
)
returns setof public.listing_pricing_rules
language plpgsql
set search_path = public
as $$
declare
  v_default_id bigint;
  v_item jsonb;
  v_from date;
  v_to date;
  v_price numeric;
  v_blocked boolean;
begin
  if (select auth.uid()) is null
     or not exists (select 1 from public.admin_users au where au.user_id = (select auth.uid())) then
    raise exception 'Only an authorized admin can save listing pricing' using errcode = '42501';
  end if;
  if not exists (select 1 from public.listings where id = p_listing_id) then
    raise exception 'The selected listing does not exist';
  end if;
  if p_cruise_type not in ('day', 'night') then
    raise exception 'cruise_type must be day or night';
  end if;
  if p_weekday_price is null or p_weekday_price <= 0 or p_weekday_price > 9999999999.99
     or p_weekend_price is null or p_weekend_price <= 0 or p_weekend_price > 9999999999.99 then
    raise exception 'Weekday and weekend prices must be greater than zero and within the supported currency range';
  end if;
  if jsonb_typeof(coalesce(p_rules, '[]'::jsonb)) <> 'array' then
    raise exception 'Pricing rules must be a JSON array';
  end if;

  select id into v_default_id
  from public.listing_pricing_rules
  where listing_id = p_listing_id
    and cruise_type = p_cruise_type
    and rule_type = 'default'
  limit 1;

  if v_default_id is null then
    insert into public.listing_pricing_rules (
      listing_id, cruise_type, rule_type, start_date, end_date,
      valid_from, valid_to, weekday_price, weekend_price, price,
      is_blocked, created_by
    ) values (
      p_listing_id, p_cruise_type, 'default', null, null,
      null, null, round(p_weekday_price, 2), round(p_weekend_price, 2), null,
      false, (select auth.uid())
    );
  else
    update public.listing_pricing_rules
    set weekday_price = round(p_weekday_price, 2),
        weekend_price = round(p_weekend_price, 2),
        price = null,
        is_blocked = false,
        created_by = (select auth.uid())
    where id = v_default_id;
  end if;

  delete from public.listing_pricing_rules
  where listing_id = p_listing_id
    and cruise_type = p_cruise_type
    and rule_type = 'date';

  for v_item in select value from jsonb_array_elements(coalesce(p_rules, '[]'::jsonb)) loop
    begin
      v_from := (v_item->>'from')::date;
      v_to := (v_item->>'to')::date;
    exception when others then
      raise exception 'Each pricing rule must contain valid from and to dates';
    end;
    v_blocked := coalesce((v_item->>'blocked')::boolean, false);
    if v_from is null or v_to is null or v_from > v_to then
      raise exception 'Each pricing rule must have a valid inclusive date range';
    end if;
    if v_blocked then
      if nullif(trim(v_item->>'price'), '') is not null then
        raise exception 'Blocked date ranges cannot contain a price';
      end if;
      v_price := null;
    else
      begin
        v_price := round((v_item->>'price')::numeric, 2);
      exception when others then
        raise exception 'Every custom date range price must be numeric';
      end;
      if v_price is null or v_price <= 0 or v_price > 9999999999.99 then
        raise exception 'Every custom date range price must be greater than zero and within the supported currency range';
      end if;
    end if;
    insert into public.listing_pricing_rules (
      listing_id, cruise_type, rule_type, start_date, end_date,
      valid_from, valid_to, weekday_price, weekend_price, price,
      is_blocked, created_by
    ) values (
      p_listing_id, p_cruise_type, 'date', v_from, v_to,
      v_from, v_to, null, null, v_price,
      v_blocked, (select auth.uid())
    );
  end loop;

  return query
  select * from public.listing_pricing_rules
  where listing_id = p_listing_id and cruise_type = p_cruise_type
  order by rule_type, valid_from nulls first;
end;
$$;

revoke all on function public.save_listing_pricing(bigint, text, numeric, numeric, jsonb) from public, anon;
grant execute on function public.save_listing_pricing(bigint, text, numeric, numeric, jsonb) to authenticated;

notify pgrst, 'reload schema';
