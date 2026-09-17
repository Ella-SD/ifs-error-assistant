-- ============================================================================
-- Drop stale overloads of apply_as_consultant.
--
-- Migrations 0048/0049/0050 each used CREATE OR REPLACE with a different
-- parameter list, which in PostgreSQL creates a NEW overloaded function rather
-- than replacing the old one.  This left 4 overloads with the same name;
-- when the edit-modules flow calls apply_as_consultant(p_modules => text[])
-- Postgres throws "could not choose the best candidate function".
--
-- Fix: drop the three old overloads by their exact signatures.
-- The current (0050) version — 12 params, all but p_modules have defaults —
-- handles every call site including the p_modules-only edit-modules path.
-- ============================================================================

-- Original (0018)
drop function if exists public.apply_as_consultant(text[]);

-- 0048 version (7 params)
drop function if exists public.apply_as_consultant(text[], text, text, text, text, text, text);

-- 0049 version (9 params)
drop function if exists public.apply_as_consultant(text[], text, text, text, text, text, text, boolean, text);

notify pgrst, 'reload schema';
