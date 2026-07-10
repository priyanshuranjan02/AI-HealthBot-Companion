
-- Restrict SECURITY DEFINER function so it can only be executed by triggers/backend, not exposed to API roles
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;

-- Hide tables from the pg_graphql API surface (REST/PostgREST access is unaffected)
REVOKE USAGE ON SCHEMA graphql FROM anon, authenticated;
