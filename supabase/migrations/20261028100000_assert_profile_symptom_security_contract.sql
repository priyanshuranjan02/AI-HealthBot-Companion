-- Forward-only verification for environments where
-- 20261027180000_least_privilege_profile_symptom_grants.sql is already applied.
-- This migration fails closed if the RLS policy expressions, trigger
-- configuration, or trusted trigger functions no longer match the reviewed
-- contract. It also removes structural privileges not used by the application
-- from service_role while retaining its existing CRUD rights.
BEGIN;

DO $security_contract$
DECLARE
  role_function record;
  insert_function record;
  signup_function record;
  profiles_owner oid;
  profiles_rls boolean;
  profiles_force_rls boolean;
  signup_owner_bypasses_rls boolean;
  expected_role_body constant text := $role_body$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role
     AND current_user NOT IN (
       'postgres',
       'service_role',
       'supabase_admin'
     )
     AND COALESCE(auth.role(), '') NOT IN (
       'service_role',
       'supabase_admin'
     )
  THEN
    RAISE EXCEPTION 'Changing account role is not permitted'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$role_body$;
  expected_insert_body constant text := $insert_body$
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
$insert_body$;
  expected_signup_body constant text := $signup_body$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$signup_body$;
  expected_policy_count integer;
  service_role_oid oid;
