# Lofer waitlist: database

The waitlist is stored in Supabase. The website is static (GitHub Pages), so it cannot hold a secret.
Instead the **database** guards itself:

```
Browser (publishable key)  ──►  join_waitlist(name, email)          Step 1: saves the signup, returns a token
                           ──►  update_waitlist(token, answers…)    Step 2: needs that token
Everything else (reading, exporting, deleting)  ──►  you, in the Supabase dashboard
```

* The tables have row level security on, no policies and no grants. The publishable key **cannot read
  or write them directly**. `supabase/tests` proves it.
* The **secret key is not used by the website at all** and must never be in this repository, in
  `website/.env*`, or in GitHub. You only need it for admin scripts you run yourself.
* The Step 2 token is 256 random bits, stored only as a hash, expires after 2 hours and works once, so
  knowing or guessing an entry id (or an email address) lets nobody change an entry. Signing up with an
  address that is already on the list gets a normal-looking answer but a token that matches nothing, so the
  form cannot be used to find out who is on the list.
* Flood protection: more than 40 calls a minute across everyone is refused (`rate_limited`), and the form has
  a hidden trap field for bots. For stronger protection later, add Cloudflare Turnstile via a Supabase Edge Function.

## One-time setup

1. In Supabase: **SQL Editor → New query**, paste `migrations/20261010000000_waitlist.sql`, **Run**.
   (Already done for the live project. On 11 October 2026 its five functions, nine constraints and
   row-level security were checked against this file and match exactly.)
2. Find your **Project URL** (Project Settings → API), like `https://abcdxyz.supabase.co`.
3. Locally: put it in `website/.env.local` as `VITE_SUPABASE_URL=…` (the publishable key is already there). Run `npm run dev` in `website/`.
4. On GitHub: **Settings → Secrets and variables → Actions → Variables**, add `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`.
5. Check your project's region (Project Settings → General) and make sure section 8 of the privacy policy is true for it.

## Upgrades (run each once, in order, in the SQL Editor)

| File | What it does | Live project |
|---|---|---|
| `migrations/20261010000000_waitlist.sql` | The waitlist itself | Applied (checked 11 Oct 2026) |
| `migrations/20261011000000_waitlist_withdrawals.sql` | Records marketing withdrawals (keeping the consent evidence) and adds the "do not email" list | **Not yet applied** |

To apply one: **SQL Editor → New query**, paste the whole file, **Run**. It only adds things and
changes one table rule; existing entries are kept (a test checks this).

## Day-to-day (run in the SQL Editor, as the owner)

The rules and the step-by-step procedure for privacy requests are in
`docs/WAITLIST-PRIVACY-OPERATIONS.md`. **No marketing email may be sent until unsubscribing works.**

```sql
-- See the list
select name, email, interest_category, price_range, marketing_consent, marketing_consent_timestamp, created_at
from public.waitlist_entries order by created_at desc;

-- THE list for any marketing email (opted in, not withdrawn, not on the "do not email" list)
select * from public.marketing_audience();

-- Someone unsubscribes from marketing (stays on the waitlist)
select public.withdraw_marketing_consent('person@example.com');

-- Someone leaves the waitlist / asks for deletion (email to loferprivacy@gmail.com; check it really is them first)
select public.remove_from_waitlist('person@example.com');

-- Retention: delete entries older than 12 months
select public.purge_waitlist(interval '12 months');
```

## Tests

```
cd supabase && npm install && npm test
```

Runs the real migration in an embedded Postgres (PGlite) and calls the functions as the public `anon` role.
