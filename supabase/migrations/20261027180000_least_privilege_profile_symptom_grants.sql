-- Narrow table ACLs to the operations used by the application. RLS remains
-- responsible for row ownership; this migration does not change any policy.
-- Apply after 20261019120000_harden_profile_insert_privileges.sql.
BEGIN;

DO $$
DECLARE
  signup_function oid;
  signup_owner oid;
  profiles_owner oid;
  signup_owner_bypasses_rls boolean;
  profiles_rls_enabled boolean;
  profiles_force_rls boolean;
  signup_config text[];
  signup_definition text;
  signup_role_default text;
BEGIN
  IF to_regclass('public.profiles') IS NULL
     OR to_regclass('public.symptom_checks') IS NULL
     OR to_regclass('auth.users') IS NULL
  THEN
    RAISE EXCEPTION 'profiles, symptom_checks, and auth.users must exist before least-privilege grants';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated')
     OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role')
  THEN
    RAISE EXCEPTION 'Supabase API roles anon, authenticated, and service_role are required';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.profiles'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.symptom_checks'::regclass)
  THEN
    RAISE EXCEPTION 'RLS must remain enabled on profiles and symptom_checks';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid = 'public.profiles'::regclass
      AND polname NOT IN ('Users can view own profile', 'Users can update own profile')
  ) THEN
    RAISE EXCEPTION 'unexpected profiles policy found; review it before applying table grants';
  END IF;

  IF NOT EXISTS (
       SELECT 1 FROM pg_policy
       WHERE polrelid = 'public.profiles'::regclass
         AND polname = 'Users can view own profile'
         AND polcmd = 'r'
         AND (SELECT oid FROM pg_roles WHERE rolname = 'authenticated') = ANY(polroles)
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_policy
       WHERE polrelid = 'public.profiles'::regclass
         AND polname = 'Users can update own profile'
         AND polcmd = 'w'
         AND (SELECT oid FROM pg_roles WHERE rolname = 'authenticated') = ANY(polroles)
     )
  THEN
    RAISE EXCEPTION 'expected authenticated own-profile SELECT and UPDATE policies are required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid = 'public.symptom_checks'::regclass
      AND polname NOT IN (
        'Users can view their own symptom checks',
        'Users can insert their own symptom checks',
        'Users can delete their own symptom checks',
        'Anonymous users can insert symptom checks',
        'Service role can read all symptom checks'
      )
  )
     OR NOT EXISTS (
       SELECT 1 FROM pg_policy
       WHERE polrelid = 'public.symptom_checks'::regclass
         AND polname = 'Users can view their own symptom checks'
         AND polcmd = 'r'
         AND (SELECT oid FROM pg_roles WHERE rolname = 'authenticated') = ANY(polroles)
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_policy
       WHERE polrelid = 'public.symptom_checks'::regclass
         AND polname = 'Users can insert their own symptom checks'
         AND polcmd = 'a'
         AND (SELECT oid FROM pg_roles WHERE rolname = 'authenticated') = ANY(polroles)
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_policy
       WHERE polrelid = 'public.symptom_checks'::regclass
         AND polname = 'Users can delete their own symptom checks'
         AND polcmd = 'd'
         AND (SELECT oid FROM pg_roles WHERE rolname = 'authenticated') = ANY(polroles)
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_policy
       WHERE polrelid = 'public.symptom_checks'::regclass
         AND polname = 'Anonymous users can insert symptom checks'
         AND polcmd = 'a'
         AND (SELECT oid FROM pg_roles WHERE rolname = 'anon') = ANY(polroles)
     )
  THEN
    RAISE EXCEPTION 'expected ownership-scoped symptom-check policies are required';
  END IF;

  SELECT p.oid, p.proowner, c.relowner,
         (r.rolsuper OR r.rolbypassrls), c.relrowsecurity,
         c.relforcerowsecurity, p.proconfig, pg_get_functiondef(p.oid),
         pg_get_expr(d.adbin, d.adrelid)
    INTO signup_function, signup_owner, profiles_owner,
         signup_owner_bypasses_rls, profiles_rls_enabled,
         profiles_force_rls, signup_config, signup_definition,
         signup_role_default
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  JOIN pg_class AS c ON c.oid = 'public.profiles'::regclass
  JOIN pg_roles AS r ON r.oid = p.proowner
  JOIN pg_attribute AS a ON a.attrelid = c.oid AND a.attname = 'role'
  JOIN pg_attrdef AS d ON d.adrelid = c.oid AND d.adnum = a.attnum
  WHERE n.nspname = 'public'
    AND p.proname = 'handle_new_user'
    AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype;

  IF signup_function IS NULL
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = signup_function)
     OR NOT COALESCE(signup_config @> ARRAY['search_path=""']::text[], false)
     OR signup_owner IN (
       SELECT oid FROM pg_roles WHERE rolname IN ('anon', 'authenticated')
     )
     OR position('user' IN lower(COALESCE(signup_role_default, ''))) = 0
     OR position('INSERT INTO public.profiles (id, full_name)' IN signup_definition) = 0
     OR signup_definition ~* 'raw_user_meta_data[^;]*role|INSERT INTO public\.profiles\s*\([^)]*role'
     OR NOT has_column_privilege(signup_owner, 'public.profiles', 'id', 'INSERT')
     OR NOT has_column_privilege(signup_owner, 'public.profiles', 'full_name', 'INSERT')
     OR (profiles_rls_enabled AND profiles_force_rls AND NOT signup_owner_bypasses_rls)
     OR (profiles_rls_enabled AND NOT profiles_force_rls
         AND signup_owner <> profiles_owner AND NOT signup_owner_bypasses_rls)
  THEN
    RAISE EXCEPTION 'trusted handle_new_user() must retain safe signup behavior and required profile INSERT privileges';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger AS t
    WHERE t.tgrelid = 'auth.users'::regclass
      AND t.tgname = 'on_auth_user_created'
      AND t.tgfoid = signup_function
      AND t.tgtype = 5
      AND t.tgenabled IN ('O', 'A')
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'enabled Auth signup trigger must continue to call handle_new_user()';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger AS t
    WHERE t.tgrelid = 'public.profiles'::regclass
      AND t.tgname = 'prevent_profile_role_escalation'
      AND t.tgfoid = to_regprocedure('public.prevent_profile_role_escalation()')
      AND (t.tgtype & 16) = 16
      AND t.tgenabled IN ('O', 'A')
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'enabled profile role-escalation trigger is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger AS t
    WHERE t.tgrelid = 'public.profiles'::regclass
      AND t.tgname = 'prevent_untrusted_profile_insert'
      AND t.tgfoid = to_regprocedure('public.prevent_untrusted_profile_insert()')
      AND t.tgtype = 7
      AND t.tgenabled IN ('O', 'A')
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'enabled profile insert-guard trigger is required';
  END IF;
