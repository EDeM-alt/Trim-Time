# TrimTime — commercial launch starter

This package upgrades the earlier browser-only prototype into a real multi-user application **scaffold**. It contains a customer-facing booking website, Supabase database schema with row-level security, atomic booking logic that prevents overlapping appointments, account registration/sign-in, a barber workspace, and Paystack server endpoints for Mobile Money/card checkout.

## Important launch status

This is **not yet a live commercial service**. It becomes live only after the owner creates and configures the Supabase and Paystack accounts, runs the SQL, enters the public Supabase project values, sets server secrets, deploys the website, configures the payment webhook, creates the first verified partner records, and tests real payments. I cannot register accounts, complete merchant KYC, buy a domain, accept legal terms, or deploy under your ownership from this package alone.

The public page intentionally does not show invented sample barbers or pretend that the supplied numbers are already connected to an automated MoMo merchant account.

## What's included

- `index.html` — customer website with sign-up/sign-in, shop discovery, booking request, customer booking history and barber workspace.
- `config.js` — public Supabase URL and publishable/anon key settings; add only public values here.
- `schema.sql` — database tables, account roles, Row Level Security, atomic booking function, overlapping-slot protection and working-hours checks.
- `api/paystack-initialize.js` — server-side Paystack transaction initialization; checks the signed-in customer owns the appointment and reads the amount from the database.
- `api/paystack-webhook.js` — verifies Paystack webhook signature and independently verifies the transaction before marking payment successful.
- `payment-return.html` — customer return page after checkout.
- `.env.example` — server-only environment variable template. Never publish real secrets in this file.
- `demo-dashboard.html` — earlier localStorage prototype, retained only as a reference/demo.

## A. Create the Supabase database

