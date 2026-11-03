-- Close direct client profile creation while preserving the trusted Auth
-- signup trigger. Apply only after the preceding profile/signup migrations.
BEGIN;

DO $$
DECLARE
  signup_function oid;
  signup_owner oid;
  profiles_owner oid;
  profiles_force_rls boolean;
  profiles_rls_enabled boolean;
  owner_can_insert_id boolean;
  owner_can_insert_name boolean;
  owner_bypasses_rls boolean;
  signup_settings text[];
  signup_definition text;
  profile_role_default text;
  enabled_trigger_count integer;
BEGIN
  SELECT p.oid, p.proowner, c.relowner, c.relrowsecurity,
         c.relforcerowsecurity,
         has_column_privilege(p.proowner, c.oid, 'id', 'INSERT'),
         has_column_privilege(p.proowner, c.oid, 'full_name', 'INSERT'),
         r.rolsuper OR r.rolbypassrls,
         p.proconfig,
         pg_get_functiondef(p.oid),
         pg_get_expr(d.adbin, d.adrelid)
    INTO signup_function, signup_owner, profiles_owner,
         profiles_rls_enabled, profiles_force_rls,
         owner_can_insert_id, owner_can_insert_name, owner_bypasses_rls,
         signup_settings, signup_definition, profile_role_default
  FROM pg_proc AS p
  JOIN pg_namespace AS pn ON pn.oid = p.pronamespace
  JOIN pg_class AS c ON c.oid = 'public.profiles'::regclass
  JOIN pg_attribute AS a ON a.attrelid = c.oid AND a.attname = 'role'
  JOIN pg_attrdef AS d ON d.adrelid = c.oid AND d.adnum = a.attnum
  JOIN pg_roles AS r ON r.oid = p.proowner
  WHERE pn.nspname = 'public'
    AND p.proname = 'handle_new_user'
    AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype;

  IF signup_function IS NULL THEN
    RAISE EXCEPTION 'public.handle_new_user() is required before profile INSERT lockdown';
  END IF;

  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = signup_function) THEN
    RAISE EXCEPTION 'public.handle_new_user() must be SECURITY DEFINER';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE oid = signup_owner AND rolname IN ('anon', 'authenticated')
  ) THEN
    RAISE EXCEPTION 'public.handle_new_user() must be owned by a trusted database role';
  END IF;

  IF NOT COALESCE(signup_settings @> ARRAY['search_path=""']::text[], false) THEN
    RAISE EXCEPTION 'public.handle_new_user() must use an empty search_path';
  END IF;

  IF position('INSERT INTO public.profiles (id, full_name)' IN signup_definition) = 0
     OR signup_definition ~* 'raw_user_meta_data[^;]*role|INSERT INTO public\.profiles\s*\([^)]*role'
     OR COALESCE(array_length(regexp_split_to_array(signup_definition, '\mINSERT\M'), 1) - 1, 0) <> 1
     OR signup_definition ~* '\m(UPDATE|DELETE|TRUNCATE|EXECUTE|CALL|PERFORM)\M'
  THEN
    RAISE EXCEPTION 'public.handle_new_user() must insert only Auth ID/full name and ignore role metadata';
  END IF;

  IF profile_role_default IS NULL OR position('user' IN lower(profile_role_default)) = 0 THEN
    RAISE EXCEPTION 'public.profiles.role must default to user for trusted signup';
  END IF;

  IF NOT owner_can_insert_id OR NOT owner_can_insert_name
     OR (profiles_rls_enabled AND profiles_force_rls AND NOT owner_bypasses_rls)
     OR (profiles_rls_enabled AND NOT profiles_force_rls
         AND signup_owner <> profiles_owner AND NOT owner_bypasses_rls)
  THEN
    RAISE EXCEPTION 'handle_new_user owner cannot safely insert profiles after client policies are removed';
  END IF;

  SELECT count(*) INTO enabled_trigger_count
  FROM pg_trigger AS t
  WHERE t.tgrelid = 'auth.users'::regclass
    AND t.tgname = 'on_auth_user_created'
    AND t.tgfoid = signup_function
    AND t.tgtype = 5
    AND t.tgconstraint = 0
    AND NOT t.tgdeferrable
    AND NOT t.tginitdeferred
    AND t.tgenabled IN ('O', 'A')
    AND NOT t.tgisinternal;

  IF enabled_trigger_count <> 1 THEN
    RAISE EXCEPTION 'enabled AFTER INSERT row trigger must invoke public.handle_new_user()';
  END IF;

  IF NOT has_schema_privilege('anon', 'auth', 'USAGE')
     OR NOT has_schema_privilege('authenticated', 'auth', 'USAGE')
     OR to_regprocedure('auth.role()') IS NULL
     OR NOT has_function_privilege('anon', 'auth.role()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'auth.role()', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'API roles require Auth schema and auth.role() access for the profile insert guard';
  END IF;

  IF has_function_privilege('anon', signup_function, 'EXECUTE')
     OR has_function_privilege('authenticated', signup_function, 'EXECUTE')
  THEN
    RAISE EXCEPTION 'API roles must not be able to execute public.handle_new_user() directly';
  END IF;

  IF NOT has_schema_privilege(signup_owner, 'auth', 'USAGE')
     OR to_regprocedure('auth.role()') IS NULL
     OR NOT has_function_privilege(signup_owner, 'auth.role()', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'trusted signup and profile-trigger functions require Auth schema/function privileges';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policy
    WHERE polrelid = 'public.profiles'::regclass
      AND polcmd = '*'
  ) THEN
    RAISE EXCEPTION 'profiles has a FOR ALL policy; reconcile it explicitly before profile INSERT lockdown';
  END IF;
END;
$$;

-- Remove INSERT policies only. A FOR ALL policy can also authorize SELECT,
-- UPDATE, or DELETE, so the preflight above requires an explicit design review
-- instead of silently removing legitimate non-INSERT behavior.
DO $$
DECLARE
  policy_row record;
BEGIN
  FOR policy_row IN
    SELECT polname
    FROM pg_policy
    WHERE polrelid = 'public.profiles'::regclass
      AND polcmd = 'a'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.profiles', policy_row.polname);
  END LOOP;
END;
$$;

REVOKE INSERT ON TABLE public.profiles FROM PUBLIC, anon, authenticated;

-- Table-level REVOKE does not clear column-level ACL entries. Revoke every
-- direct client INSERT column grant, including grants to PUBLIC, then verify
-- effective privileges (which also detects inherited grants that need review).
DO $$
DECLARE
  column_grant record;
  grantee_sql text;
  signup_owner oid;
BEGIN
  FOR column_grant IN
    SELECT DISTINCT a.attname, acl.grantee, r.rolname
    FROM pg_attribute AS a
    CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
    LEFT JOIN pg_roles AS r ON r.oid = acl.grantee
    WHERE a.attrelid = 'public.profiles'::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND acl.privilege_type = 'INSERT'
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
      'REVOKE INSERT (%I) ON TABLE public.profiles FROM %s',
      column_grant.attname,
      grantee_sql
    );
  END LOOP;

  SELECT p.proowner INTO signup_owner
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'handle_new_user'
    AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype;

  IF has_table_privilege('anon', 'public.profiles', 'INSERT')
     OR has_any_column_privilege('anon', 'public.profiles', 'INSERT')
     OR has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     OR has_any_column_privilege('authenticated', 'public.profiles', 'INSERT')
     OR signup_owner IS NULL
     OR NOT has_column_privilege(signup_owner, 'public.profiles', 'id', 'INSERT')
     OR NOT has_column_privilege(signup_owner, 'public.profiles', 'full_name', 'INSERT')
  THEN
    RAISE EXCEPTION 'profile INSERT revocation or trusted signup privileges failed verification';
  END IF;