BEGIN
  IF to_regclass('public.profiles') IS NULL
     OR to_regclass('public.symptom_checks') IS NULL
     OR to_regclass('auth.users') IS NULL
  THEN
    RAISE EXCEPTION 'required profile, symptom, or Auth table is missing';
  END IF;

  IF (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.profiles'::regclass) <> 2
     OR (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.symptom_checks'::regclass) <> 5
  THEN
    RAISE EXCEPTION 'unexpected profile or symptom RLS policy count';
  END IF;

  -- pg_get_expr may omit auth qualification when auth is on search_path.
  -- Normalize only this equivalent function-name representation.
  WITH expected(policy_name, command, role_name, using_expression, check_expression) AS (
    VALUES
      ('Users can view own profile', 'r', 'authenticated', '(auth.uid() = id)', NULL::text),
      ('Users can update own profile', 'w', 'authenticated', '(auth.uid() = id)', '(auth.uid() = id)'),
      ('Users can view their own symptom checks', 'r', 'authenticated', '(auth.uid() = user_id)', NULL::text),
      ('Users can insert their own symptom checks', 'a', 'authenticated', NULL::text, '(auth.uid() = user_id)'),
      ('Users can delete their own symptom checks', 'd', 'authenticated', '(auth.uid() = user_id)', NULL::text),
      ('Anonymous users can insert symptom checks', 'a', 'anon', NULL::text, '(user_id IS NULL)'),
      ('Service role can read all symptom checks', 'r', 'service_role', 'true', NULL::text)
  ), mismatches AS (
    SELECT e.policy_name
    FROM expected AS e
    LEFT JOIN pg_policy AS p
      ON p.polrelid = CASE
        WHEN e.policy_name IN ('Users can view own profile', 'Users can update own profile')
          THEN 'public.profiles'::regclass
        ELSE 'public.symptom_checks'::regclass
      END
     AND p.polname::text = e.policy_name
    LEFT JOIN pg_roles AS r ON r.rolname::text = e.role_name
    WHERE p.oid IS NULL
       OR p.polcmd::text <> e.command
       OR p.polpermissive IS DISTINCT FROM true
       OR p.polroles IS DISTINCT FROM ARRAY[r.oid]::oid[]
       OR regexp_replace(regexp_replace(lower(COALESCE(pg_get_expr(p.polqual, p.polrelid), '')), '[[:space:]]+', '', 'g'), 'auth[.]uid[(][)]', 'uid()', 'g')
          IS DISTINCT FROM regexp_replace(regexp_replace(lower(COALESCE(e.using_expression, '')), '[[:space:]]+', '', 'g'), 'auth[.]uid[(][)]', 'uid()', 'g')
       OR regexp_replace(regexp_replace(lower(COALESCE(
            pg_get_expr(p.polwithcheck, p.polrelid),
            CASE WHEN p.polcmd::text = 'w' THEN pg_get_expr(p.polqual, p.polrelid) END,
            ''
          )), '[[:space:]]+', '', 'g'), 'auth[.]uid[(][)]', 'uid()', 'g')
          IS DISTINCT FROM regexp_replace(regexp_replace(lower(COALESCE(e.check_expression, '')), '[[:space:]]+', '', 'g'), 'auth[.]uid[(][)]', 'uid()', 'g')
  )
  SELECT count(*) INTO expected_policy_count FROM mismatches;

  IF expected_policy_count <> 0 THEN
    RAISE EXCEPTION 'profile or symptom RLS policy definition differs from the reviewed contract';
  END IF;

  SELECT p.* INTO role_function
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'prevent_profile_role_escalation'
    AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype;

  IF role_function.oid IS NULL
     OR role_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
     OR role_function.prosecdef
     OR NOT COALESCE(role_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR regexp_replace(role_function.prosrc, '[[:space:]]+', '', 'g')
        IS DISTINCT FROM regexp_replace(expected_role_body, '[[:space:]]+', '', 'g')
  THEN
    RAISE EXCEPTION 'profile role-protection function definition or security attributes differ';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS t
    JOIN pg_attribute AS a
      ON a.attrelid = t.tgrelid AND a.attname = 'role' AND NOT a.attisdropped
    WHERE t.tgrelid = 'public.profiles'::regclass
      AND t.tgname = 'prevent_profile_role_escalation'
      AND t.tgfoid = role_function.oid
      AND t.tgtype = 19 -- BEFORE ROW UPDATE
      AND array_length(t.tgattr, 1) = 1
      AND a.attnum = ANY(t.tgattr) -- UPDATE OF role only
      AND t.tgenabled IN ('O', 'A')
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'profile role-protection trigger must be enabled BEFORE ROW UPDATE OF role';
  END IF;

  SELECT p.* INTO insert_function
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'prevent_untrusted_profile_insert'
    AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype;

  IF insert_function.oid IS NULL
     OR insert_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
     OR insert_function.prosecdef
     OR NOT COALESCE(insert_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR regexp_replace(insert_function.prosrc, '[[:space:]]+', '', 'g')
        IS DISTINCT FROM regexp_replace(expected_insert_body, '[[:space:]]+', '', 'g')
     OR has_function_privilege('anon', insert_function.oid, 'EXECUTE')
     OR has_function_privilege('authenticated', insert_function.oid, 'EXECUTE')
     OR EXISTS (
       SELECT 1 FROM aclexplode(
         COALESCE(insert_function.proacl, acldefault('f', insert_function.proowner))
       ) AS acl
       WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'profile insert-guard function definition, security, or grants differ';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger AS t
    WHERE t.tgrelid = 'public.profiles'::regclass
      AND t.tgname = 'prevent_untrusted_profile_insert'
      AND t.tgfoid = insert_function.oid
      AND t.tgtype = 7 -- BEFORE ROW INSERT
      AND t.tgenabled IN ('O', 'A')
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'profile insert-guard trigger must be enabled BEFORE ROW INSERT';
  END IF;

  SELECT p.* INTO signup_function
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'handle_new_user'
    AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype;

  SELECT c.relowner, c.relrowsecurity, c.relforcerowsecurity
    INTO profiles_owner, profiles_rls, profiles_force_rls
  FROM pg_class AS c
  WHERE c.oid = 'public.profiles'::regclass;

  IF signup_function.oid IS NULL
     OR NOT signup_function.prosecdef
     OR NOT COALESCE(signup_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR regexp_replace(signup_function.prosrc, '[[:space:]]+', '', 'g')
        IS DISTINCT FROM regexp_replace(expected_signup_body, '[[:space:]]+', '', 'g')
     OR signup_function.proowner IN (
       SELECT oid FROM pg_roles WHERE rolname IN ('anon', 'authenticated')
     )
     OR NOT has_schema_privilege(signup_function.proowner, 'public', 'USAGE')
     OR NOT has_schema_privilege(signup_function.proowner, 'auth', 'USAGE')
     OR NOT has_function_privilege(signup_function.proowner, 'auth.role()', 'EXECUTE')
     OR NOT has_column_privilege(signup_function.proowner, 'public.profiles', 'id', 'INSERT')
     OR NOT has_column_privilege(signup_function.proowner, 'public.profiles', 'full_name', 'INSERT')
     OR has_function_privilege('anon', signup_function.oid, 'EXECUTE')
     OR has_function_privilege('authenticated', signup_function.oid, 'EXECUTE')
     OR EXISTS (
       SELECT 1 FROM aclexplode(
         COALESCE(signup_function.proacl, acldefault('f', signup_function.proowner))
       ) AS acl
       WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'
     )
  THEN
    RAISE EXCEPTION 'trusted Auth signup function definition, security, privileges, or grants differ';
  END IF;

  SELECT r.rolsuper OR r.rolbypassrls INTO signup_owner_bypasses_rls
  FROM pg_roles AS r WHERE r.oid = signup_function.proowner;

  IF (profiles_rls AND profiles_force_rls AND NOT signup_owner_bypasses_rls)
     OR (profiles_rls AND NOT profiles_force_rls
         AND signup_function.proowner <> profiles_owner AND NOT signup_owner_bypasses_rls)
  THEN
    RAISE EXCEPTION 'trusted Auth signup owner cannot insert through profiles RLS';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_attrdef AS d
    JOIN pg_attribute AS a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    WHERE d.adrelid = 'public.profiles'::regclass
      AND a.attname = 'role'
      AND position('user' IN lower(pg_get_expr(d.adbin, d.adrelid))) > 0
  ) THEN
    RAISE EXCEPTION 'profiles.role must retain a user default for Auth signup';
  END IF;

  IF (SELECT count(*) FROM pg_trigger AS t
      WHERE t.tgrelid = 'auth.users'::regclass
        AND t.tgfoid = signup_function.oid
        AND t.tgtype = 5
        AND t.tgenabled IN ('O', 'A')
        AND NOT t.tgisinternal) <> 1
     OR NOT EXISTS (
       SELECT 1 FROM pg_trigger AS t
       WHERE t.tgrelid = 'auth.users'::regclass
         AND t.tgname = 'on_auth_user_created'
         AND t.tgfoid = signup_function.oid
         AND t.tgtype = 5
         AND t.tgenabled IN ('O', 'A')
         AND NOT t.tgisinternal
     )
  THEN
    RAISE EXCEPTION 'exactly one enabled Auth AFTER ROW INSERT trigger must call handle_new_user()';
  END IF;

  SELECT oid INTO service_role_oid FROM pg_roles WHERE rolname = 'service_role';
  IF service_role_oid IS NULL
     OR EXISTS (
       SELECT 1 FROM pg_class AS c
       WHERE c.oid IN ('public.profiles'::regclass, 'public.symptom_checks'::regclass)
         AND c.relowner = service_role_oid
     )
  THEN
    RAISE EXCEPTION 'service_role must exist and must not own profiles or symptom_checks';
  END IF;
END;
$security_contract$;

-- The application requires CRUD through trusted backend paths, but no code
-- creates/truncates these tables, adds foreign keys, or creates table triggers.
REVOKE TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.profiles, public.symptom_checks
  FROM service_role;

DO $service_role_privileges$
BEGIN
  IF NOT has_table_privilege('service_role', 'public.profiles', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'INSERT')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'UPDATE')
     OR NOT has_table_privilege('service_role', 'public.profiles', 'DELETE')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'INSERT')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'UPDATE')
     OR NOT has_table_privilege('service_role', 'public.symptom_checks', 'DELETE')
     OR has_table_privilege('service_role', 'public.profiles', 'TRUNCATE')
     OR has_table_privilege('service_role', 'public.profiles', 'REFERENCES')
     OR has_table_privilege('service_role', 'public.profiles', 'TRIGGER')
     OR has_table_privilege('service_role', 'public.symptom_checks', 'TRUNCATE')
     OR has_table_privilege('service_role', 'public.symptom_checks', 'REFERENCES')
     OR has_table_privilege('service_role', 'public.symptom_checks', 'TRIGGER')
  THEN
    RAISE EXCEPTION 'service_role table privileges do not match CRUD-only contract';
  END IF;
END;
$service_role_privileges$;

COMMIT;
