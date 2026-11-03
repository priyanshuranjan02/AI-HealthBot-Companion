-- PostgreSQL 17 forward migration for the verified post-20261028100000 state.
-- It removes only the residual MAINTAIN table privilege from service_role.
-- This is not compatible with the separate 20261029120000 Lovable-baseline
-- migration path; see docs/admin-and-signup-operations.md before deployment.
BEGIN;

DO $preflight$
DECLARE
  profiles_oid oid;
  symptoms_oid oid;
  profiles_owner oid;
  symptoms_owner oid;
  anon_oid oid;
  authenticated_oid oid;
  service_role_oid oid;
  postgres_oid oid;
  role_function record;
  insert_function record;
  signup_function record;
  audit_function record;
  analytics_function record;
  submit_function record;
  review_function record;
  expected_policy_count integer;
  expected_analytics_body constant text := $analytics_body$
SELECT jsonb_build_object(
    'totalChecks', NULL,
    'totalUsers', NULL,
    'severityCounts', jsonb_build_object('low', NULL, 'moderate', NULL, 'high', NULL),
    'topDiagnoses', '[]'::jsonb,
    'dailyChecks', '[]'::jsonb,
    'monthlyAssessments', '[]'::jsonb,
    'predictionTrend', '[]'::jsonb,
    'languageDistribution', '{}'::jsonb,
    'languageBreakdown', '[]'::jsonb,
    'topSymptoms', '[]'::jsonb,
    'avgConfidence', NULL,
    'highRiskCases', NULL,
    'privacySuppressed', true,
    'minimumCohort', 10,
    'suppressedBreakdowns', jsonb_build_array('all')
  );
$analytics_body$;
  expected_audit_body constant text := $audit_body$
BEGIN
  UPDATE public.admin_audit_log
  SET actor_id = NULL,
      target_user_id = NULL,
      application_id = NULL,
      details = '{}'::jsonb,
      anonymized_at = now()
  WHERE actor_id = OLD.id
     OR target_user_id = OLD.id
     OR application_id IN (
       SELECT application.id
       FROM public.ngo_applications AS application
       WHERE application.applicant_user_id = OLD.id
     );

  RETURN OLD;