1. Create a project at [Supabase](https://supabase.com/).
2. Open **SQL Editor** in the Supabase dashboard.
3. Paste and run the complete contents of `schema.sql`.
4. In **Project Settings → API**, copy the Project URL and the publishable/anon key.
5. Put those two public values in `config.js`:

```js
window.TRIMTIME_CONFIG = {
  SUPABASE_URL: 'https://YOUR_PROJECT.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY',
  CURRENCY: 'GHS',
  SUPPORT_NUMBERS: ['0204275051', '0557418712']
};
```

Do **not** put the Supabase `service_role` key in `config.js` or in browser code.

6. In Supabase **Authentication → URL Configuration**, set your deployed website URL as the Site URL and add it to Redirect URLs.
7. In **Authentication → Providers → Email**, enable email/password and decide whether email confirmation is required. Keep confirmation enabled for a public launch.

## B. Promote the platform administrator

1. Register your own account through the website after it is deployed/configured.
2. In Supabase **Authentication → Users**, copy your user UUID.
3. In SQL Editor run this once, replacing the UUID:

```sql
update public.profiles set role='admin' where id='YOUR_AUTH_USER_UUID';
```

Never make public sign-up automatically create an administrator. Admin roles must be assigned manually by the project owner.

## C. Add the first real partner shop, barber, service and hours

Only add a shop after its owner has agreed to participate and its details/prices/hours have been checked. Register the shop owner and barber as normal TrimTime users first. Copy their user UUIDs from Authentication → Users.

Run a carefully edited SQL script like this in Supabase SQL Editor (replace every placeholder):

```sql
-- Give the shop owner the partner role.
update public.profiles set role='shop_owner' where id='SHOP_OWNER_AUTH_UUID';
-- Create the shop as inactive. An administrator must verify it before it appears publicly.
insert into public.shops(owner_id,name,description,location,shop_type,contact_phone,is_active)
values('SHOP_OWNER_AUTH_UUID','REAL SHOP NAME','Short verified description','Verified UCC-area location','Barbershop','SHOP CONTACT',false)
returning id;
-- After an admin verifies the shop, activate it using the shop UUID returned above.
update public.shops set is_active=true, verified_at=now() where id='SHOP_UUID';
-- Create the barber profile (barber must have registered first).
update public.profiles set role='barber' where id='BARBER_AUTH_UUID';
insert into public.barbers(user_id,shop_id,display_name)
values('BARBER_AUTH_UUID','SHOP_UUID','BARBER DISPLAY NAME') returning id;
-- Create a service for that barber.
insert into public.services(shop_id,barber_id,name,price_ghs,duration_minutes)
values('SHOP_UUID','BARBER_UUID','Classic haircut',35.00,30);
-- Publish that barber's working hours. weekday: Sunday=0, Monday=1 ... Saturday=6.
insert into public.barber_working_hours(barber_id,weekday,opens_at,closes_at,is_day_off) values
('BARBER_UUID',1,'08:00','18:00',false),
('BARBER_UUID',2,'08:00','18:00',false),
('BARBER_UUID',3,'08:00','18:00',false),
('BARBER_UUID',4,'08:00','18:00',false),
('BARBER_UUID',5,'08:00','18:00',false),
('BARBER_UUID',6,'09:00','16:00',false),
('BARBER_UUID',0,'00:00','00:01',true);
```

Note: the database checks the barber's published working hours in Ghana local time. The example prices/hours above are illustrative only; replace them with the partner's real approved information. Add more barbers and services as needed.

## D. Enable Paystack Mobile Money

1. Create a business/merchant account with [Paystack Ghana](https://paystack.com/gh/), complete its verification/KYC and confirm that Mobile Money is enabled for the account.
2. Start in **test mode**. Obtain the test secret key from the Paystack dashboard.
3. Deploy this project to Vercel (or another Node-compatible host that supports the included serverless functions).
4. In the hosting provider's environment settings, add the variables from `.env.example`:
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY` — server-side only; never expose it in the browser.
   - `PAYSTACK_SECRET_KEY` — use the test secret key while testing.
   - `PUBLIC_SITE_URL` — the exact deployed HTTPS website URL.
5. In the Paystack dashboard, set the webhook URL to:
   `https://YOUR_DOMAIN/api/paystack-webhook`
6. Confirm that the website callback page is reachable at:
   `https://YOUR_DOMAIN/payment-return.html`
7. Test with Paystack test mode and test credentials/instructions supplied by Paystack. Do not accept real customer money until test payments, webhook verification, booking status transitions, cancellation/refund handling and reconciliation have been tested.
8. After Paystack approves the merchant for live transactions, replace the test secret with the live secret in the hosting environment and redeploy. Never put either secret in frontend files.

The current payment endpoint charges the **full service price**. If TrimTime decides to collect only a deposit, that amount and the balance-collection process must be agreed and implemented before launch; do not advertise a deposit until that code is changed and tested.

## E. Deploy the website

1. Upload this folder to a private GitHub repository owned by TrimTime.
2. Import that repository into [Vercel](https://vercel.com/).
3. Add the server environment variables listed above.
4. Deploy and attach a domain owned by TrimTime. Use HTTPS.
5. Add the final domain to Supabase Authentication URL Configuration.
6. Redeploy after updating `config.js` with the Supabase public URL and publishable/anon key.

The `api/` directory is intended for Vercel Node serverless functions. If you use a different host, adapt the two API routes to that host's serverless-function format.

## F. Important operational/security checks before public launch

- Verify every shop's identity, owner consent, location, prices, services, barber identity and working hours.
- The shop owner cannot self-verify a shop through the public database policy; the admin activates it after checks.
- Assign barber/shop-owner/admin roles manually. Never let a user select their own role at sign-up.
- Enable email verification, strong passwords and multi-factor authentication for administrators.
- Configure password reset and test account recovery.
- Test two customers booking the same barber/time simultaneously. The database exclusion constraint should reject the second overlapping reservation.
- Test the booking function with closed days, before-opening times, after-closing times and appointments crossing closing time.
- Set up a process to expire abandoned `pending_payment` appointments; the current scaffold does not yet automatically release unpaid reservations after a timeout.
- Define cancellation, refund, no-show and dispute policies before taking money.
- Set up backups, uptime/error monitoring, access review and incident response.
- Add WhatsApp Business Platform/SMS provider credentials only when ready. Current footer links open the supplied phone numbers in phone/WhatsApp; automated outbound WhatsApp/SMS notifications are not yet connected.
- Review Ghana data-protection obligations, publish a privacy notice and terms, and obtain appropriate consent before collecting customer data.
- Confirm the legal business identity, merchant settlement account and customer support process. The two numbers supplied (0204275051 and 0557418712) are displayed as contact/WhatsApp numbers; they are not automatically configured as Paystack settlement accounts.

## Known limitations to finish before a full public commercial launch

- No automatic unpaid-booking expiry job yet.
- No automated WhatsApp/SMS notifications yet; contact links are present.
- No customer cancellation/refund interface yet.
- No full shop-owner onboarding interface; first partner records are created by the administrator in Supabase.
- No admin web console for verifying shops or managing all users; administrator setup is done in Supabase for this first release.
- No map/geolocation, reviews UI, analytics, receipt email or production monitoring configuration.
- The barber workspace shows appointment IDs in shortened form rather than exposing another customer's full profile.

This is a genuine backend-connected launch foundation, but it must pass the setup and acceptance tests above before it should be marketed as fully operational.
