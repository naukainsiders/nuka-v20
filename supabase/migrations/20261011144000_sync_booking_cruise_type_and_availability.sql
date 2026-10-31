-- Keep bookings and availability aligned with the selected cruise type.
-- Existing bookings are preserved; legacy rows are inferred from their route.

alter table public.bookings
  add column if not exists cruise_type text default 'night';

update public.bookings
set cruise_type = case
  when lower(coalesce(cruise_type, '')) = 'day' then 'day'
  when route ilike '%day cruise%' then 'day'
  else 'night'
end
where cruise_type is null or cruise_type not in ('day', 'night');

alter table public.bookings
  alter column cruise_type set default 'night';
alter table public.bookings
  alter column cruise_type set not null;

alter table public.bookings
  drop constraint if exists bookings_cruise_type_check;
alter table public.bookings
  add constraint bookings_cruise_type_check check (cruise_type in ('day', 'night'));

-- The booking row is never allowed to trust a browser-calculated price. On
-- insert, derive its unit price and estimate from the selected cruise type,
-- date rules, defaults, and listing fallback prices. Admin quote updates are
-- left untouched because this trigger only runs for new guest requests.
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
    select r.* into rule_row
    from public.listing_pricing_rules r
    where r.listing_id = new.property_id
      and r.cruise_type = new.cruise_type
      and r.rule_type = 'date'
      and r.valid_from <= v_current_date
      and r.valid_to >= v_current_date
    limit 1;

    if found and rule_row.is_blocked then
      raise exception 'The selected cruise type is blocked for %', v_current_date using errcode = '23514';
    end if;
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

drop trigger if exists bookings_set_pricing_from_rules on public.bookings;
create trigger bookings_set_pricing_from_rules
before insert on public.bookings
for each row execute function public.set_booking_pricing_from_rules();

-- Include only rules for the selected cruise type. Existing bookings still
-- block the boat for every cruise mode because the boat is physically in use.
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
      greatest(r.start_date, p_from),
      least(r.end_date, p_to),
      interval '1 day'
    ) as gs
    where r.listing_id = p_property_id
      and coalesce(r.cruise_type, 'night') = case when p_cruise_type = 'day' then 'day' else 'night' end
      and r.is_blocked
      and r.start_date <= p_to
      and r.end_date >= p_from
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
