-- Wat op de echte server Supabase Auth en de installatie klaarzetten,
-- nagebootst voor de proefversie in de browser.
create role anon nologin;
create role authenticated nologin;
create schema extensions;
create extension pgcrypto schema extensions;
create schema auth;
create table auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text unique not null,
  encrypted_password text,
  raw_user_meta_data jsonb not null default '{}',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth, extensions to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
