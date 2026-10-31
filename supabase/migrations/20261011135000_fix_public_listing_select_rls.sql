-- Make the listings read boundary explicit after RLS is enabled.
-- Public visitors need active boats; authenticated admins need the complete
-- fleet, including draft and suspended records. This migration is additive
-- and does not change or delete listing data.

alter table public.listings enable row level security;

grant select on table public.listings to anon, authenticated;

drop policy if exists "Public can read active listings" on public.listings;
create policy "Public can read active listings"
on public.listings
for select
to anon, authenticated
using (status = 'active');

drop policy if exists "Admins can read all listings" on public.listings;
create policy "Admins can read all listings"
on public.listings
for select
to authenticated
using (exists (
  select 1
  from public.admin_users au
  where au.user_id = (select auth.uid())
));