END;
$audit_body$;
BEGIN
  IF current_setting('server_version_num')::integer < 170000 THEN
    RAISE EXCEPTION 'This migration requires PostgreSQL 17 or later for MAINTAIN privilege semantics';
  END IF;

  profiles_oid := to_regclass('public.profiles');
  symptoms_oid := to_regclass('public.symptom_checks');
  IF profiles_oid IS NULL OR symptoms_oid IS NULL
     OR to_regclass('auth.users') IS NULL
     OR to_regclass('public.user_roles') IS NULL
     OR to_regclass('public.ngo_applications') IS NULL
     OR to_regclass('public.admin_audit_log') IS NULL THEN
    RAISE EXCEPTION 'post-20261028 profile, symptom, Auth, NGO, and audit objects are required';
  END IF;

  SELECT oid INTO anon_oid FROM pg_roles WHERE rolname = 'anon';
  SELECT oid INTO authenticated_oid FROM pg_roles WHERE rolname = 'authenticated';
  SELECT oid INTO service_role_oid FROM pg_roles WHERE rolname = 'service_role';
  SELECT oid INTO postgres_oid FROM pg_roles WHERE rolname = 'postgres';
  IF anon_oid IS NULL OR authenticated_oid IS NULL
     OR service_role_oid IS NULL OR postgres_oid IS NULL THEN
    RAISE EXCEPTION 'Supabase API roles and the reviewed postgres function owner are required';
  END IF;

  SELECT relowner INTO profiles_owner FROM pg_class WHERE oid = profiles_oid;
  SELECT relowner INTO symptoms_owner FROM pg_class WHERE oid = symptoms_oid;
  IF profiles_owner <> postgres_oid OR symptoms_owner <> postgres_oid THEN
    RAISE EXCEPTION 'profiles and symptom_checks must retain the reviewed postgres owner';
  END IF;

  -- The runner must itself be a table owner or a superuser. Membership alone
  -- is not treated as proof of authority to revoke the table ACL.
  IF NOT (current_user = pg_get_userbyid(profiles_owner)
          AND current_user = pg_get_userbyid(symptoms_owner))
     AND NOT COALESCE((SELECT rolsuper FROM pg_roles WHERE rolname = current_user), false) THEN
    RAISE EXCEPTION 'Migration runner must directly own both protected tables or be a superuser';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname IN ('anon', 'authenticated')
      AND (rolsuper OR rolbypassrls)
  ) OR EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'service_role' AND rolsuper
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'service_role' AND rolbypassrls
  ) THEN
    RAISE EXCEPTION 'API role attributes differ from the reviewed Supabase role contract';
  END IF;

  -- Strict membership contract: API roles cannot inherit from or SET ROLE to
  -- any other role. Inbound authenticator -> API-role memberships are allowed.
  IF EXISTS (
    SELECT 1 FROM pg_auth_members
    WHERE member IN (anon_oid, authenticated_oid, service_role_oid)
  ) THEN
    RAISE EXCEPTION 'anon, authenticated, and service_role must have no outbound role memberships';
  END IF;

  IF EXISTS (
    WITH RECURSIVE settable_roles(api_oid, role_oid) AS (
      SELECT r.oid, r.oid FROM pg_roles AS r
      WHERE r.oid IN (anon_oid, authenticated_oid, service_role_oid)
      UNION
      SELECT s.api_oid, m.roleid
      FROM settable_roles AS s
      JOIN pg_auth_members AS m ON m.member = s.role_oid
      WHERE m.set_option
    )
    SELECT 1 FROM settable_roles WHERE role_oid <> api_oid
  ) OR EXISTS (
    WITH RECURSIVE inherited_roles(api_oid, role_oid) AS (
      SELECT r.oid, r.oid FROM pg_roles AS r
      WHERE r.oid IN (anon_oid, authenticated_oid, service_role_oid)
      UNION
      SELECT i.api_oid, m.roleid
      FROM inherited_roles AS i
      JOIN pg_auth_members AS m ON m.member = i.role_oid
      WHERE m.inherit_option
    )
    SELECT 1 FROM inherited_roles WHERE role_oid <> api_oid
  ) THEN
    RAISE EXCEPTION 'API roles have an unexpected SET ROLE or inherited membership path';
  END IF;

  IF NOT (SELECT relrowsecurity AND NOT relforcerowsecurity
          FROM pg_class WHERE oid = profiles_oid)
     OR NOT (SELECT relrowsecurity AND NOT relforcerowsecurity
             FROM pg_class WHERE oid = symptoms_oid) THEN
    RAISE EXCEPTION 'RLS must be enabled and FORCE RLS disabled on both protected tables';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = profiles_oid AND attname = 'role'
      AND attnum > 0 AND NOT attisdropped AND attnotnull
      AND atttypid = 'text'::regtype
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_attrdef AS d
    JOIN pg_attribute AS a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    WHERE d.adrelid = profiles_oid AND a.attname = 'role'
      AND regexp_replace(pg_get_expr(d.adbin, d.adrelid), '[[:space:]]+', '', 'g') = '''user''::text'
  ) OR (SELECT count(*) FROM pg_constraint AS c
        WHERE c.conrelid = profiles_oid AND c.conname = 'profiles_role_allowed_values'
          AND c.contype = 'c' AND c.convalidated
          AND regexp_replace(lower(pg_get_constraintdef(c.oid)), '[[:space:]]+', '', 'g')
            = 'check((role=any(array[''user''::text,''ngo''::text])))') <> 1
     OR (SELECT count(*) FROM pg_constraint AS c
         WHERE c.conrelid = profiles_oid AND c.contype = 'c'
           AND (SELECT attnum FROM pg_attribute
                WHERE attrelid = profiles_oid AND attname = 'role' AND NOT attisdropped) = ANY(c.conkey)) <> 1
     OR EXISTS (SELECT 1 FROM public.profiles WHERE role IS NULL OR role NOT IN ('user', 'ngo')) THEN
    RAISE EXCEPTION 'profiles.role must be NOT NULL, default to user, and allow only user/ngo values';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = symptoms_oid AND conname = 'symptom_checks_user_id_fkey'
      AND contype = 'f' AND confrelid = 'auth.users'::regclass AND confdeltype = 'c'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.admin_audit_log'::regclass
      AND conname = 'admin_audit_log_actor_id_fkey'
      AND contype = 'f' AND confrelid = profiles_oid AND confdeltype = 'n'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.ngo_applications'::regclass
      AND conname = 'ngo_applications_reviewer_id_fkey'
      AND contype = 'f' AND confdeltype = 'n'
  ) THEN
    RAISE EXCEPTION 'account-deletion cascade and reviewer/audit SET NULL constraints must remain installed';
  END IF;

  IF (SELECT count(*) FROM pg_policy WHERE polrelid = profiles_oid) <> 2
     OR (SELECT count(*) FROM pg_policy WHERE polrelid = symptoms_oid) <> 5 THEN
    RAISE EXCEPTION 'profile or symptom policy set differs from the post-20261028 contract';
  END IF;

  -- Normalize equivalent auth.uid() rendering from pg_get_expr.
  -- Keep policy commands, roles, predicates, and ACL checks strict.
  WITH expected(table_oid, policy_name, command, role_name, using_expression, check_expression) AS (
    VALUES
      (profiles_oid, 'Users can view own profile', 'r', 'authenticated', '(auth.uid() = id)', NULL::text),
      (profiles_oid, 'Users can update own profile', 'w', 'authenticated', '(auth.uid() = id)', '(auth.uid() = id)'),
      (symptoms_oid, 'Users can view their own symptom checks', 'r', 'authenticated', '(auth.uid() = user_id)', NULL::text),
      (symptoms_oid, 'Users can insert their own symptom checks', 'a', 'authenticated', NULL::text, '(auth.uid() = user_id)'),
      (symptoms_oid, 'Users can delete their own symptom checks', 'd', 'authenticated', '(auth.uid() = user_id)', NULL::text),
      (symptoms_oid, 'Anonymous users can insert symptom checks', 'a', 'anon', NULL::text, '(user_id IS NULL)'),
      (symptoms_oid, 'Service role can read all symptom checks', 'r', 'service_role', 'true', NULL::text)
  ), mismatches AS (
    SELECT e.policy_name
    FROM expected AS e
    LEFT JOIN pg_policy AS p ON p.polrelid = e.table_oid AND p.polname::text = e.policy_name
    LEFT JOIN pg_roles AS r ON r.rolname = e.role_name
    WHERE p.oid IS NULL
       OR p.polcmd::text <> e.command
       OR p.polpermissive IS DISTINCT FROM true
       OR p.polroles IS DISTINCT FROM ARRAY[r.oid]::oid[]
       OR regexp_replace(
            regexp_replace(
              lower(COALESCE(pg_get_expr(p.polqual, p.polrelid), '')),
              '[[:space:]]+', '', 'g'
            ),
            'auth[.]uid[(][)]', 'uid()', 'g'
          ) IS DISTINCT FROM regexp_replace(
            regexp_replace(
              lower(COALESCE(e.using_expression, '')),
              '[[:space:]]+', '', 'g'
            ),
            'auth[.]uid[(][)]', 'uid()', 'g'
          )
       OR regexp_replace(
            regexp_replace(
              lower(COALESCE(
                pg_get_expr(p.polwithcheck, p.polrelid),
                CASE WHEN p.polcmd::text = 'w' THEN pg_get_expr(p.polqual, p.polrelid) END,
                ''
              )),
              '[[:space:]]+', '', 'g'
            ),
            'auth[.]uid[(][)]', 'uid()', 'g'
          ) IS DISTINCT FROM regexp_replace(
            regexp_replace(
              lower(COALESCE(e.check_expression, '')),
              '[[:space:]]+', '', 'g'
            ),
            'auth[.]uid[(][)]', 'uid()', 'g'
          )
  )
  SELECT count(*) INTO expected_policy_count FROM mismatches;
  IF expected_policy_count <> 0 THEN
    RAISE EXCEPTION 'profile or symptom policy roles, commands, or predicates differ from the reviewed contract';
  END IF;

  SELECT p.* INTO signup_function
  FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'handle_new_user'
    AND p.pronargs = 0 AND p.prorettype = 'pg_catalog.trigger'::regtype;
  IF signup_function.oid IS NULL
     OR signup_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
     OR signup_function.proowner <> postgres_oid OR NOT signup_function.prosecdef
     OR NOT COALESCE(signup_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR regexp_replace(signup_function.prosrc, '[[:space:]]+', '', 'g')
        IS DISTINCT FROM regexp_replace($signup_body$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$signup_body$, '[[:space:]]+', '', 'g')
     OR NOT has_column_privilege(signup_function.proowner, profiles_oid, 'id', 'INSERT')
     OR NOT has_column_privilege(signup_function.proowner, profiles_oid, 'full_name', 'INSERT')
     OR has_function_privilege(anon_oid, signup_function.oid, 'EXECUTE')
     OR has_function_privilege(authenticated_oid, signup_function.oid, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(signup_function.proacl, acldefault('f', signup_function.proowner))) AS acl
                WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'handle_new_user owner, body, security attributes, or execution grants differ';
  END IF;

  IF (SELECT count(*) FROM pg_trigger AS t
      WHERE t.tgrelid = 'auth.users'::regclass AND t.tgname = 'on_auth_user_created'
        AND t.tgfoid = signup_function.oid AND t.tgtype = 5
        AND t.tgenabled IN ('O', 'A') AND t.tgqual IS NULL
        AND t.tgconstraint = 0 AND NOT t.tgdeferrable AND NOT t.tginitdeferred
        AND array_length(t.tgattr, 1) = 0
        AND NOT t.tgisinternal) <> 1 THEN
    RAISE EXCEPTION 'exactly one unconditional enabled Auth AFTER INSERT row signup trigger is required';
  END IF;

  SELECT p.* INTO role_function
  FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'prevent_profile_role_escalation'
    AND p.pronargs = 0 AND p.prorettype = 'pg_catalog.trigger'::regtype;
  IF role_function.oid IS NULL
     OR role_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
     OR role_function.proowner <> postgres_oid OR role_function.prosecdef
     OR NOT COALESCE(role_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR regexp_replace(role_function.prosrc, '[[:space:]]+', '', 'g')
        IS DISTINCT FROM regexp_replace($role_body$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role
     AND current_user NOT IN ('postgres', 'service_role', 'supabase_admin')
     AND COALESCE(auth.role(), '') NOT IN ('service_role', 'supabase_admin')
  THEN
    RAISE EXCEPTION 'Changing account role is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$role_body$, '[[:space:]]+', '', 'g') THEN
    RAISE EXCEPTION 'profile role-guard function definition or attributes differ';
  END IF;

  IF (SELECT count(*) FROM pg_trigger AS t
      WHERE t.tgrelid = profiles_oid AND NOT t.tgisinternal) <> 3
     OR (SELECT count(*) FROM pg_trigger AS t
         WHERE t.tgrelid = profiles_oid AND t.tgname = 'prevent_profile_role_escalation'
           AND t.tgfoid = role_function.oid AND t.tgtype = 19
           AND array_length(t.tgattr, 1) = 1
           AND (SELECT attnum FROM pg_attribute WHERE attrelid = profiles_oid AND attname = 'role' AND NOT attisdropped) = ANY(t.tgattr)
           AND t.tgenabled IN ('O', 'A') AND t.tgqual IS NULL
           AND t.tgconstraint = 0 AND NOT t.tgdeferrable AND NOT t.tginitdeferred
           AND NOT t.tgisinternal) <> 1 THEN
    RAISE EXCEPTION 'exactly one unconditional BEFORE UPDATE OF role guard trigger is required';
  END IF;

  SELECT p.* INTO insert_function
  FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'prevent_untrusted_profile_insert'
    AND p.pronargs = 0 AND p.prorettype = 'pg_catalog.trigger'::regtype;
  IF insert_function.oid IS NULL
     OR insert_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
     OR insert_function.proowner <> postgres_oid OR insert_function.prosecdef
     OR NOT COALESCE(insert_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR regexp_replace(insert_function.prosrc, '[[:space:]]+', '', 'g')
        IS DISTINCT FROM regexp_replace($insert_body$
DECLARE
  profiles_owner name;
BEGIN
  SELECT pg_catalog.pg_get_userbyid(c.relowner) INTO profiles_owner
  FROM pg_catalog.pg_class AS c WHERE c.oid = 'public.profiles'::regclass;
  IF current_user <> profiles_owner
     AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles AS r
                     WHERE r.rolname = current_user AND (r.rolsuper OR r.rolbypassrls))
     AND COALESCE(auth.role(), '') NOT IN ('service_role', 'supabase_admin')
  THEN
    RAISE EXCEPTION 'Direct profile creation is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$insert_body$, '[[:space:]]+', '', 'g')
     OR has_function_privilege(anon_oid, insert_function.oid, 'EXECUTE')
     OR has_function_privilege(authenticated_oid, insert_function.oid, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(insert_function.proacl, acldefault('f', insert_function.proowner))) AS acl
                WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'profile insert-guard function definition, owner, or grants differ';
  END IF;

  IF (SELECT count(*) FROM pg_trigger AS t
      WHERE t.tgrelid = profiles_oid AND t.tgname = 'prevent_untrusted_profile_insert'
        AND t.tgfoid = insert_function.oid AND t.tgtype = 7
        AND t.tgenabled IN ('O', 'A') AND t.tgqual IS NULL
        AND t.tgconstraint = 0 AND NOT t.tgdeferrable AND NOT t.tginitdeferred
        AND NOT t.tgisinternal) <> 1 THEN
    RAISE EXCEPTION 'exactly one unconditional BEFORE INSERT profile-guard trigger is required';
  END IF;

  SELECT p.* INTO audit_function
  FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'anonymize_account_audit_records'
    AND p.pronargs = 0 AND p.prorettype = 'pg_catalog.trigger'::regtype;
  IF audit_function.oid IS NULL
     OR audit_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
     OR audit_function.proowner <> postgres_oid OR NOT audit_function.prosecdef
     OR NOT COALESCE(audit_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR regexp_replace(audit_function.prosrc, '[[:space:]]+', '', 'g')
        IS DISTINCT FROM regexp_replace(expected_audit_body, '[[:space:]]+', '', 'g')
     OR has_function_privilege(anon_oid, audit_function.oid, 'EXECUTE')
     OR has_function_privilege(authenticated_oid, audit_function.oid, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(audit_function.proacl, acldefault('f', audit_function.proowner))) AS acl
                WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'audit anonymization function definition, owner, or grants differ';
  END IF;

  IF (SELECT count(*) FROM pg_trigger AS t
      WHERE t.tgrelid = profiles_oid AND t.tgname = 'anonymize_account_audit_records_before_profile_delete'
        AND t.tgfoid = audit_function.oid AND t.tgtype = 11
        AND t.tgenabled IN ('O', 'A') AND t.tgqual IS NULL
        AND t.tgconstraint = 0 AND NOT t.tgdeferrable AND NOT t.tginitdeferred
        AND NOT t.tgisinternal) <> 1 THEN
    RAISE EXCEPTION 'account audit anonymization trigger is missing or changed';
  END IF;

  SELECT p.* INTO analytics_function
  FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_ngo_dashboard_stats'
    AND p.pronargs = 0 AND p.prorettype = 'jsonb'::regtype;
  IF analytics_function.oid IS NULL
     OR analytics_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'sql')
     OR NOT analytics_function.prosecdef
     OR analytics_function.proowner <> postgres_oid
     OR NOT COALESCE(analytics_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR regexp_replace(analytics_function.prosrc, '[[:space:]]+', '', 'g')
        IS DISTINCT FROM regexp_replace(expected_analytics_body, '[[:space:]]+', '', 'g')
     OR NOT has_function_privilege(service_role_oid, analytics_function.oid, 'EXECUTE')
     OR has_function_privilege(anon_oid, analytics_function.oid, 'EXECUTE')
     OR has_function_privilege(authenticated_oid, analytics_function.oid, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(analytics_function.proacl, acldefault('f', analytics_function.proowner))) AS acl
                WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'fail-closed analytics RPC definition or execution permissions differ';
  END IF;

  SELECT * INTO submit_function FROM pg_proc
  WHERE oid = to_regprocedure('public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)');
  SELECT * INTO review_function FROM pg_proc
  WHERE oid = to_regprocedure('public.review_ngo_application(uuid,uuid,text,text)');
  IF submit_function.oid IS NULL OR review_function.oid IS NULL
     OR submit_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
     OR review_function.prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
     OR NOT submit_function.prosecdef OR NOT review_function.prosecdef
     OR NOT COALESCE(submit_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR NOT COALESCE(review_function.proconfig @> ARRAY['search_path=""']::text[], false)
     OR submit_function.proowner <> postgres_oid OR review_function.proowner <> postgres_oid
     OR NOT has_function_privilege(service_role_oid, submit_function.oid, 'EXECUTE')
     OR NOT has_function_privilege(service_role_oid, review_function.oid, 'EXECUTE')
     OR has_function_privilege(anon_oid, submit_function.oid, 'EXECUTE')
     OR has_function_privilege(authenticated_oid, submit_function.oid, 'EXECUTE')
     OR has_function_privilege(anon_oid, review_function.oid, 'EXECUTE')
     OR has_function_privilege(authenticated_oid, review_function.oid, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(submit_function.proacl, acldefault('f', submit_function.proowner))) AS acl
                WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
     OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(review_function.proacl, acldefault('f', review_function.proowner))) AS acl
                WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'NGO submission/review RPC definitions or execution permissions differ';
  END IF;

  -- Exact non-MAINTAIN table ACL matrix. The only optional pre-upgrade ACL is
  -- one non-grantable MAINTAIN entry to service_role per table. The verified
  -- migration sequence grants through the table owner; other grantors or
  -- duplicate entries are treated as drift, not silently normalized.
  IF EXISTS (
    SELECT 1 FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
    WHERE c.oid IN (profiles_oid, symptoms_oid)
      AND (acl.grantee = 0 OR acl.grantee NOT IN (c.relowner, anon_oid, authenticated_oid, service_role_oid))
  ) THEN
    RAISE EXCEPTION 'unexpected PUBLIC or non-contract table ACL grantee';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_attribute AS a
    CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
    WHERE a.attrelid IN (profiles_oid, symptoms_oid)
      AND a.attnum > 0 AND NOT a.attisdropped
  ) THEN
    RAISE EXCEPTION 'column-level ACLs exist on a protected table';
  END IF;

  IF EXISTS (
    WITH expected(table_oid, grantee, privilege_type) AS (
      VALUES
        (profiles_oid, authenticated_oid, 'SELECT'), (profiles_oid, authenticated_oid, 'UPDATE'),
        (profiles_oid, service_role_oid, 'SELECT'), (profiles_oid, service_role_oid, 'INSERT'),
        (profiles_oid, service_role_oid, 'UPDATE'), (profiles_oid, service_role_oid, 'DELETE'),
        (symptoms_oid, anon_oid, 'INSERT'),
        (symptoms_oid, authenticated_oid, 'SELECT'), (symptoms_oid, authenticated_oid, 'INSERT'),
        (symptoms_oid, authenticated_oid, 'DELETE'),
        (symptoms_oid, service_role_oid, 'SELECT'), (symptoms_oid, service_role_oid, 'INSERT'),
        (symptoms_oid, service_role_oid, 'UPDATE'), (symptoms_oid, service_role_oid, 'DELETE')
    ), actual AS (
      SELECT c.oid AS table_oid, acl.grantee, acl.privilege_type,
             acl.is_grantable, acl.grantor
      FROM pg_class AS c
      CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
      WHERE c.oid IN (profiles_oid, symptoms_oid)
        AND acl.grantee IN (anon_oid, authenticated_oid, service_role_oid)
        AND acl.privilege_type <> 'MAINTAIN'
    ), bad_expected AS (
      SELECT e.table_oid, e.grantee, e.privilege_type
      FROM expected AS e
      LEFT JOIN actual AS a ON a.table_oid = e.table_oid
        AND a.grantee = e.grantee AND a.privilege_type = e.privilege_type
      GROUP BY e.table_oid, e.grantee, e.privilege_type
      HAVING count(a.table_oid) <> 1
    ), bad_actual AS (
      SELECT a.table_oid, a.grantee, a.privilege_type
      FROM actual AS a
      LEFT JOIN expected AS e ON e.table_oid = a.table_oid
        AND e.grantee = a.grantee AND e.privilege_type = a.privilege_type
      WHERE e.table_oid IS NULL OR a.is_grantable
    ), bad_owner_grants AS (
      SELECT 1 FROM pg_class AS c
      CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
      WHERE c.oid IN (profiles_oid, symptoms_oid)
        AND acl.grantee IN (anon_oid, authenticated_oid, service_role_oid)
        AND acl.grantor <> c.relowner
    )
    SELECT 1 FROM bad_expected
    UNION ALL SELECT 1 FROM bad_actual
    UNION ALL SELECT 1 FROM bad_owner_grants
  ) THEN
    RAISE EXCEPTION 'direct API-role ACLs differ from the exact post-20261028 CRUD matrix';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
    WHERE c.oid IN (profiles_oid, symptoms_oid)
      AND acl.grantee IN (anon_oid, authenticated_oid, service_role_oid)
      AND acl.privilege_type = 'MAINTAIN'
      AND (acl.grantee <> service_role_oid OR acl.is_grantable OR acl.grantor <> c.relowner)
  ) OR EXISTS (
    SELECT 1 FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
    WHERE c.oid IN (profiles_oid, symptoms_oid)
      AND acl.grantee = service_role_oid AND acl.privilege_type = 'MAINTAIN'
    GROUP BY c.oid HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'only one non-grantable owner-granted service_role MAINTAIN ACL per table is accepted';
  END IF;

  IF has_table_privilege(anon_oid, profiles_oid, 'SELECT')
     OR has_table_privilege(anon_oid, profiles_oid, 'INSERT')
     OR has_table_privilege(anon_oid, profiles_oid, 'UPDATE')
     OR has_table_privilege(anon_oid, profiles_oid, 'DELETE')
     OR has_table_privilege(anon_oid, profiles_oid, 'TRUNCATE')
     OR has_table_privilege(anon_oid, profiles_oid, 'REFERENCES')
     OR has_table_privilege(anon_oid, profiles_oid, 'TRIGGER')
     OR has_table_privilege(anon_oid, profiles_oid, 'MAINTAIN')
     OR has_table_privilege(anon_oid, symptoms_oid, 'SELECT')
     OR NOT has_table_privilege(anon_oid, symptoms_oid, 'INSERT')
     OR has_table_privilege(anon_oid, symptoms_oid, 'UPDATE')
     OR has_table_privilege(anon_oid, symptoms_oid, 'DELETE')
     OR has_table_privilege(anon_oid, symptoms_oid, 'TRUNCATE')
     OR has_table_privilege(anon_oid, symptoms_oid, 'REFERENCES')
     OR has_table_privilege(anon_oid, symptoms_oid, 'TRIGGER')
     OR has_table_privilege(anon_oid, symptoms_oid, 'MAINTAIN')
     OR NOT has_table_privilege(authenticated_oid, profiles_oid, 'SELECT')
     OR has_table_privilege(authenticated_oid, profiles_oid, 'INSERT')
     OR NOT has_table_privilege(authenticated_oid, profiles_oid, 'UPDATE')
     OR has_table_privilege(authenticated_oid, profiles_oid, 'DELETE')
     OR has_table_privilege(authenticated_oid, profiles_oid, 'TRUNCATE')
     OR has_table_privilege(authenticated_oid, profiles_oid, 'REFERENCES')
     OR has_table_privilege(authenticated_oid, profiles_oid, 'TRIGGER')
     OR has_table_privilege(authenticated_oid, profiles_oid, 'MAINTAIN')
     OR NOT has_table_privilege(authenticated_oid, symptoms_oid, 'SELECT')
     OR NOT has_table_privilege(authenticated_oid, symptoms_oid, 'INSERT')
     OR has_table_privilege(authenticated_oid, symptoms_oid, 'UPDATE')
     OR NOT has_table_privilege(authenticated_oid, symptoms_oid, 'DELETE')
     OR has_table_privilege(authenticated_oid, symptoms_oid, 'TRUNCATE')
     OR has_table_privilege(authenticated_oid, symptoms_oid, 'REFERENCES')
     OR has_table_privilege(authenticated_oid, symptoms_oid, 'TRIGGER')
     OR has_table_privilege(authenticated_oid, symptoms_oid, 'MAINTAIN')
     OR NOT has_table_privilege(service_role_oid, profiles_oid, 'SELECT')
     OR NOT has_table_privilege(service_role_oid, profiles_oid, 'INSERT')
     OR NOT has_table_privilege(service_role_oid, profiles_oid, 'UPDATE')
     OR NOT has_table_privilege(service_role_oid, profiles_oid, 'DELETE')
     OR has_table_privilege(service_role_oid, profiles_oid, 'TRUNCATE')
     OR has_table_privilege(service_role_oid, profiles_oid, 'REFERENCES')
     OR has_table_privilege(service_role_oid, profiles_oid, 'TRIGGER')
     OR NOT has_table_privilege(service_role_oid, symptoms_oid, 'SELECT')
     OR NOT has_table_privilege(service_role_oid, symptoms_oid, 'INSERT')
     OR NOT has_table_privilege(service_role_oid, symptoms_oid, 'UPDATE')
     OR NOT has_table_privilege(service_role_oid, symptoms_oid, 'DELETE')
     OR has_table_privilege(service_role_oid, symptoms_oid, 'TRUNCATE')
     OR has_table_privilege(service_role_oid, symptoms_oid, 'REFERENCES')
     OR has_table_privilege(service_role_oid, symptoms_oid, 'TRIGGER')
     OR has_table_privilege(anon_oid, profiles_oid, 'MAINTAIN')
     OR has_table_privilege(authenticated_oid, profiles_oid, 'MAINTAIN')
     OR has_table_privilege(anon_oid, symptoms_oid, 'MAINTAIN')
     OR has_table_privilege(authenticated_oid, symptoms_oid, 'MAINTAIN')
     OR has_any_column_privilege(anon_oid, profiles_oid, 'SELECT')
     OR has_any_column_privilege(anon_oid, profiles_oid, 'INSERT')
     OR has_any_column_privilege(authenticated_oid, profiles_oid, 'INSERT')
     OR has_any_column_privilege(anon_oid, symptoms_oid, 'SELECT')
     OR has_any_column_privilege(anon_oid, symptoms_oid, 'UPDATE')
     OR has_any_column_privilege(authenticated_oid, symptoms_oid, 'UPDATE') THEN
    RAISE EXCEPTION 'effective CRUD or column privileges differ from the intended API matrix';
  END IF;

  IF has_any_column_privilege(service_role_oid, profiles_oid, 'REFERENCES')
     OR has_any_column_privilege(service_role_oid, symptoms_oid, 'REFERENCES') THEN
    RAISE EXCEPTION 'service_role has an unexpected column-level REFERENCES privilege';
  END IF;
END;
$preflight$;

REVOKE MAINTAIN ON TABLE public.profiles, public.symptom_checks FROM service_role;

DO $postconditions$
DECLARE
  profiles_oid oid := 'public.profiles'::regclass;
  symptoms_oid oid := 'public.symptom_checks'::regclass;
BEGIN
  IF has_table_privilege('anon', profiles_oid, 'MAINTAIN')
     OR has_table_privilege('authenticated', profiles_oid, 'MAINTAIN')
     OR has_table_privilege('service_role', profiles_oid, 'MAINTAIN')
     OR has_table_privilege('anon', symptoms_oid, 'MAINTAIN')
     OR has_table_privilege('authenticated', symptoms_oid, 'MAINTAIN')
     OR has_table_privilege('service_role', symptoms_oid, 'MAINTAIN') THEN
    RAISE EXCEPTION 'MAINTAIN remains effective for an API role on a protected table';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES (profiles_oid), (symptoms_oid)) AS t(table_oid)
    CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(role_name)
    CROSS JOIN (VALUES ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) AS p(privilege_name)
    WHERE has_table_privilege(r.role_name, t.table_oid, p.privilege_name)
  ) OR has_any_column_privilege('anon', profiles_oid, 'REFERENCES')
     OR has_any_column_privilege('authenticated', profiles_oid, 'REFERENCES')
     OR has_any_column_privilege('service_role', profiles_oid, 'REFERENCES')
     OR has_any_column_privilege('anon', symptoms_oid, 'REFERENCES')
     OR has_any_column_privilege('authenticated', symptoms_oid, 'REFERENCES')
     OR has_any_column_privilege('service_role', symptoms_oid, 'REFERENCES') THEN
    RAISE EXCEPTION 'a structural table or column privilege remains effective after migration';
  END IF;

  IF has_table_privilege('anon', profiles_oid, 'SELECT')
     OR has_table_privilege('anon', profiles_oid, 'INSERT')
     OR has_table_privilege('anon', profiles_oid, 'UPDATE')
     OR has_table_privilege('anon', profiles_oid, 'DELETE')
     OR NOT has_table_privilege('anon', symptoms_oid, 'INSERT')
     OR has_table_privilege('anon', symptoms_oid, 'SELECT')
     OR has_table_privilege('anon', symptoms_oid, 'UPDATE')
     OR has_table_privilege('anon', symptoms_oid, 'DELETE')
     OR NOT has_table_privilege('authenticated', profiles_oid, 'SELECT')
     OR NOT has_table_privilege('authenticated', profiles_oid, 'UPDATE')
     OR has_table_privilege('authenticated', profiles_oid, 'INSERT')
     OR has_table_privilege('authenticated', profiles_oid, 'DELETE')
     OR NOT has_table_privilege('authenticated', symptoms_oid, 'SELECT')
     OR NOT has_table_privilege('authenticated', symptoms_oid, 'INSERT')
     OR NOT has_table_privilege('authenticated', symptoms_oid, 'DELETE')
     OR has_table_privilege('authenticated', symptoms_oid, 'UPDATE')
     OR NOT has_table_privilege('service_role', profiles_oid, 'SELECT')
     OR NOT has_table_privilege('service_role', profiles_oid, 'INSERT')
     OR NOT has_table_privilege('service_role', profiles_oid, 'UPDATE')
     OR NOT has_table_privilege('service_role', profiles_oid, 'DELETE')
     OR NOT has_table_privilege('service_role', symptoms_oid, 'SELECT')
     OR NOT has_table_privilege('service_role', symptoms_oid, 'INSERT')
     OR NOT has_table_privilege('service_role', symptoms_oid, 'UPDATE')
     OR NOT has_table_privilege('service_role', symptoms_oid, 'DELETE') THEN
    RAISE EXCEPTION 'post-migration CRUD privilege matrix differs from the reviewed contract';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
    WHERE c.oid IN (profiles_oid, symptoms_oid)
      AND acl.grantee = 0
  ) OR EXISTS (
    SELECT 1 FROM pg_attribute AS a
    CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
    WHERE a.attrelid IN (profiles_oid, symptoms_oid)
      AND a.attnum > 0 AND NOT a.attisdropped
  ) OR EXISTS (
    SELECT 1 FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
    WHERE c.oid IN (profiles_oid, symptoms_oid)
      AND acl.grantee IN (
        (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
        (SELECT oid FROM pg_roles WHERE rolname = 'authenticated'),
        (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
      ) AND acl.is_grantable
  ) OR EXISTS (
    SELECT 1 FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
    WHERE c.oid IN (profiles_oid, symptoms_oid)
      AND acl.grantee IN (
        (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
        (SELECT oid FROM pg_roles WHERE rolname = 'authenticated'),
        (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
      ) AND acl.privilege_type = 'MAINTAIN'
  ) THEN
    RAISE EXCEPTION 'PUBLIC, column-level, or API-role grant-option ACLs remain';
  END IF;
END;
$postconditions$;

COMMIT;
