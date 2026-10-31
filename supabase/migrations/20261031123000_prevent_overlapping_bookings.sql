-- Protect the physical boat at the database boundary.
--
-- The browser still performs an availability check for a fast, friendly UI,
-- but that check is necessarily subject to a race when two guests submit at
-- the same time.  This trigger takes a transaction-scoped advisory lock for
-- the boat, then rejects an overlapping pending/confirmed booking.  It also
-- runs when an admin changes a booking into a blocking status or edits its
-- dates, so the admin path cannot create a conflict either.

create or replace function public.prevent_overlapping_bookings()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_listing_title text;
begin
  if new.booking_date is null
     or new.status not in ('pending', 'confirmed') then
    return new;
  end if;

  -- Use the current listing title for legacy rows that predate property_id.
  -- The same lock is therefore shared by both the modern and legacy identity
  -- forms used by get_listing_blocked_dates().
  if new.property_id is not null then
    select l.title
      into v_listing_title
      from public.listings as l
     where l.id = new.property_id;
  end if;
  v_listing_title := coalesce(v_listing_title, new.property_name);

  if v_listing_title is null or btrim(v_listing_title) = '' then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('nauka:booking:' || lower(btrim(v_listing_title)), 0)
  );

  if exists (
    select 1
      from public.bookings as b
     where b.id is distinct from new.id
       and b.booking_date is not null
       and b.status in ('pending', 'confirmed')
       and (
         b.property_id = new.property_id
         or (
           b.property_id is null
           and b.property_name = v_listing_title
         )
         or (
           new.property_id is null
           and new.property_name = b.property_name
         )
       )
       and daterange(
         b.booking_date,
         b.booking_date + greatest(coalesce(b.nights, 1), 1),
         '[)'
       ) && daterange(
         new.booking_date,
         new.booking_date + greatest(coalesce(new.nights, 1), 1),
         '[)'
       )
  ) then
    raise exception
      'The selected boat is already booked for one or more of these dates.'
      using errcode = '23P01';
  end if;

  return new;
end;
$$;

drop trigger if exists bookings_prevent_overlapping on public.bookings;
create trigger bookings_prevent_overlapping
before insert or update of property_id, property_name, booking_date, nights, status
on public.bookings
for each row execute function public.prevent_overlapping_bookings();

revoke all on function public.prevent_overlapping_bookings() from public;
notify pgrst, 'reload schema';
