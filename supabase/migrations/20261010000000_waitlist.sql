-- Lofer waitlist.
--
-- How it works (see supabase/README.md for the full picture):
--   * The website calls two database functions with the *publishable* key. There is no other
--     way in: the tables below have row level security on, no policies, and no grants, so the
--     public key cannot read or write them directly.
--   * join_waitlist     Step 1. Saves name + email. Returns a random, short-lived token.
--   * update_waitlist   Step 2 (optional). Needs that token, so only the browser that did Step 1
--                       can add the answers. Knowing or guessing an entry id is useless.
--   * Reading, exporting and deleting entries is done by the owner in the Supabase dashboard
--     (or with the secret key from a trusted machine), never from the website.
--
-- Deleting someone's data on request is done by the owner (see supabase/README.md): the privacy
-- policy tells people to email the privacy address.
--
-- Run this whole file once in the Supabase SQL editor.

-- ───────────── Wording that people consent to (kept for audit) ─────────────
-- Must match CONSENT_WORDING in website/src/waitlist/config.js (a test checks this).
create table if not exists public.waitlist_consent_texts (
  version    text primary key,
  wording    text not null,
  created_at timestamptz not null default now()
);

insert into public.waitlist_consent_texts (version, wording) values
  ('marketing-v1', 'I''d like to receive occasional product news, updates and offers from Lofer by email.')
on conflict (version) do nothing;

-- ───────────── The waitlist ─────────────
create table if not exists public.waitlist_entries (
  id                          uuid primary key default gen_random_uuid(),
  name                        text not null check (char_length(name) between 1 and 100),
  email                       text not null check (char_length(email) between 3 and 254),
  email_normalised            text not null check (char_length(email_normalised) between 3 and 254),

  -- Step 2 answers (all optional)
  interest_category           text check (interest_category in (
    'sports_recovery', 'everyday_tension', 'preventive_care', 'at_home_convenience',
    'ai_personalised', 'exploring_technology', 'other_curious')),
  price_range                 text check (price_range in (
    'under_100', '100_149', '150_199', '200_249', '250_299', '300_399', '400_plus', 'not_sure')),

  -- Marketing consent: separate from joining, off unless the person ticks the box
  marketing_consent           boolean not null default false,
  marketing_consent_timestamp timestamptz,
  marketing_consent_version   text references public.waitlist_consent_texts (version),
  marketing_consent_wording   text,   -- the exact words they saw, copied at the time

  -- Which privacy notice was shown at sign-up
  privacy_notice_version      text not null default 'draft-1',

  -- Only a hash of the Step 2 token is stored, and it stops working after 2 hours or one use
  update_token_hash           text,
  update_token_expires_at     timestamptz,

  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),

  constraint consent_fields_agree check (
    (marketing_consent and marketing_consent_timestamp is not null and marketing_consent_version is not null)
    or (not marketing_consent and marketing_consent_timestamp is null and marketing_consent_version is null)
  )
);

-- One entry per email address, however it is capitalised or spaced.
create unique index if not exists waitlist_entries_email_unique on public.waitlist_entries (email_normalised);

-- Counts calls, to slow down floods. Holds no personal data.
create table if not exists public.waitlist_attempts (
  at timestamptz not null default now()
);
create index if not exists waitlist_attempts_at on public.waitlist_attempts (at);

-- ───────────── Lock the tables ─────────────
alter table public.waitlist_consent_texts      enable row level security;
alter table public.waitlist_entries            enable row level security;
alter table public.waitlist_attempts           enable row level security;
-- (no policies = nobody using the public key can touch these tables)

revoke all on table
  public.waitlist_consent_texts,
  public.waitlist_entries,
  public.waitlist_attempts
from public, anon, authenticated;

-- ───────────── Shared helpers (not callable from the website) ─────────────
create or replace function public.waitlist_slow_down()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.waitlist_attempts where at < now() - interval '1 day';
  insert into public.waitlist_attempts default values;
  -- More than 40 calls in a minute, across everyone: ask the caller to wait.
  if (select count(*) from public.waitlist_attempts where at > now() - interval '1 minute') > 40 then
    raise exception 'rate_limited';
  end if;
