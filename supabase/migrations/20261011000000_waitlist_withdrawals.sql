-- Lofer waitlist: record marketing withdrawals and keep a "do not email" list.
--
-- Run once in the Supabase SQL Editor, AFTER 20261010000000_waitlist.sql.
--
-- Why:
--   * Before this, switching someone's marketing consent off had to wipe the consent time and
--     version (a table rule required it), so the evidence that they had consented was lost and
--     there was no record of when they withdrew.
--   * There was no "do not email" list: someone removed from the waitlist could be emailed again
--     if their address came back (signing up again, an import).
--
-- What changes:
--   * waitlist_entries.marketing_consent_withdrawn_at: when consent was withdrawn. The original
--     consent time, version and wording are KEPT as evidence.
--   * waitlist_suppressions: the "do not email" list. It holds a SHA-256 hash of the normalised
--     address, never the address itself, plus why and when.
--   * Three owner-only functions (the website cannot call them):
--       withdraw_marketing_consent(email)  someone unsubscribes from marketing (stays on the waitlist)
--       remove_from_waitlist(email)        someone asks to leave the waitlist / be deleted
--       marketing_audience()               THE list to use for any marketing email
--   * The two functions the website calls (join_waitlist, update_waitlist) are NOT changed.
--
-- A fresh tick of the marketing box AFTER someone was suppressed counts as new consent: they
-- appear in marketing_audience() again. A suppression after their consent always wins.

-- ───────────── 1. Withdrawal time, keeping the consent evidence ─────────────
alter table public.waitlist_entries
  add column if not exists marketing_consent_withdrawn_at timestamptz;

alter table public.waitlist_entries drop constraint if exists consent_fields_agree;
alter table public.waitlist_entries add constraint consent_fields_agree check (
  -- consented now: time and version recorded, not withdrawn
  (marketing_consent and marketing_consent_timestamp is not null and marketing_consent_version is not null
     and marketing_consent_withdrawn_at is null)
  -- never consented: nothing recorded
  or (not marketing_consent and marketing_consent_timestamp is null and marketing_consent_version is null
     and marketing_consent_withdrawn_at is null)
  -- consented, then withdrew: the original evidence is kept, with the withdrawal time
  or (not marketing_consent and marketing_consent_timestamp is not null and marketing_consent_version is not null
     and marketing_consent_withdrawn_at is not null)
);

-- ───────────── 2. The "do not email" list ─────────────
create table if not exists public.waitlist_suppressions (
  email_hash text primary key check (char_length(email_hash) = 64),   -- sha256 of the normalised address
  reason     text not null check (reason in ('unsubscribed', 'removed')),
  created_at timestamptz not null default now()
);
alter table public.waitlist_suppressions enable row level security;
-- (no policies = nobody using the public key can touch it)
revoke all on table public.waitlist_suppressions from public, anon, authenticated;

-- The hash of an address, after the same clean-up as sign-up (trimmed, lower case, checked).
create or replace function public.waitlist_email_hash(p_email text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  return encode(sha256(convert_to(public.waitlist_clean_email(p_email), 'UTF8')), 'hex');
end;
$$;

-- Adds (or keeps) a suppression. The first reason and time are kept; "removed" outranks "unsubscribed".
create or replace function public.waitlist_suppress(p_email text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.waitlist_suppressions (email_hash, reason)
  values (public.waitlist_email_hash(p_email), p_reason)
  on conflict (email_hash) do update
    set reason = case when excluded.reason = 'removed' then 'removed' else public.waitlist_suppressions.reason end,
        created_at = case when excluded.reason = 'removed' and public.waitlist_suppressions.reason <> 'removed'
                          then now() else public.waitlist_suppressions.created_at end;
end;
$$;

-- ───────────── 3. Owner actions ─────────────
-- Unsubscribe from marketing. They stay on the waitlist. Returns what happened:
--   'withdrawn'      they had consented; consent is now off, with the time recorded
--   'not_consented'  they're on the waitlist but never ticked the box (suppressed anyway)
--   'not_on_list'    no such address (suppressed anyway, in case it's added later)
create or replace function public.withdraw_marketing_consent(p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email  text := public.waitlist_clean_email(p_email);
  v_result text;
begin
  update public.waitlist_entries
     set marketing_consent = false, marketing_consent_withdrawn_at = now(), updated_at = now()
   where email_normalised = v_email and marketing_consent;
  if found then
    v_result := 'withdrawn';
  elsif exists (select 1 from public.waitlist_entries where email_normalised = v_email) then
    v_result := 'not_consented';
  else
    v_result := 'not_on_list';
  end if;
  perform public.waitlist_suppress(v_email, 'unsubscribed');
  return v_result;
end;
$$;

-- Leave the waitlist: deletes their entry (name, email, answers, consent record) and keeps only
-- the hashed address on the "do not email" list. Returns 'removed' or 'not_on_list'.
create or replace function public.remove_from_waitlist(p_email text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email   text := public.waitlist_clean_email(p_email);
  v_deleted boolean;
begin
  delete from public.waitlist_entries where email_normalised = v_email;
  v_deleted := found;                       -- read now: the next statement resets it
  perform public.waitlist_suppress(v_email, 'removed');
  return case when v_deleted then 'removed' else 'not_on_list' end;
end;
$$;

-- THE list for any marketing email: people who ticked the box, haven't withdrawn, and have no
-- suppression recorded after their consent.
create or replace function public.marketing_audience()
returns table (name text, email text, consented_at timestamptz, consent_version text)
language sql
stable
security definer
set search_path = ''
as $$
  select e.name, e.email, e.marketing_consent_timestamp, e.marketing_consent_version
  from public.waitlist_entries e
  where e.marketing_consent
    and not exists (
      select 1 from public.waitlist_suppressions s
      where s.email_hash = encode(sha256(convert_to(e.email_normalised, 'UTF8')), 'hex')
        and s.created_at >= e.marketing_consent_timestamp
    )
  order by e.marketing_consent_timestamp;
$$;

-- ───────────── Who may call what ─────────────
revoke all on function public.waitlist_email_hash(text)              from public, anon, authenticated;
revoke all on function public.waitlist_suppress(text, text)          from public, anon, authenticated;
revoke all on function public.withdraw_marketing_consent(text)       from public, anon, authenticated;
revoke all on function public.remove_from_waitlist(text)             from public, anon, authenticated;
revoke all on function public.marketing_audience()                   from public, anon, authenticated;
