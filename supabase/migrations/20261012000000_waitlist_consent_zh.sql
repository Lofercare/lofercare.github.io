-- Adds the Chinese marketing-consent wording, so the website's Chinese version can record exactly
-- what the person agreed to. Run once in the Supabase SQL editor (after the first waitlist migration).
--
-- The text must match CONSENT_WORDING_ZH in website/src/waitlist/config.js and row 183 of
-- docs/website-text-for-translation.csv (a test checks this). If you change the Chinese wording,
-- add a NEW version (for example 'marketing-v2-zh'), never edit this row: old sign-ups point to it.
insert into public.waitlist_consent_texts (version, wording) values
  ('marketing-v1-zh', '我希望通过邮件偶尔收到 Lofer 的产品消息、更新与优惠。')
on conflict (version) do nothing;