end;
$$;

create or replace function public.waitlist_clean_email(p_email text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := lower(btrim(coalesce(p_email, '')));
begin
  if char_length(v) < 3 or char_length(v) > 254 or v !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'invalid_email';
  end if;
  return v;
end;
$$;

-- ───────────── Step 1: join ─────────────
create or replace function public.join_waitlist(p_name text, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name  text := btrim(coalesce(p_name, ''));
  v_email text;
  v_token text;
begin
  perform public.waitlist_slow_down();

  if char_length(v_name) < 1 or char_length(v_name) > 100 then
    raise exception 'invalid_name';
  end if;
  v_email := public.waitlist_clean_email(p_email);

  -- 256 random bits, handed to the browser once. Only its hash is kept.
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');

  insert into public.waitlist_entries (name, email, email_normalised, update_token_hash, update_token_expires_at)
  values (v_name, btrim(p_email), v_email,
          encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
          now() + interval '2 hours')
  on conflict (email_normalised) do nothing;

  -- Same answer whether or not the address was already there, so nobody can use this
  -- function to find out who is on the list. (For an address already on the list the token
  -- simply never matches anything, and Step 2 is declined.)
  return jsonb_build_object('ok', true, 'token', v_token);
end;
$$;

-- ───────────── Step 2: optional answers ─────────────
create or replace function public.update_waitlist(
  p_token           text,
  p_interest        text,
  p_price           text,
  p_consent         boolean,
  p_consent_version text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      uuid;
  v_wording text;
begin
  perform public.waitlist_slow_down();

  if p_token is null or char_length(p_token) <> 64 then
    raise exception 'invalid_token';
  end if;

  select id into v_id
  from public.waitlist_entries
  where update_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
    and update_token_expires_at > now();
  if v_id is null then
    raise exception 'invalid_token';
  end if;

  -- The check constraints also enforce these lists; this gives a clearer error.
  if p_interest is not null and p_interest not in (
    'sports_recovery', 'everyday_tension', 'preventive_care', 'at_home_convenience',
    'ai_personalised', 'exploring_technology', 'other_curious') then
    raise exception 'invalid_answer';
  end if;
  if p_price is not null and p_price not in (
    'under_100', '100_149', '150_199', '200_249', '250_299', '300_399', '400_plus', 'not_sure') then
    raise exception 'invalid_answer';
  end if;

  if coalesce(p_consent, false) then
    select wording into v_wording from public.waitlist_consent_texts where version = p_consent_version;
    if v_wording is null then
      raise exception 'invalid_consent_version';
    end if;
    update public.waitlist_entries set
      interest_category = p_interest,
      price_range = p_price,
      marketing_consent = true,
      marketing_consent_timestamp = now(),
      marketing_consent_version = p_consent_version,
      marketing_consent_wording = v_wording,
      update_token_hash = null,          -- the token works once
      update_token_expires_at = null,
      updated_at = now()
    where id = v_id;
  else
    update public.waitlist_entries set
      interest_category = p_interest,
      price_range = p_price,
      marketing_consent = false,
      marketing_consent_timestamp = null,
      marketing_consent_version = null,
      marketing_consent_wording = null,
      update_token_hash = null,
      update_token_expires_at = null,
      updated_at = now()
    where id = v_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ───────────── Who may call what ─────────────
revoke all on function public.waitlist_slow_down()                              from public, anon, authenticated;
revoke all on function public.waitlist_clean_email(text)                        from public, anon, authenticated;
revoke all on function public.join_waitlist(text, text)                         from public, anon, authenticated;
revoke all on function public.update_waitlist(text, text, text, boolean, text)  from public, anon, authenticated;

grant execute on function public.join_waitlist(text, text)                        to anon, authenticated;
grant execute on function public.update_waitlist(text, text, text, boolean, text) to anon, authenticated;

-- ───────────── For the owner only (run from the SQL editor) ─────────────
-- Deletes entries older than the interval you give, e.g. select public.purge_waitlist(interval '12 months');
create or replace function public.purge_waitlist(p_older_than interval)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from public.waitlist_entries where created_at < now() - p_older_than;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.purge_waitlist(interval) from public, anon, authenticated;
