-- One-time cleanup requested for the booking/revenue reset.
-- Listing, pricing-rule and fleet records are intentionally untouched.
delete from public.bookings
where booking_date is null
   or booking_date <= current_date;
