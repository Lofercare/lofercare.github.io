# Sending waitlist emails with Brevo: setup and every send

How Lofer emails the waitlist so that unsubscribing and leaving always work. Read
`WAITLIST-PRIVACY-OPERATIONS.md` first: **no marketing email until every step below works.**

## How it fits together

```
Supabase (the one source of truth)                         Brevo (sends the emails)
  marketing_audience_with_links()  ── CSV export ──►  a contact list, each with LOFER_LINK
                                                          │
           ┌──────────────────────────────────────────────┘
           ▼  every email has two links in its footer
  1. Brevo's own unsubscribe link   → Brevo blocklists them  ──► you copy these back to Supabase (step C1)
  2. Our personal link               → https://lofercare.github.io/unsubscribe/#t=<code>
                                        "Unsubscribe from marketing" or "Leave the waitlist"
                                        → updates Supabase directly
```

Why both links: Brevo requires its own unsubscribe link in marketing emails (it also adds the
one-click "unsubscribe" button some inboxes show). Ours lets people **leave the waitlist** too, and
records everything in Supabase. Step C1 keeps the two in step.

## A. One-time setup

You'll need: **a domain you own for sending** (for example `lofer.co.uk`). Inbox providers and
Brevo won't reliably deliver bulk email "from" a `@gmail.com` address. The website is at
`https://lofercare.github.io` (if it moves to your own domain later, update the link in step A8).

1. **Apply the two database upgrades**, in order. Supabase → SQL Editor → New query → paste the
   whole file → Run:
   1. `supabase/migrations/20261011000000_waitlist_withdrawals.sql`
   2. `supabase/migrations/20261012000000_waitlist_email_links.sql`
2. **Publish the website changes** (the `/unsubscribe/` page and the updated privacy policy): merge
   the `feature/waitlist-privacy` branch into `main`. GitHub deploys it.
3. **Check the page works:** open `https://lofercare.github.io/unsubscribe/`. It should say "This link isn't complete"
   (that's correct: there's no personal code in the address).
4. **Create the Brevo account** (the free plan is fine to start). Brevo's data processing agreement
   is part of its terms; download a copy for your records.
5. **Authenticate your domain:** Brevo → *Senders, Domains & Dedicated IPs* → *Domains* → *Add a
   domain*, then add the DNS records it shows at your domain registrar (DKIM, Brevo code, DMARC).
   Wait until Brevo shows it as authenticated.
6. **Add a sender**, for example `hello@yourdomain`.
7. **Add a contact attribute:** Brevo → *Contacts* → *Settings* → *Contact attributes* → add
   **`LOFER_LINK`**, type *Text*.
8. **Make an email template** with this in the footer, next to Brevo's unsubscribe link:
   ```html
   <a href="https://lofercare.github.io/unsubscribe/#t={{ contact.LOFER_LINK }}">Email preferences or leave the waitlist</a>
   ```
9. **Retention (12 months after sign-up):** either run this on the 1st of every month,
   ```sql
   select public.purge_waitlist(interval '12 months');
   ```
   or schedule it once. Supabase → *Database* → *Extensions* → enable **pg_cron**, then in the SQL Editor:
   ```sql
   select cron.schedule('waitlist-retention', '0 3 1 * *', $$select public.purge_waitlist(interval '12 months')$$);
   ```

## B. Test it end to end (before any real send)

1. Sign up on the website with **your own** address and tick the marketing box.
2. Do a send (section C) to a list containing only you.
3. In the email, click our link → **Unsubscribe from marketing**. Check in Supabase:
   ```sql
   select marketing_consent, marketing_consent_withdrawn_at from public.waitlist_entries
   where email_normalised = 'you@example.com';   -- false, with a date
   select * from public.marketing_audience();      -- you're not in it
   ```
4. Click the same link again → **Leave the waitlist** → confirm. Your entry should be gone.
5. Repeat with a second test address, using **Brevo's** unsubscribe link, then do step C1 and check
   it's withdrawn in Supabase.

Only when all of that works may you send to real people.

## C. Every send

1. **Copy Brevo's unsubscribes back first.** Brevo → *Contacts* → filter *Blocklisted* (or
   *Unsubscribed*) → export. Then in the SQL Editor, with their addresses:
   ```sql
   select e, public.withdraw_marketing_consent(e)
   from unnest(array['first@example.com', 'second@example.com']) as e;
   ```
2. **Export a fresh list** from Supabase (SQL Editor → run → *Download CSV*):
   ```sql
   -- MARKETING (product news, offers): only people who opted in and haven't withdrawn
   select name, email, link_token from public.marketing_audience_with_links();

   -- SERVICE emails to everyone (e.g. "early access is open"), with NO promotional content
   select name, email, link_token from public.waitlist_contacts_with_links();
   ```
   Every export makes fresh personal links; links in earlier emails keep working for about 13 months.
3. **Import it into Brevo** as a new list (*Contacts* → *Import contacts*), mapping `email` → EMAIL,
   `name` → FIRSTNAME and `link_token` → **LOFER_LINK**, with "update existing contacts" on.
4. **Send** the campaign to that list only.
5. **Afterwards, delete the list's contacts from Brevo** (keep Brevo's blocklist). Supabase stays the
   only place the waitlist lives, and the next send starts again from step 1.

Never send from an old export, a spreadsheet or a personal inbox.
