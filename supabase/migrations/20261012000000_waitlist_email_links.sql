-- Lofer waitlist: personal links in emails, to unsubscribe from marketing or leave the waitlist.
--
-- Run once in the Supabase SQL Editor, AFTER 20261011000000_waitlist_withdrawals.sql.
--
-- How it works:
--   * Before a send, the owner exports the list with marketing_audience_with_links() (marketing) or
--     waitlist_contacts_with_links() (service emails to everyone). Each row has a fresh personal
--     link token: 256 random bits, given out once. Only its hash is kept, so the database can check
--     a link without being able to recreate it.
--   * The email service (Brevo) puts each person's token into their link:
--       https://<website>/unsubscribe/#t=<token>
--     ("#" keeps the token out of web-server logs.)
--   * That page calls ONE of two functions with the token, only when the person presses a button
--     (so email scanners that open links can't trigger anything):
--       unsubscribe_by_link(token)   stop marketing emails; stay on the waitlist
--       leave_waitlist_by_link(token) delete their waitlist entry
--   * A token is tied to the email address (as a hash), not to the entry, so it still works after
--     the entry is gone: a late click can never fail or be turned against them.
--   * Tokens work for 400 days.
--
-- Also: new sign-ups now record the policy they saw (privacy_notice_version), and the withdraw and
-- remove actions now share one implementation with the link versions.

-- ───────────── The link tokens ─────────────
create table if not exists public.waitlist_link_tokens (
  token_hash text primary key check (char_length(token_hash) = 64),
  email_hash text not null check (char_length(email_hash) = 64),
  created_at timestamptz not null default now()
);
create index if not exists waitlist_link_tokens_email on public.waitlist_link_tokens (email_hash);
alter table public.waitlist_link_tokens enable row level security;
revoke all on table public.waitlist_link_tokens from public, anon, authenticated;

-- New sign-ups saw the privacy policy dated 11 October 2026.
alter table public.waitlist_entries alter column privacy_notice_version set default 'policy-2026-10-11';

-- ───────────── One implementation for each action, by address hash ─────────────
create or replace function public.waitlist_withdraw_by_hash(p_email_hash text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result text;
begin
  update public.waitlist_entries
     set marketing_consent = false, marketing_consent_withdrawn_at = now(), updated_at = now()
   where encode(sha256(convert_to(email_normalised, 'UTF8')), 'hex') = p_email_hash and marketing_consent;
  if found then
    v_result := 'withdrawn';
  elsif exists (select 1 from public.waitlist_entries
                where encode(sha256(convert_to(email_normalised, 'UTF8')), 'hex') = p_email_hash) then
    v_result := 'not_consented';
  else
    v_result := 'not_on_list';
  end if;
  -- Each new request refreshes the date, so it always outranks any earlier consent. "removed" is never downgraded.
  insert into public.waitlist_suppressions (email_hash, reason) values (p_email_hash, 'unsubscribed')
  on conflict (email_hash) do update set created_at = now();
  return v_result;
end;
$$;

create or replace function public.waitlist_remove_by_hash(p_email_hash text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted boolean;
begin
  delete from public.waitlist_entries where encode(sha256(convert_to(email_normalised, 'UTF8')), 'hex') = p_email_hash;
  v_deleted := found;
  insert into public.waitlist_suppressions (email_hash, reason) values (p_email_hash, 'removed')
  on conflict (email_hash) do update set reason = 'removed', created_at = now();
  return case when v_deleted then 'removed' else 'not_on_list' end;
end;
$$;

-- The owner's by-address actions now use the same code.
create or replace function public.withdraw_marketing_consent(p_email text)
returns text language sql security definer set search_path = ''
as $$ select public.waitlist_withdraw_by_hash(public.waitlist_email_hash(p_email)); $$;

create or replace function public.remove_from_waitlist(p_email text)
returns text language sql security definer set search_path = ''
as $$ select public.waitlist_remove_by_hash(public.waitlist_email_hash(p_email)); $$;

-- ───────────── Owner: lists to load into the email service, each with a fresh link token ─────────────
create or replace function public.waitlist_new_link_token(p_email_normalised text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  insert into public.waitlist_link_tokens (token_hash, email_hash)
  values (encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), encode(sha256(convert_to(p_email_normalised, 'UTF8')), 'hex'));
  return v_token;
end;
$$;

-- For MARKETING emails: only people in marketing_audience().
create or replace function public.marketing_audience_with_links()
returns table (name text, email text, consented_at timestamptz, link_token text)
language sql
volatile
security definer
set search_path = ''
as $$
  select a.name, a.email, a.consented_at, public.waitlist_new_link_token(lower(btrim(a.email)))
  from public.marketing_audience() a;
$$;

-- For SERVICE emails (about your registration / early access, no promotion): everyone on the waitlist.
create or replace function public.waitlist_contacts_with_links()
returns table (name text, email text, link_token text)
language sql
volatile
security definer
set search_path = ''
as $$
  select e.name, e.email, public.waitlist_new_link_token(e.email_normalised)
  from public.waitlist_entries e
  order by e.created_at;
$$;

-- ───────────── Website: the two link actions ─────────────
create or replace function public.waitlist_link_email_hash(p_token text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_link';
  end if;
  select email_hash into v_hash from public.waitlist_link_tokens
   where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
     and created_at > now() - interval '400 days';
  if v_hash is null then
    raise exception 'invalid_link';
  end if;
  return v_hash;
end;
$$;

-- The answer never says whether the address is (still) on the list: "done" either way.
create or replace function public.unsubscribe_by_link(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.waitlist_slow_down();
  perform public.waitlist_withdraw_by_hash(public.waitlist_link_email_hash(p_token));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.leave_waitlist_by_link(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.waitlist_slow_down();
  perform public.waitlist_remove_by_hash(public.waitlist_link_email_hash(p_token));
  return jsonb_build_object('ok', true);
end;
$$;

-- Retention: entries are deleted 12 months after sign-up; link tokens after 400 days.
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
  delete from public.waitlist_link_tokens where created_at < now() - interval '400 days';
  return v_count;
end;
$$;

-- ───────────── Who may call what ─────────────
revoke all on function public.waitlist_withdraw_by_hash(text)     from public, anon, authenticated;
revoke all on function public.waitlist_remove_by_hash(text)       from public, anon, authenticated;
revoke all on function public.withdraw_marketing_consent(text)    from public, anon, authenticated;
revoke all on function public.remove_from_waitlist(text)          from public, anon, authenticated;
revoke all on function public.waitlist_new_link_token(text)       from public, anon, authenticated;
revoke all on function public.marketing_audience_with_links()     from public, anon, authenticated;
revoke all on function public.waitlist_contacts_with_links()      from public, anon, authenticated;
revoke all on function public.waitlist_link_email_hash(text)      from public, anon, authenticated;
revoke all on function public.purge_waitlist(interval)            from public, anon, authenticated;
revoke all on function public.unsubscribe_by_link(text)           from public, anon, authenticated;
revoke all on function public.leave_waitlist_by_link(text)        from public, anon, authenticated;

grant execute on function public.unsubscribe_by_link(text)    to anon, authenticated;
grant execute on function public.leave_waitlist_by_link(text) to anon, authenticated;
