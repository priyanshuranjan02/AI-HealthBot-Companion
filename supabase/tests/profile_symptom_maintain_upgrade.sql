-- Upgrade regression suite for 20261030151837_revoke_service_role_maintain_privilege.sql.
-- Run after the full local path through 20261028100000 and the new migration,
-- on PostgreSQL 17. This file intentionally does not include the incompatible
-- 20261029120000 Lovable-baseline migration path.
--
-- All synthetic Auth records, ACL test grants, and health rows are rolled back.
-- The existing reviewer_account_deletion.sql suite is also run because it
-- exercises the broader NGO, account-deletion, and RLS workflows.
BEGIN;

DO $runtime_preflight$
BEGIN
  IF current_setting('server_version_num')::integer < 170000 THEN
    RAISE EXCEPTION 'This upgrade suite requires PostgreSQL 17 or later';
  END IF;
  IF EXISTS (
    SELECT 1 FROM auth.users
    WHERE id IN (
      'a4c7e000-2026-4e00-8000-000000000001'::uuid,
      'a4c7e000-2026-4e00-8000-000000000002'::uuid
    )
  ) OR EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id IN (
      'a4c7e000-2026-4e00-8000-000000000001'::uuid,
      'a4c7e000-2026-4e00-8000-000000000002'::uuid
    )
  ) OR EXISTS (
    SELECT 1 FROM public.symptom_checks
    WHERE id IN (
      'a4c7e000-2026-4e00-8000-000000000011'::uuid,
      'a4c7e000-2026-4e00-8000-000000000012'::uuid,
      'a4c7e000-2026-4e00-8000-000000000013'::uuid
    )
  ) THEN
    RAISE EXCEPTION 'Synthetic upgrade-test UUID collision; choose new IDs before running';
  END IF;
END;
$runtime_preflight$;

SELECT no_plan();

SELECT ok(
  (SELECT relrowsecurity AND NOT relforcerowsecurity
   FROM pg_class WHERE oid = 'public.profiles'::regclass)
  AND (SELECT relrowsecurity AND NOT relforcerowsecurity
       FROM pg_class WHERE oid = 'public.symptom_checks'::regclass),
  'RLS remains enabled without FORCE RLS on both protected tables'
);

