-- Keep one authoritative policy set for the new pricing workflow.
-- The older migrations left equivalent permissive policies in place, which
-- caused Supabase's multiple_permissive_policies advisor warning and made
-- policy evaluation unnecessarily expensive.

drop policy if exists "Public can read listing pricing rules" on public.listing_pricing_rules;
drop policy if exists "Admins can delete listing pricing rules" on public.listing_pricing_rules;
drop policy if exists "Admins can insert listing pricing rules" on public.listing_pricing_rules;
drop policy if exists "Admins can update listing pricing rules" on public.listing_pricing_rules;
drop policy if exists "listing_pricing_rules_admin_select" on public.listing_pricing_rules;
drop policy if exists "listing_pricing_rules_admin_delete" on public.listing_pricing_rules;
drop policy if exists "listing_pricing_rules_admin_insert" on public.listing_pricing_rules;
drop policy if exists "listing_pricing_rules_admin_update" on public.listing_pricing_rules;

create index if not exists listing_pricing_rules_created_by_idx
  on public.listing_pricing_rules (created_by);

-- This legacy helper is intentionally superseded by save_listing_pricing.
-- It is retained for compatibility but no longer exposed through PostgREST.
revoke all on function public.admin_set_listing_pricing_rule(bigint, date, date, numeric, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_set_listing_pricing_rule(bigint, date, date, numeric, boolean)
  to service_role;