END;
$$;

-- Clear table-level rights for API roles, including grants inherited from
-- PUBLIC. The trusted Auth function's owner and service_role are not revoked.
REVOKE ALL PRIVILEGES ON TABLE public.profiles, public.symptom_checks
  FROM PUBLIC, anon, authenticated;

-- Table-level REVOKE does not remove column ACL entries. Remove every existing
-- column grant to PUBLIC/anon/authenticated, regardless of privilege type.
DO $$
DECLARE
  column_grant record;
  grantee_sql text;
BEGIN
  FOR column_grant IN
    SELECT DISTINCT c.relname AS table_name,
           a.attname AS column_name,
           acl.grantee,
           acl.privilege_type,
           r.rolname
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_attribute AS a ON a.attrelid = c.oid
    CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
    LEFT JOIN pg_roles AS r ON r.oid = acl.grantee
    WHERE n.nspname = 'public'
      AND c.relname IN ('profiles', 'symptom_checks')
      AND c.relkind IN ('r', 'p')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND acl.grantee IN (
        0,
        (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
        (SELECT oid FROM pg_roles WHERE rolname = 'authenticated')
      )
  LOOP
    grantee_sql := CASE
      WHEN column_grant.grantee = 0 THEN 'PUBLIC'
      ELSE quote_ident(column_grant.rolname)
    END;
    EXECUTE format(
      'REVOKE %s (%I) ON TABLE public.%I FROM %s',
      column_grant.privilege_type,
      column_grant.column_name,
      column_grant.table_name,
      grantee_sql
    );
  END LOOP;
END;
$$;

-- Restore only the operations used by the application. RLS continues to limit
-- authenticated reads/writes to the caller's own profile/assessment rows, and
-- anonymous assessment inserts remain limited to user_id IS NULL.
GRANT SELECT, UPDATE ON TABLE public.profiles TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.symptom_checks TO authenticated;
GRANT INSERT ON TABLE public.symptom_checks TO anon;

-- Preserve trusted backend behavior without granting API roles extra rights.
GRANT ALL PRIVILEGES ON TABLE public.profiles, public.symptom_checks TO service_role;

DO $$
BEGIN
  IF has_table_privilege('anon', 'public.profiles', 'SELECT')
     OR has_table_privilege('anon', 'public.profiles', 'INSERT')
     OR has_table_privilege('anon', 'public.profiles', 'UPDATE')
     OR has_table_privilege('anon', 'public.profiles', 'DELETE')
     OR has_table_privilege('anon', 'public.profiles', 'TRUNCATE')
     OR has_table_privilege('anon', 'public.profiles', 'REFERENCES')
     OR has_table_privilege('anon', 'public.profiles', 'TRIGGER')
     OR has_any_column_privilege('anon', 'public.profiles', 'SELECT')
     OR has_any_column_privilege('anon', 'public.profiles', 'INSERT')
     OR has_any_column_privilege('anon', 'public.profiles', 'UPDATE')
     OR has_any_column_privilege('anon', 'public.profiles', 'REFERENCES')
     OR NOT has_table_privilege('authenticated', 'public.profiles', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.profiles', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     OR has_table_privilege('authenticated', 'public.profiles', 'DELETE')
     OR has_table_privilege('authenticated', 'public.profiles', 'TRUNCATE')
     OR has_table_privilege('authenticated', 'public.profiles', 'REFERENCES')
     OR has_table_privilege('authenticated', 'public.profiles', 'TRIGGER')
     OR has_any_column_privilege('authenticated', 'public.profiles', 'INSERT')
     OR has_any_column_privilege('authenticated', 'public.profiles', 'REFERENCES')
  THEN
    RAISE EXCEPTION 'profiles table privileges do not match the least-privilege matrix';
  END IF;

  IF NOT has_table_privilege('anon', 'public.symptom_checks', 'INSERT')
     OR has_table_privilege('anon', 'public.symptom_checks', 'SELECT')
     OR has_table_privilege('anon', 'public.symptom_checks', 'UPDATE')
     OR has_table_privilege('anon', 'public.symptom_checks', 'DELETE')
     OR has_table_privilege('anon', 'public.symptom_checks', 'TRUNCATE')
     OR has_table_privilege('anon', 'public.symptom_checks', 'REFERENCES')
     OR has_table_privilege('anon', 'public.symptom_checks', 'TRIGGER')
     OR has_any_column_privilege('anon', 'public.symptom_checks', 'SELECT')
     OR has_any_column_privilege('anon', 'public.symptom_checks', 'UPDATE')
     OR has_any_column_privilege('anon', 'public.symptom_checks', 'REFERENCES')
     OR NOT has_table_privilege('authenticated', 'public.symptom_checks', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.symptom_checks', 'INSERT')
     OR NOT has_table_privilege('authenticated', 'public.symptom_checks', 'DELETE')
     OR has_table_privilege('authenticated', 'public.symptom_checks', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.symptom_checks', 'TRUNCATE')
     OR has_table_privilege('authenticated', 'public.symptom_checks', 'REFERENCES')
     OR has_table_privilege('authenticated', 'public.symptom_checks', 'TRIGGER')
     OR has_any_column_privilege('authenticated', 'public.symptom_checks', 'UPDATE')
  THEN
    RAISE EXCEPTION 'symptom_checks table privileges do not match the least-privilege matrix';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(
      COALESCE(c.relacl, acldefault('r', c.relowner))
    ) AS acl
    WHERE n.nspname = 'public'
      AND c.relname IN ('profiles', 'symptom_checks')
      AND acl.grantee = 0
  ) OR EXISTS (
    SELECT 1
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_attribute AS a ON a.attrelid = c.oid
    CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
    WHERE n.nspname = 'public'
      AND c.relname IN ('profiles', 'symptom_checks')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND acl.grantee = 0
  ) THEN
    RAISE EXCEPTION 'PUBLIC privileges remain on profiles or symptom_checks';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_attribute AS a ON a.attrelid = c.oid
    CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
    WHERE n.nspname = 'public'
      AND c.relname IN ('profiles', 'symptom_checks')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND acl.grantee IN (
        (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
        (SELECT oid FROM pg_roles WHERE rolname = 'authenticated')
      )
  ) THEN
    RAISE EXCEPTION 'client column-level privileges remain on profiles or symptom_checks';
  END IF;

  IF NOT has_table_privilege('service_role', 'public.profiles', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'INSERT')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'UPDATE')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'DELETE')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'TRUNCATE')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'REFERENCES')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'TRIGGER')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'INSERT')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'UPDATE')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'DELETE')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'TRUNCATE')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'REFERENCES')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'TRIGGER')
  THEN
    RAISE EXCEPTION 'service_role lost required table privileges';
  END IF;
END;
$$;

COMMIT;
