# Waitlist privacy: how we operate

For Lofer's two joint data controllers. It covers the rules we follow for the waitlist and the
steps for privacy requests. The database side is described in `supabase/README.md`.

This is an operating procedure, not legal advice. Review it against the ICO's guidance on direct
marketing (PECR) and on the right to erasure before relying on it.

## Rule 1: no marketing emails until unsubscribing works

**Do not send any marketing email** (product news, updates, offers, anything promotional) until
**all** of these are true:

1. Every marketing email is sent through an email service that adds a **working one-click
   unsubscribe link**, and clicking it actually runs `withdraw_marketing_consent` (or does the same).
2. The recipient list comes **only** from `select * from public.marketing_audience();`, pulled
   fresh right before sending. Never from an old export, a spreadsheet or a personal address book.
3. The privacy policy describes the email service and the unsubscribe process accurately.

**Never** send marketing from a personal inbox (Gmail, etc.): there's no unsubscribe link, and
it would break both our privacy policy and the PECR rules.

Service emails to everyone on the waitlist (for example "early access is open, here's how to
order") are allowed without marketing consent, **but must not contain promotional content**.
If in doubt, treat it as marketing.

## Rule 2: privacy requests by email

Requests arrive at **loferprivacy@gmail.com**. Both founders have access.

| What | Our target | Legal limit (UK GDPR) |
|---|---|---|
| Check the inbox | At least twice a week | — |
| Reply and act on a request | Within 7 days | One month from receipt |

### Steps for every request

1. **Log it** in our private request log (kept outside this repository): date received, type of
   request, date completed, who did it. Do not copy the person's details into the log beyond
   what's needed to find the request again.
2. **Check it's really them.** Act only if the request comes from the email address that's on
   the waitlist. If it comes from a different address, reply asking them to write from the
   address they signed up with. Never ask for more personal data than that.
3. **Do it** in the Supabase SQL Editor (see below).
4. **Remove them everywhere else too:** any export or spreadsheet, and the email service's
   contact list once we have one.
5. **Confirm** by replying to their email: what was done, and when.
6. **Complete the log entry.**

### The commands (Supabase → SQL Editor)

```sql
-- Unsubscribe from marketing (they stay on the waitlist; the consent evidence is kept)
select public.withdraw_marketing_consent('person@example.com');
--   → 'withdrawn' | 'not_consented' | 'not_on_list'  (all three add them to the "do not email" list)

-- Leave the waitlist / delete their data (keeps only a hashed address on the "do not email" list)
select public.remove_from_waitlist('person@example.com');
--   → 'removed' | 'not_on_list'

-- A copy of what we hold about them (access request)
select * from public.waitlist_entries where email_normalised = lower(btrim('person@example.com'));

-- Correct their name (correction request)
update public.waitlist_entries set name = 'New Name', updated_at = now()
where email_normalised = lower(btrim('person@example.com'));
```

### Backups

Supabase keeps automatic backups for a limited period (it depends on the plan). A deleted entry
can remain in a backup until that backup expires. We never restore a backup without first
re-running every deletion and unsubscribe made since that backup was taken.
