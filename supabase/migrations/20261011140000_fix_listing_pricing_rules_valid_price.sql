-- Reconcile legacy listing_pricing_rules schemas with the P&D pricing model.
--
-- This migration is intentionally additive/repair-oriented:
--   * it never deletes listings, bookings, or pricing rows;
--   * it aborts before changing data when an existing row is ambiguous or
--     incompatible with the model below;
--   * it only copies an existing date value into its compatibility column
--     when the other copy is NULL. It never invents a date or changes a price.
--
-- Model:
--   default rule -> price NULL, positive weekday/weekend prices, no dates
--   custom date -> positive price, unblocked, inclusive start/end dates
--   blocked date -> price NULL, blocked, inclusive start/end dates

do $$
begin
  if to_regclass('public.listing_pricing_rules') is null then
    raise exception
      'public.listing_pricing_rules does not exist; apply the base pricing migration first';
  end if;
end
$$;

-- Some deployed projects have start_date/end_date while the original local
-- migration only declared valid_from/valid_to. Keep both column pairs because
-- the frontend sends both and older rows may contain either pair.
alter table public.listing_pricing_rules
  add column if not exists start_date date;

alter table public.listing_pricing_rules
  add column if not exists end_date date;

alter table public.listing_pricing_rules
  add column if not exists valid_from date;

alter table public.listing_pricing_rules
  add column if not exists valid_to date;

-- Default rows legitimately have no date range. The old deployed schema may
-- have made these columns NOT NULL, which caused the earlier default-row error.
alter table public.listing_pricing_rules alter column start_date drop not null;
alter table public.listing_pricing_rules alter column end_date drop not null;
alter table public.listing_pricing_rules alter column valid_from drop not null;
alter table public.listing_pricing_rules alter column valid_to drop not null;

-- Preflight existing data before any compatibility backfill or constraint
-- replacement. A failure rolls back the migration and leaves data untouched.
do $$
begin
  if exists (
    select 1
    from public.listing_pricing_rules
    where rule_type is null
       or rule_type not in ('default', 'date')
  ) then
    raise exception
      'listing_pricing_rules contains a row with an unsupported or NULL rule_type';
  end if;

  if exists (
    select 1
    from public.listing_pricing_rules
    where is_blocked is null
  ) then
    raise exception
      'listing_pricing_rules contains a row with NULL is_blocked';
  end if;

  if exists (
    select 1
    from public.listing_pricing_rules
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
    raise exception
      'listing_pricing_rules contains an incompatible default pricing row';
  end if;

  if exists (
    select 1
    from public.listing_pricing_rules
    where rule_type = 'date'
      and (
        coalesce(start_date, valid_from) is null
        or coalesce(end_date, valid_to) is null
        or coalesce(end_date, valid_to) < coalesce(start_date, valid_from)
        or (start_date is not null and valid_from is not null and start_date <> valid_from)
        or (end_date is not null and valid_to is not null and end_date <> valid_to)
        or (is_blocked = true and price is not null)
        or (is_blocked = false and (price is null or price <= 0))
      )
  ) then
    raise exception
      'listing_pricing_rules contains an incompatible date pricing or blocked row';
  end if;
end
$$;

-- Synchronize the two date-column pairs without inventing dates. This copies
-- only an already-present value and rejects conflicting values explicitly.
update public.listing_pricing_rules
set
  start_date = coalesce(start_date, valid_from),
  end_date = coalesce(end_date, valid_to),
  valid_from = coalesce(valid_from, start_date),
  valid_to = coalesce(valid_to, end_date)
where rule_type = 'date'
  and (
    start_date is null or end_date is null
    or valid_from is null or valid_to is null
  );

-- Remove the obsolete live check and the two older local checks. The new
-- single constraint below subsumes them and prevents duplicate/conflicting
-- validation paths. IF EXISTS keeps this safe across deployed variants.
alter table public.listing_pricing_rules
  drop constraint if exists listing_pricing_rules_valid_price;

alter table public.listing_pricing_rules
  drop constraint if exists listing_pricing_rules_range_check;

alter table public.listing_pricing_rules
  drop constraint if exists listing_pricing_rules_positive_prices;

alter table public.listing_pricing_rules
  add constraint listing_pricing_rules_valid_price check (
    (
      rule_type is not null
      and rule_type = 'default'
      and is_blocked is false
      and price is null
      and weekday_price is not null and weekday_price > 0
      and weekend_price is not null and weekend_price > 0
      and start_date is null and end_date is null
      and valid_from is null and valid_to is null
    )
    or
    (
      rule_type is not null
      and rule_type = 'date'
      and is_blocked is false
      and price is not null and price > 0
      and start_date is not null and end_date is not null
      and end_date >= start_date
      and valid_from is not null and valid_to is not null
      and valid_to >= valid_from
      and start_date = valid_from
      and end_date = valid_to
    )
    or
    (
      rule_type is not null
      and rule_type = 'date'
      and is_blocked is true
      and price is null
      and start_date is not null and end_date is not null
      and end_date >= start_date
      and valid_from is not null and valid_to is not null
      and valid_to >= valid_from
      and start_date = valid_from
      and end_date = valid_to
    )
  );

create or replace function public.sync_listing_pricing_rule_dates()
returns trigger
language plpgsql
as $$
begin
  if new.rule_type = 'default' then
    if new.start_date is not null
       or new.end_date is not null
       or new.valid_from is not null
       or new.valid_to is not null then
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
  end if;

  return new;
end;
$$;

drop trigger if exists listing_pricing_rules_sync_dates
  on public.listing_pricing_rules;

create trigger listing_pricing_rules_sync_dates
before insert or update on public.listing_pricing_rules
for each row
execute function public.sync_listing_pricing_rule_dates();

-- Keep PostgREST from serving the old table definition after the migration.
notify pgrst, 'reload schema';
