
REVOKE USAGE ON SCHEMA graphql_public FROM anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA graphql_public FROM anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA graphql_public FROM anon, authenticated;
