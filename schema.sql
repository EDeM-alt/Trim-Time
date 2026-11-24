-- TRIMTIME PRODUCTION DATABASE (Supabase / PostgreSQL)
-- Run this entire file in Supabase Dashboard > SQL Editor.
create extension if not exists pgcrypto;
create extension if not exists btree_gist;

do $$ begin
  create type public.account_role as enum ('customer','barber','shop_owner','admin');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.appointment_status as enum ('pending_payment','pending_confirmation','confirmed','completed','cancelled','expired');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  role public.account_role not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.shops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id),
  name text not null,
  description text,
  location text not null,
  shop_type text not null default 'Barbershop',
  contact_phone text,
  is_active boolean not null default false,
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.barbers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(id),
  shop_id uuid not null references public.shops(id) on delete cascade,
  display_name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(id,shop_id)
);

create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  barber_id uuid not null,
  name text not null,
  description text,
  price_ghs numeric(10,2) not null check (price_ghs >= 0),
  duration_minutes integer not null check (duration_minutes between 5 and 360),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(id,shop_id),
  foreign key (barber_id,shop_id) references public.barbers(id,shop_id) on delete cascade
);

create table if not exists public.barber_working_hours (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references public.barbers(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6), -- Sunday=0
  opens_at time not null,
  closes_at time not null,
  is_day_off boolean not null default false,
  unique(barber_id,weekday),
  check (closes_at > opens_at)
);

create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id),
  shop_id uuid not null references public.shops(id),
  barber_id uuid not null,
  service_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status public.appointment_status not null default 'pending_payment',
  quoted_price_ghs numeric(10,2) not null check (quoted_price_ghs >= 0),
  customer_note text,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  foreign key (barber_id,shop_id) references public.barbers(id,shop_id),
  foreign key (service_id,shop_id) references public.services(id,shop_id),
  -- Prevents overlapping live reservations for the same barber.
  constraint no_overlapping_live_appointments exclude using gist (
    barber_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status in ('pending_payment','pending_confirmation','confirmed'))
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  customer_id uuid not null references public.profiles(id),
  provider text not null default 'paystack',
  reference text not null unique,
  amount_ghs numeric(10,2) not null check (amount_ghs > 0),
  status text not null default 'initialized' check (status in ('initialized','pending','success','failed','refunded')),
  provider_reference text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.appointments(id),
  customer_id uuid not null references public.profiles(id),
  shop_id uuid not null references public.shops(id),
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

-- Automatically create a customer profile after Supabase Auth registration.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id,full_name,phone)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),new.phone)
  on conflict (id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=auth.uid() and role='admin');
$$;

-- Atomic booking: checks service/shop, computes end time from trusted DB data,
-- then inserts. The exclusion constraint blocks double-booking under concurrency.
create or replace function public.create_booking(p_service_id uuid,p_starts_at timestamptz)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_service public.services%rowtype; v_barber public.barbers%rowtype; v_id uuid; v_end timestamptz;
begin
  if auth.uid() is null then raise exception 'Please sign in before booking.'; end if;
  if p_starts_at <= now() then raise exception 'Choose a future appointment time.'; end if;
  select * into v_service from public.services where id=p_service_id and is_active=true;
  if not found then raise exception 'This service is not currently available.'; end if;
  select * into v_barber from public.barbers where id=v_service.barber_id and is_active=true;
  if not found then raise exception 'This barber is not currently accepting bookings.'; end if;
  if not exists(select 1 from public.shops where id=v_service.shop_id and is_active=true) then
    raise exception 'This shop is not currently accepting bookings.';
  end if;
  v_end := p_starts_at + make_interval(mins=>v_service.duration_minutes);
  -- All appointment times are interpreted in Ghana local time (Africa/Accra).
  if not exists (select 1 from public.barber_working_hours h where h.barber_id=v_barber.id and h.weekday=extract(dow from (p_starts_at at time zone 'Africa/Accra'))::smallint and h.is_day_off=false and (p_starts_at at time zone 'Africa/Accra')::time >= h.opens_at and (v_end at time zone 'Africa/Accra')::time <= h.closes_at) then
    raise exception 'This barber has not published working hours for that time, or the requested time is outside their schedule.';
  end if;
  insert into public.appointments(customer_id,shop_id,barber_id,service_id,starts_at,ends_at,status,quoted_price_ghs)
  values(auth.uid(),v_service.shop_id,v_barber.id,v_service.id,p_starts_at,v_end,'pending_payment',v_service.price_ghs)
  returning id into v_id;
  return v_id;
exception when exclusion_violation then
  raise exception 'Sorry, this barber has just been booked for that time. Please choose another slot.';
end; $$;

-- Prevent staff from confirming an appointment before a verified successful payment.
create or replace function public.guard_appointment_status()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status in ('pending_confirmation','confirmed') and not exists (
    select 1 from public.payments p where p.appointment_id=new.id and p.status='success'
  ) then raise exception 'A verified successful payment is required before confirmation.'; end if;
  if old.status='pending_payment' and new.status not in ('pending_payment','pending_confirmation','cancelled') then raise exception 'Invalid appointment status transition.'; end if;
  if old.status='pending_confirmation' and new.status not in ('pending_confirmation','confirmed','cancelled') then raise exception 'Invalid appointment status transition.'; end if;
  if old.status='confirmed' and new.status not in ('confirmed','completed','cancelled') then raise exception 'Invalid appointment status transition.'; end if;
  if new.status='completed' and old.status<>'confirmed' then
    raise exception 'Only a confirmed appointment can be marked completed.';
  end if;
  if old.status in ('completed','expired') and new.status<>old.status then
    raise exception 'This appointment can no longer be changed.';
  end if;
  return new;
