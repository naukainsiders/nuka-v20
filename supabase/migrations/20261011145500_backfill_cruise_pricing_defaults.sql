-- Seed the new per-cruise defaults from the existing listing prices.
-- This keeps current customer-facing prices unchanged while making the new
-- pricing table authoritative immediately after deployment.

with source as (
  select
    l.id,
    coalesce(nullif(l.day_price, 0), nullif(l.price, 0)) as day_price,
    coalesce(nullif(l.weekday_price, 0), nullif(l.overnight_price, 0), nullif(l.price, 0)) as night_weekday_price,
    coalesce(nullif(l.weekend_price, 0), nullif(l.overnight_price, 0), nullif(l.price, 0)) as night_weekend_price
  from public.listings l
)
insert into public.listing_pricing_rules (
  listing_id, rule_type, cruise_type, price, is_blocked,
  valid_from, valid_to, start_date, end_date,
  weekday_price, weekend_price
)
select id, 'default', 'day', null, false, null, null, null, null, day_price, day_price
from source
where day_price is not null and day_price > 0
on conflict do nothing;

with source as (
  select
    l.id,
    coalesce(nullif(l.weekday_price, 0), nullif(l.overnight_price, 0), nullif(l.price, 0)) as night_weekday_price,
    coalesce(nullif(l.weekend_price, 0), nullif(l.overnight_price, 0), nullif(l.price, 0)) as night_weekend_price
  from public.listings l
)
insert into public.listing_pricing_rules (
  listing_id, rule_type, cruise_type, price, is_blocked,
  valid_from, valid_to, start_date, end_date,
  weekday_price, weekend_price
)
select id, 'default', 'night', null, false, null, null, null, null, night_weekday_price, night_weekend_price
from source
where night_weekday_price is not null
  and night_weekend_price is not null
  and night_weekday_price > 0
  and night_weekend_price > 0
on conflict do nothing;