SELECT ok(
  (SELECT a.atttypid = 'text'::regtype AND a.attnotnull
   FROM pg_attribute AS a
   WHERE a.attrelid = 'public.profiles'::regclass
     AND a.attname = 'role' AND a.attnum > 0 AND NOT a.attisdropped)
  AND (SELECT regexp_replace(pg_get_expr(d.adbin, d.adrelid), '[[:space:]]+', '', 'g') = '''user''::text'
       FROM pg_attrdef AS d
       JOIN pg_attribute AS a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
       WHERE d.adrelid = 'public.profiles'::regclass AND a.attname = 'role')
  AND EXISTS (
    SELECT 1 FROM pg_constraint AS c
    WHERE c.conrelid = 'public.profiles'::regclass
      AND c.conname = 'profiles_role_allowed_values'
      AND c.contype = 'c' AND c.convalidated
      AND regexp_replace(lower(pg_get_constraintdef(c.oid)), '[[:space:]]+', '', 'g')
        = 'check((role=any(array[''user''::text,''ngo''::text])))'
  )
  AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE role IS NULL OR role NOT IN ('user', 'ngo')),
  'profile role type, default, NOT NULL constraint, allowed values, and existing data remain valid'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname IN ('anon', 'authenticated') AND (rolsuper OR rolbypassrls)
  )
  AND (SELECT NOT rolsuper AND rolbypassrls FROM pg_roles WHERE rolname = 'service_role'),
  'API role attributes remain within the reviewed Supabase contract'
);

SELECT ok(
  (SELECT relowner = 'postgres'::regrole FROM pg_class WHERE oid = 'public.profiles'::regclass)
  AND (SELECT relowner = 'postgres'::regrole FROM pg_class WHERE oid = 'public.symptom_checks'::regclass)
  AND NOT EXISTS (
    SELECT 1 FROM pg_auth_members AS m
    WHERE m.member IN (
      (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
      (SELECT oid FROM pg_roles WHERE rolname = 'authenticated'),
      (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
    )
  ),
  'protected table ownership and the strict no-outbound API-role membership contract remain intact'
);

SELECT ok(
  NOT EXISTS (
    WITH RECURSIVE settable_roles(api_oid, role_oid) AS (
      SELECT oid, oid FROM pg_roles WHERE rolname IN ('anon', 'authenticated', 'service_role')
      UNION
      SELECT s.api_oid, m.roleid FROM settable_roles AS s
      JOIN pg_auth_members AS m ON m.member = s.role_oid WHERE m.set_option
    )
    SELECT 1 FROM settable_roles WHERE role_oid <> api_oid
  )
  AND NOT EXISTS (
    WITH RECURSIVE inherited_roles(api_oid, role_oid) AS (
      SELECT oid, oid FROM pg_roles WHERE rolname IN ('anon', 'authenticated', 'service_role')
      UNION
      SELECT i.api_oid, m.roleid FROM inherited_roles AS i
      JOIN pg_auth_members AS m ON m.member = i.role_oid WHERE m.inherit_option
    )
    SELECT 1 FROM inherited_roles WHERE role_oid <> api_oid
  ),
  'no SET ROLE path or INHERIT path leaves anon, authenticated, or service_role'
);

-- Exact effective privilege matrix (including PostgreSQL 17 MAINTAIN).
SELECT ok(
  NOT has_table_privilege('anon', 'public.profiles', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.profiles', 'INSERT')
  AND NOT has_table_privilege('anon', 'public.profiles', 'UPDATE')
  AND NOT has_table_privilege('anon', 'public.profiles', 'DELETE')
  AND has_table_privilege('anon', 'public.symptom_checks', 'INSERT')
  AND NOT has_table_privilege('anon', 'public.symptom_checks', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.symptom_checks', 'UPDATE')
  AND NOT has_table_privilege('anon', 'public.symptom_checks', 'DELETE')
  AND has_table_privilege('authenticated', 'public.profiles', 'SELECT')
  AND has_table_privilege('authenticated', 'public.profiles', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'DELETE')
  AND has_table_privilege('authenticated', 'public.symptom_checks', 'SELECT')
  AND has_table_privilege('authenticated', 'public.symptom_checks', 'INSERT')
  AND has_table_privilege('authenticated', 'public.symptom_checks', 'DELETE')
  AND NOT has_table_privilege('authenticated', 'public.symptom_checks', 'UPDATE')
  AND has_table_privilege('service_role', 'public.profiles', 'SELECT')
  AND has_table_privilege('service_role', 'public.profiles', 'INSERT')
  AND has_table_privilege('service_role', 'public.profiles', 'UPDATE')
  AND has_table_privilege('service_role', 'public.profiles', 'DELETE')
  AND has_table_privilege('service_role', 'public.symptom_checks', 'SELECT')
  AND has_table_privilege('service_role', 'public.symptom_checks', 'INSERT')
  AND has_table_privilege('service_role', 'public.symptom_checks', 'UPDATE')
  AND has_table_privilege('service_role', 'public.symptom_checks', 'DELETE'),
  'the post-migration effective table privileges match the intended CRUD matrix'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(role_name)
    CROSS JOIN (VALUES ('public.profiles'), ('public.symptom_checks')) AS t(table_name)
    CROSS JOIN (VALUES ('TRUNCATE'), ('REFERENCES'), ('TRIGGER'), ('MAINTAIN')) AS v(privilege)
    WHERE has_table_privilege(r.role_name, t.table_name, v.privilege)
  ),
  'no API role retains TRUNCATE, REFERENCES, TRIGGER, or MAINTAIN on either table'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
    WHERE c.oid IN ('public.profiles'::regclass, 'public.symptom_checks'::regclass)
      AND (acl.grantee = 0 OR acl.is_grantable)
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_attribute AS a
    CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
    WHERE a.attrelid IN ('public.profiles'::regclass, 'public.symptom_checks'::regclass)
      AND a.attnum > 0 AND NOT a.attisdropped
  ),
  'no PUBLIC table grants, grant options, or column-level ACLs remain'
);

SELECT ok(
  NOT EXISTS (
    WITH expected(table_name, role_name, privilege_type) AS (
      VALUES
        ('profiles', 'authenticated', 'SELECT'), ('profiles', 'authenticated', 'UPDATE'),
        ('profiles', 'service_role', 'SELECT'), ('profiles', 'service_role', 'INSERT'),
        ('profiles', 'service_role', 'UPDATE'), ('profiles', 'service_role', 'DELETE'),
        ('symptom_checks', 'anon', 'INSERT'),
        ('symptom_checks', 'authenticated', 'SELECT'), ('symptom_checks', 'authenticated', 'INSERT'),
        ('symptom_checks', 'authenticated', 'DELETE'),
        ('symptom_checks', 'service_role', 'SELECT'), ('symptom_checks', 'service_role', 'INSERT'),
        ('symptom_checks', 'service_role', 'UPDATE'), ('symptom_checks', 'service_role', 'DELETE')
    ), actual AS (
      SELECT c.oid AS table_oid, c.relname, c.relowner, r.rolname,
             acl.privilege_type, acl.is_grantable, acl.grantor
      FROM pg_class AS c
      CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
      JOIN pg_roles AS r ON r.oid = acl.grantee
      WHERE c.oid IN ('public.profiles'::regclass, 'public.symptom_checks'::regclass)
        AND r.rolname IN ('anon', 'authenticated', 'service_role')
    ), bad_expected AS (
      SELECT e.table_name, e.role_name, e.privilege_type
      FROM expected AS e
      LEFT JOIN actual AS a ON a.relname = e.table_name
        AND a.rolname = e.role_name AND a.privilege_type = e.privilege_type
      GROUP BY e.table_name, e.role_name, e.privilege_type
      HAVING count(a.table_oid) <> 1
    ), bad_actual AS (
      SELECT 1 FROM actual AS a
      LEFT JOIN expected AS e ON e.table_name = a.relname
        AND e.role_name = a.rolname AND e.privilege_type = a.privilege_type
      WHERE e.table_name IS NULL OR a.is_grantable OR a.grantor <> a.relowner
    )
    SELECT 1 FROM bad_expected
    UNION ALL SELECT 1 FROM bad_actual
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_class AS c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS acl
    WHERE c.oid IN ('public.profiles'::regclass, 'public.symptom_checks'::regclass)
      AND acl.grantee IN (
        (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
        (SELECT oid FROM pg_roles WHERE rolname = 'authenticated'),
        (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
      ) AND acl.privilege_type = 'MAINTAIN'
  ),
  'direct API-role ACLs exactly match the owner-granted CRUD matrix with no duplicate entries or MAINTAIN grant'
);

SELECT ok(
  (SELECT count(*) = 2 FROM pg_policy WHERE polrelid = 'public.profiles'::regclass)
  AND (SELECT count(*) = 5 FROM pg_policy WHERE polrelid = 'public.symptom_checks'::regclass)
  AND NOT EXISTS (
    WITH expected(table_name, policy_name, command, role_name, using_expression, check_expression) AS (
      VALUES
        ('profiles', 'Users can view own profile', 'r', 'authenticated', '(uid() = id)', NULL::text),
        ('profiles', 'Users can update own profile', 'w', 'authenticated', '(uid() = id)', '(uid() = id)'),
        ('symptom_checks', 'Users can view their own symptom checks', 'r', 'authenticated', '(uid() = user_id)', NULL::text),
        ('symptom_checks', 'Users can insert their own symptom checks', 'a', 'authenticated', NULL::text, '(uid() = user_id)'),
        ('symptom_checks', 'Users can delete their own symptom checks', 'd', 'authenticated', '(uid() = user_id)', NULL::text),
        ('symptom_checks', 'Anonymous users can insert symptom checks', 'a', 'anon', NULL::text, '(user_id IS NULL)'),
        ('symptom_checks', 'Service role can read all symptom checks', 'r', 'service_role', 'true', NULL::text)
    )
    SELECT 1 FROM expected AS e
    LEFT JOIN pg_policy AS p
      ON p.polrelid = CASE e.table_name WHEN 'profiles' THEN 'public.profiles'::regclass ELSE 'public.symptom_checks'::regclass END
     AND p.polname::text = e.policy_name
    LEFT JOIN pg_roles AS r ON r.rolname = e.role_name
    WHERE p.oid IS NULL OR p.polcmd::text <> e.command
       OR p.polpermissive IS DISTINCT FROM true
       OR p.polroles IS DISTINCT FROM ARRAY[r.oid]::oid[]
       OR regexp_replace(lower(COALESCE(pg_get_expr(p.polqual, p.polrelid), '')), '[[:space:]]+', '', 'g')
          IS DISTINCT FROM regexp_replace(lower(COALESCE(e.using_expression, '')), '[[:space:]]+', '', 'g')
       OR regexp_replace(lower(COALESCE(pg_get_expr(p.polwithcheck, p.polrelid),
            CASE WHEN p.polcmd::text = 'w' THEN pg_get_expr(p.polqual, p.polrelid) END, '')),
            '[[:space:]]+', '', 'g')
          IS DISTINCT FROM regexp_replace(lower(COALESCE(e.check_expression, '')), '[[:space:]]+', '', 'g')
  ),
  'RLS policy roles, commands, permissive mode, and predicates remain unchanged'
);

SELECT ok(
  (SELECT proowner = 'postgres'::regrole AND prosecdef
          AND proconfig @> ARRAY['search_path=""']::text[]
          AND prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
   FROM pg_proc WHERE oid = 'public.handle_new_user()'::regprocedure)
  AND NOT has_function_privilege('anon', 'public.handle_new_user()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.handle_new_user()', 'EXECUTE')
  AND (SELECT proowner = 'postgres'::regrole AND NOT prosecdef
          AND proconfig @> ARRAY['search_path=""']::text[]
   FROM pg_proc WHERE oid = 'public.prevent_profile_role_escalation()'::regprocedure)
  AND (SELECT proowner = 'postgres'::regrole AND NOT prosecdef
          AND proconfig @> ARRAY['search_path=""']::text[]
   FROM pg_proc WHERE oid = 'public.prevent_untrusted_profile_insert()'::regprocedure),
  'signup and role/profile-insert guard attributes are preserved and API callers cannot execute signup directly'
);

SELECT ok(
  (SELECT count(*) = 1 FROM pg_trigger AS t
   WHERE t.tgrelid = 'auth.users'::regclass AND t.tgname = 'on_auth_user_created'
     AND t.tgfoid = 'public.handle_new_user()'::regprocedure AND t.tgtype = 5
     AND t.tgenabled IN ('O', 'A') AND t.tgqual IS NULL
     AND t.tgconstraint = 0 AND NOT t.tgdeferrable AND NOT t.tginitdeferred
     AND array_length(t.tgattr, 1) = 0 AND NOT t.tgisinternal)
  AND (SELECT count(*) = 1 FROM pg_trigger AS t
       WHERE t.tgrelid = 'public.profiles'::regclass AND t.tgname = 'prevent_profile_role_escalation'
         AND t.tgfoid = 'public.prevent_profile_role_escalation()'::regprocedure
         AND t.tgtype = 19 AND t.tgenabled IN ('O', 'A') AND t.tgqual IS NULL
         AND array_length(t.tgattr, 1) = 1
         AND (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.profiles'::regclass AND attname = 'role') = ANY(t.tgattr)
         AND NOT t.tgisinternal)
  AND (SELECT count(*) = 1 FROM pg_trigger AS t
       WHERE t.tgrelid = 'public.profiles'::regclass AND t.tgname = 'prevent_untrusted_profile_insert'
         AND t.tgfoid = 'public.prevent_untrusted_profile_insert()'::regprocedure
         AND t.tgtype = 7 AND t.tgenabled IN ('O', 'A') AND t.tgqual IS NULL
         AND array_length(t.tgattr, 1) = 0 AND NOT t.tgisinternal)
  AND (SELECT count(*) = 1 FROM pg_trigger AS t
       WHERE t.tgrelid = 'public.profiles'::regclass AND t.tgname = 'anonymize_account_audit_records_before_profile_delete'
         AND t.tgfoid = 'public.anonymize_account_audit_records()'::regprocedure
         AND t.tgtype = 11 AND t.tgenabled IN ('O', 'A') AND t.tgqual IS NULL
         AND NOT t.tgisinternal),
  'Auth signup, role protection, insert guard, and audit anonymization triggers retain exact event configuration'
);

SELECT ok(
  has_function_privilege('service_role', 'public.get_ngo_dashboard_stats()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_ngo_dashboard_stats()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.get_ngo_dashboard_stats()', 'EXECUTE')
  AND public.get_ngo_dashboard_stats() = jsonb_build_object(
    'totalChecks', NULL, 'totalUsers', NULL,
    'severityCounts', jsonb_build_object('low', NULL, 'moderate', NULL, 'high', NULL),
    'topDiagnoses', '[]'::jsonb, 'dailyChecks', '[]'::jsonb,
    'monthlyAssessments', '[]'::jsonb, 'predictionTrend', '[]'::jsonb,
    'languageDistribution', '{}'::jsonb, 'languageBreakdown', '[]'::jsonb,
    'topSymptoms', '[]'::jsonb, 'avgConfidence', NULL, 'highRiskCases', NULL,
    'privacySuppressed', true, 'minimumCohort', 10,
    'suppressedBreakdowns', jsonb_build_array('all')
  )
  AND position('symptom_checks' IN lower(pg_get_functiondef('public.get_ngo_dashboard_stats()'::regprocedure))) = 0
  AND position(' from ' IN lower(pg_get_functiondef('public.get_ngo_dashboard_stats()'::regprocedure))) = 0,
  'analytics RPC remains service-role-only and returns only the fixed suppressed JSON contract'
);

SELECT ok(
  has_function_privilege('service_role', 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND (SELECT prosecdef AND proconfig @> ARRAY['search_path=""']::text[] FROM pg_proc WHERE oid = 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'::regprocedure)
  AND (SELECT prosecdef AND proconfig @> ARRAY['search_path=""']::text[] FROM pg_proc WHERE oid = 'public.review_ngo_application(uuid,uuid,text,text)'::regprocedure),
  'NGO submission and review RPC authorization contracts remain service-role-only'
);

SELECT ok(
  EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.symptom_checks'::regclass
          AND conname = 'symptom_checks_user_id_fkey' AND confrelid = 'auth.users'::regclass AND confdeltype = 'c')
  AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.admin_audit_log'::regclass
              AND conname = 'admin_audit_log_actor_id_fkey' AND confrelid = 'public.profiles'::regclass AND confdeltype = 'n')
  AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ngo_applications'::regclass
              AND conname = 'ngo_applications_reviewer_id_fkey' AND confdeltype = 'n')
  AND has_function_privilege('postgres', 'public.anonymize_account_audit_records()', 'EXECUTE'),
  'account deletion cascades and audit/reviewer anonymization dependencies remain installed'
);

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES
  ('a4c7e000-2026-4e00-8000-000000000001', 'authenticated', 'authenticated', 'maintain-a@example.invalid', '', now(), '{}'::jsonb, '{"role":"admin","full_name":"Upgrade A"}'::jsonb, now(), now()),
  ('a4c7e000-2026-4e00-8000-000000000002', 'authenticated', 'authenticated', 'maintain-b@example.invalid', '', now(), '{}'::jsonb, '{"role":"ngo","full_name":"Upgrade B"}'::jsonb, now(), now());

SELECT ok(
  (SELECT count(*) = 2 FROM public.profiles
   WHERE id IN ('a4c7e000-2026-4e00-8000-000000000001'::uuid,
                'a4c7e000-2026-4e00-8000-000000000002'::uuid)
     AND role = 'user'),
  'Auth trigger creates default user profiles despite hostile admin/ngo metadata'
);

SELECT set_config('request.jwt.claim.sub', 'a4c7e000-2026-4e00-8000-000000000001', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SET LOCAL ROLE authenticated;
DO $authenticated_profile_behavior$
DECLARE
  visible_rows integer;
  updated_rows integer;
  error_state text;
  error_message text;
BEGIN
  SELECT count(*)::integer INTO visible_rows FROM public.profiles
  WHERE id = 'a4c7e000-2026-4e00-8000-000000000001'::uuid;
  IF visible_rows <> 1 THEN RAISE EXCEPTION 'own profile visibility precondition failed'; END IF;
  UPDATE public.profiles SET full_name = 'Upgrade own-profile edit'
  WHERE id = 'a4c7e000-2026-4e00-8000-000000000001'::uuid;
  GET DIAGNOSTICS updated_rows = ROW_COUNT;
  IF updated_rows <> 1 THEN RAISE EXCEPTION 'own profile update precondition failed'; END IF;

  BEGIN
    UPDATE public.profiles SET role = 'ngo'
    WHERE id = 'a4c7e000-2026-4e00-8000-000000000001'::uuid;
    GET DIAGNOSTICS updated_rows = ROW_COUNT;
    IF updated_rows <> 1 THEN RAISE EXCEPTION 'role update affected unexpected row count'; END IF;
    error_state := '00000'; error_message := 'role update unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS error_state = RETURNED_SQLSTATE, error_message = MESSAGE_TEXT;
  END;
  PERFORM set_config('healthbot.maintain_role_guard_result', error_state || '|' || error_message, true);
END;
$authenticated_profile_behavior$;
RESET ROLE;

SELECT is(
  current_setting('healthbot.maintain_role_guard_result', true),
  '42501|Changing account role is not permitted',
  'ordinary authenticated users cannot change their own profile role'
);
SELECT ok(
  (SELECT role = 'user' AND full_name = 'Upgrade own-profile edit'
   FROM public.profiles WHERE id = 'a4c7e000-2026-4e00-8000-000000000001'::uuid),
  'authenticated own-profile editing remains available while role remains protected'
);

SET LOCAL ROLE authenticated;
DO $direct_profile_insert$
DECLARE error_state text; error_message text;
BEGIN
  BEGIN
    INSERT INTO public.profiles (id, role)
    VALUES ('a4c7e000-2026-4e00-8000-000000000011'::uuid, 'ngo');
    error_state := '00000'; error_message := 'profile insert unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS error_state = RETURNED_SQLSTATE, error_message = MESSAGE_TEXT;
  END;
  PERFORM set_config('healthbot.maintain_direct_insert_result', error_state || '|' || error_message, true);
END;
$direct_profile_insert$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.maintain_direct_insert_result', true),
  '42501|permission denied for table profiles',
  'authenticated direct profile INSERT remains denied by the table ACL'
);

-- Temporarily bypass the table ACL only to exercise the INSERT defense trigger.
GRANT INSERT (id, role) ON TABLE public.profiles TO authenticated;
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;
DO $insert_guard$
DECLARE error_state text; error_message text;
BEGIN
  BEGIN
    INSERT INTO public.profiles (id, role)
    VALUES ('a4c7e000-2026-4e00-8000-000000000012'::uuid, 'ngo');
    error_state := '00000'; error_message := 'profile insert unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS error_state = RETURNED_SQLSTATE, error_message = MESSAGE_TEXT;
  END;
  PERFORM set_config('healthbot.maintain_insert_guard_result', error_state || '|' || error_message, true);
END;
$insert_guard$;
RESET ROLE;
REVOKE INSERT (id, role) ON TABLE public.profiles FROM authenticated;
SELECT is(
  current_setting('healthbot.maintain_insert_guard_result', true),
  '42501|Direct profile creation is not permitted',
  'profile insert guard rejects an authenticated column-grant bypass'
);

-- Exercise authenticated symptom ownership and the still-supported CRUD subset.
INSERT INTO public.symptom_checks (id, user_id, symptoms, diagnosis, confidence, severity, language)
VALUES
  ('a4c7e000-2026-4e00-8000-000000000011', 'a4c7e000-2026-4e00-8000-000000000001', ARRAY['synthetic own'], 'synthetic own', 50, 'low', 'en'),
  ('a4c7e000-2026-4e00-8000-000000000012', 'a4c7e000-2026-4e00-8000-000000000002', ARRAY['synthetic other'], 'synthetic other', 50, 'low', 'en');

SET LOCAL ROLE authenticated;
DO $authenticated_symptoms$
DECLARE own_rows integer; other_rows integer; own_insert_id uuid;
        error_state text; error_message text; deleted_rows integer;
BEGIN
  SELECT count(*)::integer INTO own_rows FROM public.symptom_checks
  WHERE id = 'a4c7e000-2026-4e00-8000-000000000011'::uuid;
  SELECT count(*)::integer INTO other_rows FROM public.symptom_checks
  WHERE id = 'a4c7e000-2026-4e00-8000-000000000012'::uuid;
  INSERT INTO public.symptom_checks (user_id, symptoms, diagnosis, confidence, severity, language)
  VALUES ('a4c7e000-2026-4e00-8000-000000000001', ARRAY['own insert'], 'own insert', 51, 'low', 'en')
  RETURNING id INTO own_insert_id;
  BEGIN
    INSERT INTO public.symptom_checks (user_id, symptoms, diagnosis, confidence, severity, language)
    VALUES ('a4c7e000-2026-4e00-8000-000000000002', ARRAY['forged'], 'forged', 51, 'low', 'en');
    error_state := '00000'; error_message := 'cross-user insert unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS error_state = RETURNED_SQLSTATE, error_message = MESSAGE_TEXT;
  END;
  DELETE FROM public.symptom_checks WHERE id = own_insert_id;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  PERFORM set_config('healthbot.maintain_symptom_result',
    own_rows::text || '|' || other_rows::text || '|' || error_state || '|' || deleted_rows::text, true);
END;
$authenticated_symptoms$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.maintain_symptom_result', true),
  '1|0|42501|1',
  'authenticated symptom SELECT/INSERT/DELETE remains owner-scoped'
);

SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '', true);
SET LOCAL ROLE anon;
DO $anonymous_symptom_insert$
DECLARE inserted_rows integer; error_state text;
BEGIN
  INSERT INTO public.symptom_checks (symptoms, diagnosis, confidence, severity, language)
  VALUES (ARRAY['anonymous synthetic'], 'anonymous synthetic', 40, 'low', 'en');
  GET DIAGNOSTICS inserted_rows = ROW_COUNT;
  BEGIN
    INSERT INTO public.symptom_checks (user_id, symptoms, diagnosis, confidence, severity, language)
    VALUES ('a4c7e000-2026-4e00-8000-000000000001', ARRAY['anonymous forged'], 'anonymous forged', 40, 'low', 'en');
    error_state := '00000';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS error_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('healthbot.maintain_anon_result', inserted_rows::text || '|' || error_state, true);
END;
$anonymous_symptom_insert$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.maintain_anon_result', true),
  '1|42501',
  'anonymous users can submit unlinked assessments but cannot attach another user ID'
);

-- service_role must retain real CRUD, not only role-based catalog answers.
DELETE FROM public.profiles WHERE id = 'a4c7e000-2026-4e00-8000-000000000002'::uuid;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SET LOCAL ROLE service_role;
DO $service_profile_crud$
DECLARE selected_rows integer; updated_rows integer; deleted_rows integer;
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES ('a4c7e000-2026-4e00-8000-000000000002'::uuid, 'service insert');
  SELECT count(*)::integer INTO selected_rows FROM public.profiles
  WHERE id = 'a4c7e000-2026-4e00-8000-000000000002'::uuid;
  UPDATE public.profiles SET full_name = 'service update'
  WHERE id = 'a4c7e000-2026-4e00-8000-000000000002'::uuid;
  GET DIAGNOSTICS updated_rows = ROW_COUNT;
  DELETE FROM public.profiles WHERE id = 'a4c7e000-2026-4e00-8000-000000000002'::uuid;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  PERFORM set_config('healthbot.maintain_service_profile_crud',
    selected_rows::text || '|' || updated_rows::text || '|' || deleted_rows::text, true);
END;
$service_profile_crud$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.maintain_service_profile_crud', true),
  '1|1|1',
  'service_role retains actual profile SELECT/INSERT/UPDATE/DELETE behavior'
);

SELECT set_config('request.jwt.claim.role', 'service_role', true);
SET LOCAL ROLE service_role;
DO $service_symptom_crud$
DECLARE selected_rows integer; updated_rows integer; deleted_rows integer;
BEGIN
  INSERT INTO public.symptom_checks (user_id, symptoms, diagnosis, confidence, severity, language)
  VALUES (NULL, ARRAY['service insert'], 'service insert', 30, 'low', 'en');
  SELECT count(*)::integer INTO selected_rows FROM public.symptom_checks
  WHERE diagnosis = 'service insert';
  UPDATE public.symptom_checks SET diagnosis = 'service update'
  WHERE diagnosis = 'service insert';
  GET DIAGNOSTICS updated_rows = ROW_COUNT;
  DELETE FROM public.symptom_checks WHERE diagnosis = 'service update';
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  PERFORM set_config('healthbot.maintain_service_symptom_crud',
    selected_rows::text || '|' || updated_rows::text || '|' || deleted_rows::text, true);
END;
$service_symptom_crud$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.maintain_service_symptom_crud', true),
  '1|1|1',
  'service_role retains actual symptom_checks SELECT/INSERT/UPDATE/DELETE behavior'
);

SELECT * FROM finish();
ROLLBACK;