END;
$$;

-- Defense in depth: even if a future grant/policy is added accidentally, an
-- API role cannot create profiles directly. Trusted signup/backend owners pass.
CREATE OR REPLACE FUNCTION public.prevent_untrusted_profile_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  profiles_owner name;
BEGIN
  SELECT pg_catalog.pg_get_userbyid(c.relowner)
    INTO profiles_owner
  FROM pg_catalog.pg_class AS c
  WHERE c.oid = 'public.profiles'::regclass;

  IF current_user <> profiles_owner
     AND NOT EXISTS (
       SELECT 1
       FROM pg_catalog.pg_roles AS r
       WHERE r.rolname = current_user
         AND (r.rolsuper OR r.rolbypassrls)
     )
     AND COALESCE(auth.role(), '') NOT IN ('service_role', 'supabase_admin')
  THEN
    RAISE EXCEPTION 'Direct profile creation is not permitted'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.prevent_untrusted_profile_insert()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS prevent_untrusted_profile_insert ON public.profiles;
CREATE TRIGGER prevent_untrusted_profile_insert
BEFORE INSERT ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.prevent_untrusted_profile_insert();

DO $owner_postcondition$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS p
    WHERE p.oid = to_regprocedure('public.prevent_untrusted_profile_insert()')
      AND p.proowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'postgres')
      AND NOT p.prosecdef
      AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
      AND p.proconfig = ARRAY['search_path=""']::text[]
  ) THEN
    RAISE EXCEPTION 'Profile INSERT guard must retain the reviewed postgres owner and invoker attributes';
  END IF;
END;
$owner_postcondition$;

COMMIT;
