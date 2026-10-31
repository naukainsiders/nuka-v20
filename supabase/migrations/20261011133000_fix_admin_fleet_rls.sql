-- Allow Supabase-authenticated admins to manage the live fleet.
-- The admin UI already verifies membership in public.admin_users; these
-- policies make that same check enforce edits, status changes and deletes at
-- the database boundary instead of relying on browser-only permissions.

alter table public.listings enable row level security;

grant select on table public.listings to anon, authenticated;
grant insert, update, delete on table public.listings to authenticated;

drop policy if exists "Admins can insert listings" on public.listings;
create policy "Admins can insert listings"
on public.listings
for insert
to authenticated
with check (exists (
  select 1
  from public.admin_users au
  where au.user_id = (select auth.uid())
));

drop policy if exists "Admins can update listings" on public.listings;
create policy "Admins can update listings"
on public.listings
for update
to authenticated
using (exists (
  select 1
  from public.admin_users au
  where au.user_id = (select auth.uid())
))
with check (exists (
  select 1
  from public.admin_users au
  where au.user_id = (select auth.uid())
));

drop policy if exists "Admins can delete listings" on public.listings;
create policy "Admins can delete listings"
on public.listings
for delete
to authenticated
using (exists (
  select 1
  from public.admin_users au
  where au.user_id = (select auth.uid())
));