end; $$;
drop trigger if exists appointment_status_guard on public.appointments;
create trigger appointment_status_guard before update of status on public.appointments
for each row execute function public.guard_appointment_status();

alter table public.profiles enable row level security;
alter table public.shops enable row level security;
alter table public.barbers enable row level security;
alter table public.services enable row level security;
alter table public.barber_working_hours enable row level security;
alter table public.appointments enable row level security;
alter table public.payments enable row level security;
alter table public.reviews enable row level security;

drop policy if exists "profiles read self admin" on public.profiles;
create policy "profiles read self admin" on public.profiles for select using (id=auth.uid() or public.is_admin());
drop policy if exists "profiles update self" on public.profiles;
create policy "profiles update self" on public.profiles for update using (id=auth.uid()) with check (id=auth.uid());
-- Customers can edit only their own name and phone, never their role.
revoke update on public.profiles from anon, authenticated;
grant update(full_name,phone) on public.profiles to authenticated;

drop policy if exists "public read active shops" on public.shops;
create policy "public read active shops" on public.shops for select using (is_active=true or owner_id=auth.uid() or public.is_admin());
drop policy if exists "shop owner manage shop" on public.shops;
drop policy if exists "shop owner create inactive shop" on public.shops;
create policy "shop owner create inactive shop" on public.shops for insert with check (owner_id=auth.uid() and is_active=false);
drop policy if exists "shop owner edit own shop" on public.shops;
create policy "shop owner edit own shop" on public.shops for update using (owner_id=auth.uid()) with check (owner_id=auth.uid());
-- Owners cannot self-verify or publish a shop; activation is an admin operation.
revoke insert,update,delete on public.shops from anon,authenticated;
grant insert on public.shops to authenticated;
grant update(name,description,location,shop_type,contact_phone) on public.shops to authenticated;

drop policy if exists "public read active barbers" on public.barbers;
create policy "public read active barbers" on public.barbers for select using (is_active=true or user_id=auth.uid() or public.is_admin());
drop policy if exists "barber owner manage profile" on public.barbers;
create policy "barber owner manage profile" on public.barbers for all using (user_id=auth.uid() or public.is_admin()) with check (user_id=auth.uid() or public.is_admin());

drop policy if exists "public read active services" on public.services;
create policy "public read active services" on public.services for select using (is_active=true or public.is_admin() or exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid()));
drop policy if exists "shop owner manage services" on public.services;
create policy "shop owner manage services" on public.services for all using (public.is_admin() or exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid())) with check (public.is_admin() or exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid()));

drop policy if exists "barber read own hours" on public.barber_working_hours;
create policy "barber read own hours" on public.barber_working_hours for select using (exists(select 1 from public.barbers b where b.id=barber_id and (b.user_id=auth.uid() or public.is_admin())));
drop policy if exists "barber manage own hours" on public.barber_working_hours;
create policy "barber manage own hours" on public.barber_working_hours for all using (exists(select 1 from public.barbers b where b.id=barber_id and (b.user_id=auth.uid() or public.is_admin()))) with check (exists(select 1 from public.barbers b where b.id=barber_id and (b.user_id=auth.uid() or public.is_admin())));

drop policy if exists "customer barber admin read appointments" on public.appointments;
create policy "customer barber admin read appointments" on public.appointments for select using (
 customer_id=auth.uid() or public.is_admin() or exists(select 1 from public.barbers b where b.id=barber_id and b.user_id=auth.uid()) or exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid())
);
drop policy if exists "barber shop admin update appointments" on public.appointments;
create policy "barber shop admin update appointments" on public.appointments for update using (
 public.is_admin() or exists(select 1 from public.barbers b where b.id=barber_id and b.user_id=auth.uid()) or exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid())
) with check (
 public.is_admin() or exists(select 1 from public.barbers b where b.id=barber_id and b.user_id=auth.uid()) or exists(select 1 from public.shops s where s.id=shop_id and s.owner_id=auth.uid())
);
-- Inserts are deliberately restricted to the create_booking RPC. Staff may update only status.
revoke insert,update,delete on public.appointments from anon,authenticated;
grant update(status) on public.appointments to authenticated;
revoke insert,update,delete on public.payments from anon,authenticated;
revoke insert,delete on public.profiles from anon,authenticated;
revoke all on function public.create_booking(uuid,timestamptz) from public,anon;
grant execute on function public.create_booking(uuid,timestamptz) to authenticated;

drop policy if exists "customer read own payments" on public.payments;
create policy "customer read own payments" on public.payments for select using (customer_id=auth.uid() or public.is_admin());
-- Payment records are written only by trusted server-side functions using service-role credentials.

drop policy if exists "public read reviews" on public.reviews;
create policy "public read reviews" on public.reviews for select using (true);
drop policy if exists "customer create own review" on public.reviews;
create policy "customer create own review" on public.reviews for insert with check (customer_id=auth.uid() and exists(select 1 from public.appointments a where a.id=appointment_id and a.customer_id=auth.uid() and a.status='completed'));

grant execute on function public.is_admin() to authenticated,anon;

-- Read permissions are still filtered by the RLS policies above.
revoke insert,update,delete on public.barbers from anon,authenticated;
grant select on public.shops,public.barbers,public.services to anon,authenticated;
grant select on public.profiles,public.appointments,public.payments,public.reviews,public.barber_working_hours to authenticated;
grant insert on public.reviews to authenticated;
