-- A blocked date belongs to the physical boat, not to one cruise mode.
-- Pricing remains cruise-type-specific, but a Day or Night block must make the
-- boat unavailable to both booking paths.

create or replace function public.set_booking_pricing_from_rules()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  listing_row record;
  default_row record;
  rule_row record;
  v_current_date date;
  current_rate numeric;
  calculated_total numeric := 0;
  included_guests integer;
  extra_guests integer;
  v_index integer;
begin
  if new.property_id is null or new.booking_date is null then
    return new;
  end if;
  if new.cruise_type not in ('day', 'night') then
    raise exception 'cruise_type must be day or night';
  end if;

  select l.* into listing_row
  from public.listings l
  where l.id = new.property_id;
  if not found then
    return new;
  end if;

  select * into default_row
  from public.listing_pricing_rules r
  where r.listing_id = new.property_id
    and r.cruise_type = new.cruise_type
    and r.rule_type = 'default'
  limit 1;

  included_guests := greatest(2, coalesce(listing_row.bedrooms, 1) * 2);
  extra_guests := greatest(0, coalesce(new.guests, 0) - included_guests);

  for v_index in 0..greatest(coalesce(new.nights, 1), 1) - 1 loop
    v_current_date := new.booking_date + v_index;

    -- Any admin-created block is a physical boat block. Do this lookup across
    -- both cruise types before reading the selected mode's price rule.
    select r.* into rule_row
    from public.listing_pricing_rules r
    where r.listing_id = new.property_id
      and r.rule_type = 'date'
      and r.is_blocked
      and r.valid_from <= v_current_date
      and r.valid_to >= v_current_date
    limit 1;

    if found then
      raise exception 'The boat is blocked for %', v_current_date using errcode = '23514';
    end if;

    select r.* into rule_row
    from public.listing_pricing_rules r
    where r.listing_id = new.property_id
      and r.cruise_type = new.cruise_type
      and r.rule_type = 'date'
      and r.valid_from <= v_current_date
      and r.valid_to >= v_current_date
    limit 1;

    if found then
      current_rate := rule_row.price;
    elsif not found and default_row.id is not null then
      current_rate := case
        when extract(dow from v_current_date) in (5, 6) then default_row.weekend_price
        else default_row.weekday_price
      end;
    else
      current_rate := case
        when new.cruise_type = 'day' then coalesce(listing_row.day_price, listing_row.price)
        else coalesce(listing_row.overnight_price, listing_row.weekday_price, listing_row.price)
      end;
    end if;
    if current_rate is null or current_rate <= 0 then
      raise exception 'No valid price is configured for the selected cruise type and date' using errcode = '23514';
    end if;
    if v_index = 0 then
      new.price := round(current_rate, 2);
    end if;
    calculated_total := calculated_total + current_rate + (extra_guests * 1000);
  end loop;

  new.total := round(calculated_total, 2);
  return new;
end;
$$;

-- Remove the legacy overload because the 4-argument function has a default
-- cruise type and PostgreSQL otherwise treats 3-argument calls as ambiguous.
drop function if exists public.get_listing_blocked_dates(bigint, date, date);

create or replace function public.get_listing_blocked_dates(
  p_property_id bigint,
  p_from date,
  p_to date,
  p_cruise_type text default 'night'
)
returns table(blocked_date date)
language sql
stable
security definer
set search_path = ''
as $$
  with booking_dates as (
    select gs::date as blocked_date
    from public.bookings as b
    cross join lateral generate_series(
      b.booking_date,
      b.booking_date + greatest(coalesce(b.nights, 1), 1) - 1,
      interval '1 day'
    ) as gs
    where (
        b.property_id = p_property_id
        or (
          b.property_id is null
          and b.property_name = (select l.title from public.listings as l where l.id = p_property_id)
        )
      )
      and b.booking_date is not null
      and b.booking_date <= p_to
      and b.booking_date + greatest(coalesce(b.nights, 1), 1) - 1 >= p_from
      and b.status in ('pending', 'confirmed')
  ),
  rule_dates as (
    select gs::date as blocked_date
    from public.listing_pricing_rules as r
    cross join lateral generate_series(
      greatest(r.valid_from, p_from),
      least(r.valid_to, p_to),
      interval '1 day'
    ) as gs
    where r.listing_id = p_property_id
      and r.rule_type = 'date'
      and r.is_blocked
      and r.valid_from <= p_to
      and r.valid_to >= p_from
  )
  select distinct blocked_date
  from (
    select blocked_date from booking_dates
    union all
    select blocked_date from rule_dates
  ) as all_blocked
  order by blocked_date;
$$;

grant execute on function public.get_listing_blocked_dates(bigint, date, date, text) to anon, authenticated;
notify pgrst, 'reload schema';
