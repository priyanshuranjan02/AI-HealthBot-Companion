-- Run only with `supabase test db` against a newly created disposable local
-- Supabase instance. Synthetic users and records are rolled back at the end.
BEGIN;

SELECT no_plan();

-- Preserve the identities and reference state of already-anonymized
-- submission events (including prior disposable concurrency fixtures). The
-- applicant-deletion assertion below must never count these unrelated rows.
CREATE TEMP TABLE reviewer_preexisting_anonymized_ngo_audit AS
SELECT id, action, actor_id, application_id, target_user_id, details, anonymized_at
FROM public.admin_audit_log
WHERE action IN (
    'ngo_application_submitted',
    'ngo_application_approved',
    'ngo_application_rejected',
    'ngo_application_suspended',
    'ngo_application_reinstated'
  )
  AND anonymized_at IS NOT NULL;

SELECT diag(
  'AIHB_REVIEWER_PREEXISTING_ANON_NGO_AUDIT_BEFORE ' || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'audit_id', id,
      'action', action,
      'actor_id', actor_id,
      'application_id', application_id,
      'target_user_id', target_user_id,
      'details', details,
      'anonymized_at', anonymized_at
    ) ORDER BY id)::text
    FROM reviewer_preexisting_anonymized_ngo_audit
  ), '[]')
);

-- Assert the actual PostgreSQL RPC response, not only its source text. The
-- current contract is fail-closed: these are fixed placeholders and contain
-- no computed health-derived values. Keep this assertion aligned with the
-- migration if the response contract is intentionally changed.
SELECT is(
  public.get_ngo_dashboard_stats(),
  jsonb_build_object(
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
  ),
  'analytics RPC returns the exact fail-closed JSON contract'
);

SELECT ok(
  has_function_privilege('service_role', 'public.get_ngo_dashboard_stats()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_ngo_dashboard_stats()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.get_ngo_dashboard_stats()', 'EXECUTE')
  AND NOT EXISTS (
    SELECT 1
    FROM pg_proc AS p
    CROSS JOIN LATERAL aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) AS acl
    WHERE p.oid = 'public.get_ngo_dashboard_stats()'::regprocedure
      AND acl.grantee = 0
      AND acl.privilege_type = 'EXECUTE'
  ),
  'analytics RPC is executable by service_role only, with no PUBLIC grant'
);

SELECT ok(
  position('symptom_checks' IN lower(pg_get_functiondef(
    'public.get_ngo_dashboard_stats()'::regprocedure
  ))) = 0
  AND position(' from ' IN lower(pg_get_functiondef(
    'public.get_ngo_dashboard_stats()'::regprocedure
  ))) = 0
  AND position(' join ' IN lower(pg_get_functiondef(
    'public.get_ngo_dashboard_stats()'::regprocedure
  ))) = 0,
  'analytics RPC body does not read health tables or derive metrics from rows'
);

SELECT ok(
  (SELECT count(*) = 2 FROM pg_policy WHERE polrelid = 'public.profiles'::regclass)
  AND (SELECT count(*) = 5 FROM pg_policy WHERE polrelid = 'public.symptom_checks'::regclass)
  AND NOT EXISTS (
    WITH expected(policy_name, relation_name, command, role_name, using_expression, check_expression) AS (
      VALUES
        ('Users can view own profile', 'profiles', 'r', 'authenticated', '(uid() = id)', NULL::text),
        ('Users can update own profile', 'profiles', 'w', 'authenticated', '(uid() = id)', '(uid() = id)'),
        ('Users can view their own symptom checks', 'symptom_checks', 'r', 'authenticated', '(uid() = user_id)', NULL::text),
        ('Users can insert their own symptom checks', 'symptom_checks', 'a', 'authenticated', NULL::text, '(uid() = user_id)'),
        ('Users can delete their own symptom checks', 'symptom_checks', 'd', 'authenticated', '(uid() = user_id)', NULL::text),
        ('Anonymous users can insert symptom checks', 'symptom_checks', 'a', 'anon', NULL::text, '(user_id IS NULL)'),
        ('Service role can read all symptom checks', 'symptom_checks', 'r', 'service_role', 'true', NULL::text)
    )
    SELECT 1
    FROM expected AS e
    LEFT JOIN pg_policy AS p
      ON p.polrelid = CASE e.relation_name
        WHEN 'profiles' THEN 'public.profiles'::regclass
        ELSE 'public.symptom_checks'::regclass
      END
     AND p.polname::text = e.policy_name
    LEFT JOIN pg_roles AS r ON r.rolname::text = e.role_name
    WHERE p.oid IS NULL
       OR p.polcmd::text <> e.command
       OR p.polpermissive IS DISTINCT FROM true
       OR p.polroles IS DISTINCT FROM ARRAY[r.oid]::oid[]
       OR regexp_replace(lower(COALESCE(pg_get_expr(p.polqual, p.polrelid), '')), '[[:space:]]+', '', 'g')
          IS DISTINCT FROM regexp_replace(lower(COALESCE(e.using_expression, '')), '[[:space:]]+', '', 'g')
       OR regexp_replace(lower(COALESCE(
            pg_get_expr(p.polwithcheck, p.polrelid),
            CASE WHEN p.polcmd::text = 'w' THEN pg_get_expr(p.polqual, p.polrelid) END,
            ''
          )), '[[:space:]]+', '', 'g')
          IS DISTINCT FROM regexp_replace(lower(COALESCE(e.check_expression, '')), '[[:space:]]+', '', 'g')
  ),
  'profile and symptom RLS policy roles, commands, USING and WITH CHECK expressions match the contract'
);

SELECT ok(
  (SELECT relrowsecurity AND NOT relforcerowsecurity
   FROM pg_class WHERE oid = 'public.profiles'::regclass)
  AND (SELECT relrowsecurity AND NOT relforcerowsecurity
       FROM pg_class WHERE oid = 'public.symptom_checks'::regclass),
  'RLS is enabled and FORCE RLS remains disabled on profiles and symptom checks'
);

SELECT ok(
  (SELECT a.attnotnull
   FROM pg_attribute AS a
   WHERE a.attrelid = 'public.profiles'::regclass
     AND a.attname = 'role'
     AND NOT a.attisdropped)
  AND EXISTS (
    SELECT 1 FROM pg_constraint AS c
    WHERE c.conrelid = 'public.profiles'::regclass
      AND c.conname = 'profiles_role_allowed_values'
      AND c.contype = 'c'
      AND c.convalidated
      AND regexp_replace(lower(pg_get_constraintdef(c.oid)), '[[:space:]]+', '', 'g')
          = 'check((role=any(array[''user''::text,''ngo''::text])))'
  )
  AND (SELECT regexp_replace(pg_get_expr(d.adbin, d.adrelid), '[[:space:]]+', '', 'g')
       FROM pg_attrdef AS d
       JOIN pg_attribute AS a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
       WHERE d.adrelid = 'public.profiles'::regclass AND a.attname = 'role') = '''user''::text',
  'profile role is NOT NULL, defaults to user, and permits only user or ngo'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_trigger AS t
    JOIN pg_attribute AS a
      ON a.attrelid = t.tgrelid AND a.attname = 'role' AND NOT a.attisdropped
    JOIN pg_proc AS p ON p.oid = t.tgfoid
    WHERE t.tgrelid = 'public.profiles'::regclass
      AND t.tgname = 'prevent_profile_role_escalation'
      AND t.tgtype = 19
      AND array_length(t.tgattr, 1) = 1
      AND a.attnum = ANY(t.tgattr)
      AND t.tgenabled IN ('O', 'A')
      AND NOT t.tgisinternal
      AND p.prorettype = 'pg_catalog.trigger'::regtype
      AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
      AND NOT p.prosecdef
      AND p.proconfig = ARRAY['search_path=""']::text[]
      AND pg_get_userbyid(p.proowner) = 'postgres'
      AND regexp_replace(p.prosrc, '[[:space:]]+', '', 'g') = regexp_replace($role_body$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role
     AND current_user NOT IN ('postgres', 'service_role', 'supabase_admin')
     AND COALESCE(auth.role(), '') NOT IN ('service_role', 'supabase_admin')
  THEN
    RAISE EXCEPTION 'Changing account role is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$role_body$, '[[:space:]]+', '', 'g')
  )
  AND (SELECT count(*) = 1
       FROM pg_trigger AS t
       JOIN pg_proc AS p ON p.oid = t.tgfoid
       WHERE t.tgrelid = 'auth.users'::regclass
         AND t.tgname = 'on_auth_user_created'
         AND p.proname = 'handle_new_user'
         AND t.tgtype = 5
         AND t.tgenabled IN ('O', 'A')
         AND NOT t.tgisinternal)
  AND (SELECT count(*) = 1
       FROM pg_trigger AS t
       WHERE t.tgrelid = 'auth.users'::regclass
         AND t.tgfoid = 'public.handle_new_user()'::regprocedure
         AND t.tgtype = 5
         AND t.tgenabled IN ('O', 'A')
         AND NOT t.tgisinternal),
  'role-protection and Auth signup triggers have the expected enabled timing and row configuration'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'handle_new_user'
      AND p.pronargs = 0
      AND p.prorettype = 'pg_catalog.trigger'::regtype
      AND p.prosecdef
      AND p.proconfig = ARRAY['search_path=""']::text[]
      AND pg_get_userbyid(p.proowner) = 'postgres'
      AND (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE oid = p.proowner)
      AND regexp_replace(p.prosrc, '[[:space:]]+', '', 'g') = regexp_replace($signup_body$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$signup_body$, '[[:space:]]+', '', 'g')
  )
  AND NOT has_function_privilege('anon', 'public.handle_new_user()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.handle_new_user()', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.handle_new_user()', 'EXECUTE')
  AND EXISTS (
    SELECT 1 FROM pg_proc AS p
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
    WHERE p.oid = 'public.handle_new_user()'::regprocedure
      AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
      AND acl.privilege_type = 'EXECUTE'
      AND NOT acl.is_grantable
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_proc AS p
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
    WHERE p.oid = 'public.handle_new_user()'::regprocedure
      AND acl.grantee IN (
        0,
        (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
        (SELECT oid FROM pg_roles WHERE rolname = 'authenticated')
      )
      AND acl.privilege_type = 'EXECUTE'
  )
  AND (SELECT has_schema_privilege(p.proowner, 'public', 'USAGE')
              AND has_schema_privilege(p.proowner, 'auth', 'USAGE')
              AND has_function_privilege(p.proowner, 'auth.role()', 'EXECUTE')
              AND has_column_privilege(p.proowner, 'public.profiles', 'id', 'INSERT')
              AND has_column_privilege(p.proowner, 'public.profiles', 'full_name', 'INSERT')
       FROM pg_proc AS p WHERE p.oid = 'public.handle_new_user()'::regprocedure),
  'handle_new_user() keeps its trusted SECURITY DEFINER body, owner, search_path, and profile/Auth privileges'
);

SELECT ok(
  has_schema_privilege('anon', 'auth', 'USAGE')
  AND has_schema_privilege('authenticated', 'auth', 'USAGE')
  AND has_function_privilege('anon', 'auth.role()', 'EXECUTE')
  AND has_function_privilege('authenticated', 'auth.role()', 'EXECUTE')
  AND has_function_privilege('anon', 'public.prevent_profile_role_escalation()', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.prevent_profile_role_escalation()', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.prevent_profile_role_escalation()', 'EXECUTE')
  AND EXISTS (
    SELECT 1 FROM pg_proc AS p
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
    WHERE p.oid = 'public.prevent_profile_role_escalation()'::regprocedure
      AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE' AND NOT acl.is_grantable
  ),
  'prevent_profile_role_escalation() retains its post-October-28 PUBLIC EXECUTE ACL and API roles can use auth.role() for trigger checks'
);

CREATE TEMP TABLE healthbot_test_users (
  label text PRIMARY KEY,
  id uuid NOT NULL DEFAULT gen_random_uuid()
);

INSERT INTO healthbot_test_users (label)
VALUES
  ('reviewer'),
  ('approved-applicant'),
  ('rejected-applicant'),
  ('suspended-applicant'),
  ('cascade-applicant'),
  ('rollback-applicant'),
  ('signup-admin-metadata'),
  ('signup-ngo-metadata');

INSERT INTO auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
SELECT
  u.id,
  'authenticated',
  'authenticated',
  u.label || '@example.invalid',
  '',
  now(),
  '{}'::jsonb,
  CASE u.label
    WHEN 'signup-admin-metadata' THEN '{"role":"admin"}'::jsonb
    WHEN 'signup-ngo-metadata' THEN '{"role":"ngo"}'::jsonb
    ELSE jsonb_build_object('full_name', u.label)
  END,
  now(),
  now()
FROM healthbot_test_users AS u;

-- These direct INSERTs into auth.users exercise the database trigger only.
-- They are not Supabase Auth API signup tests (those run in
-- src/test/disposableLocalAuthSignup.integration.test.ts).
SELECT ok(
  (SELECT role = 'user' FROM public.profiles WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'signup-admin-metadata')),
  'admin signup metadata creates a user profile'
);
SELECT ok(
  (SELECT role = 'user' FROM public.profiles WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'signup-ngo-metadata')),
  'ngo signup metadata creates a user profile'
);
SELECT ok(
  (SELECT role = 'user' AND full_name = 'reviewer'
   FROM public.profiles
   WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'reviewer')),
  'ordinary Auth-trigger profile creation keeps the default role and supplied name'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.profiles', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'INSERT')
  AND NOT has_any_column_privilege('anon', 'public.profiles', 'INSERT')
  AND NOT has_any_column_privilege('authenticated', 'public.profiles', 'INSERT'),
  'API roles have no effective profile INSERT privilege'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid = 'public.profiles'::regclass
      AND polcmd IN ('a', '*')
  ),
  'profiles has no remaining INSERT or ALL policy'
);
SELECT set_config(
  'healthbot.test_profile_id',
  (SELECT id::text FROM healthbot_test_users WHERE label = 'signup-admin-metadata'),
  true
);
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT id::text FROM healthbot_test_users WHERE label = 'signup-admin-metadata'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'healthbot.test_other_profile_id',
  (SELECT id::text FROM healthbot_test_users WHERE label = 'signup-ngo-metadata'),
  true
);

-- Exercise normal own-profile edits and the role-protection trigger as an
-- ordinary authenticated database role, with synthetic JWT claims.
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  own_visible integer;
  other_visible integer;
  own_updated integer;
  other_updated integer;
  role_change_result text;
BEGIN
  SELECT count(*)::integer INTO own_visible
  FROM public.profiles
  WHERE id = current_setting('healthbot.test_profile_id')::uuid;

  SELECT count(*)::integer INTO other_visible
  FROM public.profiles
  WHERE id = current_setting('healthbot.test_other_profile_id')::uuid;

  UPDATE public.profiles
  SET full_name = 'Synthetic own-profile update'
  WHERE id = current_setting('healthbot.test_profile_id')::uuid;
  GET DIAGNOSTICS own_updated = ROW_COUNT;

  UPDATE public.profiles
  SET full_name = 'Synthetic unauthorized update'
  WHERE id = current_setting('healthbot.test_other_profile_id')::uuid;
  GET DIAGNOSTICS other_updated = ROW_COUNT;

  BEGIN
    UPDATE public.profiles
    SET role = 'ngo'
    WHERE id = current_setting('healthbot.test_profile_id')::uuid;
    role_change_result := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    role_change_result := 'denied';
  END;

  PERFORM set_config(
    'healthbot.profile_rls_result',
    own_visible::text || '|' || other_visible::text || '|' ||
      own_updated::text || '|' || other_updated::text || '|' || role_change_result,
    true
  );
END;
$$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.profile_rls_result', true),
  '1|0|1|0|denied',
  'authenticated profile SELECT/UPDATE is owner-scoped and role escalation is denied'
);
SELECT ok(
  (SELECT role = 'user' AND full_name = 'Synthetic own-profile update'
   FROM public.profiles
   WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'signup-admin-metadata')),
  'ordinary authenticated user cannot change their own role but can edit allowed profile fields'
);

SET LOCAL ROLE authenticated;
DO $$
DECLARE insert_result text;
BEGIN
  BEGIN
    INSERT INTO public.profiles (id, role)
    VALUES (current_setting('healthbot.test_profile_id')::uuid, 'ngo');
    insert_result := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    insert_result := 'denied';
  END;
  PERFORM set_config('healthbot.profile_insert_ngo_result', insert_result, true);
END;
$$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.profile_insert_ngo_result', true),
  'denied',
  'authenticated user cannot directly insert an NGO profile'
);

SET LOCAL ROLE anon;
DO $$
DECLARE insert_result text;
BEGIN
  BEGIN
    INSERT INTO public.profiles (id, role)
    VALUES (current_setting('healthbot.test_profile_id')::uuid, 'ngo');
    insert_result := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    insert_result := 'denied';
  END;
  PERFORM set_config('healthbot.profile_insert_anon_result', insert_result, true);
END;
$$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.profile_insert_anon_result', true),
  'denied',
  'anonymous user cannot directly insert an NGO profile'
);

-- Seed two synthetic health rows so the following tests exercise actual RLS
-- ownership behavior rather than only checking that policies exist.
INSERT INTO public.symptom_checks (
  id, user_id, symptoms, diagnosis, confidence, severity, language
)
SELECT
  CASE u.label
    WHEN 'signup-admin-metadata' THEN 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1'::uuid
    ELSE 'dddddddd-dddd-4ddd-8ddd-ddddddddddd2'::uuid
  END,
  u.id,
  ARRAY['synthetic symptom'],
  'Synthetic diagnosis',
  50,
  'low',
  'en'
FROM healthbot_test_users AS u
WHERE u.label IN ('signup-admin-metadata', 'signup-ngo-metadata');

SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  own_visible integer;
  other_visible integer;
  own_insert_id uuid;
  other_insert_result text;
  update_result text;
  own_deleted integer;
  other_deleted integer;
BEGIN
  SELECT count(*)::integer INTO own_visible
  FROM public.symptom_checks
  WHERE id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1'::uuid;

  SELECT count(*)::integer INTO other_visible
  FROM public.symptom_checks
  WHERE id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd2'::uuid;

  INSERT INTO public.symptom_checks (
    user_id, symptoms, diagnosis, confidence, severity, language
  ) VALUES (
    current_setting('healthbot.test_profile_id')::uuid,
    ARRAY['synthetic own symptom'], 'Synthetic own diagnosis', 60, 'moderate', 'en'
  ) RETURNING id INTO own_insert_id;

  BEGIN
    INSERT INTO public.symptom_checks (
      user_id, symptoms, diagnosis, confidence, severity, language
    ) VALUES (
      current_setting('healthbot.test_other_profile_id')::uuid,
      ARRAY['synthetic forged symptom'], 'Synthetic forged diagnosis', 60, 'moderate', 'en'
    );
    other_insert_result := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    other_insert_result := 'denied';
  END;

  BEGIN
    UPDATE public.symptom_checks
    SET diagnosis = 'Synthetic unauthorized diagnosis'
    WHERE id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1'::uuid;
    update_result := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    update_result := 'denied';
  END;

  DELETE FROM public.symptom_checks
  WHERE id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1'::uuid;
  GET DIAGNOSTICS own_deleted = ROW_COUNT;

  DELETE FROM public.symptom_checks
  WHERE id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd2'::uuid;
  GET DIAGNOSTICS other_deleted = ROW_COUNT;

  PERFORM set_config('healthbot.symptom_own_insert_id', own_insert_id::text, true);
  PERFORM set_config(
    'healthbot.symptom_rls_result',
    own_visible::text || '|' || other_visible::text || '|' ||
      other_insert_result || '|' || update_result || '|' ||
      own_deleted::text || '|' || other_deleted::text,
    true
  );
END;
$$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.symptom_rls_result', true),
  '1|0|denied|denied|1|0',
  'authenticated symptom SELECT/INSERT/DELETE is owner-scoped and UPDATE is denied'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.symptom_checks
    WHERE id = current_setting('healthbot.symptom_own_insert_id', true)::uuid
      AND user_id = (SELECT id FROM healthbot_test_users WHERE label = 'signup-admin-metadata')
  )
  AND EXISTS (
    SELECT 1 FROM public.symptom_checks
    WHERE id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd2'::uuid
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.symptom_checks
    WHERE id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1'::uuid
  ),
  'authenticated CRUD preserves own inserted row and cannot delete another user’s row'
);

SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '', true);
SET LOCAL ROLE anon;
DO $$
DECLARE
  forged_insert_result text;
BEGIN
  INSERT INTO public.symptom_checks (
    symptoms, diagnosis, confidence, severity, language
  ) VALUES (
    ARRAY['synthetic anonymous symptom'], 'Synthetic anonymous diagnosis', 40, 'low', 'en'
  );

  BEGIN
    INSERT INTO public.symptom_checks (
      user_id, symptoms, diagnosis, confidence, severity, language
    ) VALUES (
      current_setting('healthbot.test_other_profile_id')::uuid,
      ARRAY['synthetic forged anonymous symptom'], 'Synthetic forged diagnosis', 40, 'low', 'en'
    );
    forged_insert_result := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    forged_insert_result := 'denied';
  END;

  PERFORM set_config('healthbot.anonymous_forged_insert_result', forged_insert_result, true);
END;
$$;
RESET ROLE;
SELECT is(
  current_setting('healthbot.anonymous_forged_insert_result', true),
  'denied',
  'anonymous users may insert only unlinked symptom assessments'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.symptom_checks
    WHERE diagnosis = 'Synthetic anonymous diagnosis'
      AND user_id IS NULL
  ),
  'anonymous assessment INSERT remains available for user_id NULL'
);

INSERT INTO public.user_roles (user_id, role)
SELECT id, 'admin'
FROM healthbot_test_users
WHERE label = 'reviewer';

SELECT throws_ok(
  $query$
    INSERT INTO public.ngo_applications (
      applicant_user_id, organization_name, registration_identifier,
      official_contact_email, official_contact_phone, status,
      reviewer_id, decided_at, review_reason
    )
    SELECT applicant.id, 'Synthetic invalid rejection', 'TEST-INVALID-REJECTION',
      'invalid-rejection@example.invalid', '0000000000', 'rejected',
      reviewer.id, now(), '   '
    FROM healthbot_test_users AS applicant
    CROSS JOIN healthbot_test_users AS reviewer
    WHERE applicant.label = 'rejected-applicant'
      AND reviewer.label = 'reviewer'
  $query$,
  '23514',
  NULL,
  'rejected applications still require a non-empty reason'
);

SELECT throws_ok(
  $query$
    INSERT INTO public.ngo_applications (
      applicant_user_id, organization_name, registration_identifier,
      official_contact_email, official_contact_phone, reviewer_id
    )
    SELECT applicant.id, 'Synthetic invalid pending application', 'TEST-INVALID-PENDING',
      'invalid-pending@example.invalid', '0000000000', reviewer.id
    FROM healthbot_test_users AS applicant
    CROSS JOIN healthbot_test_users AS reviewer
    WHERE applicant.label = 'approved-applicant'
      AND reviewer.label = 'reviewer'
  $query$,
  '23514',
  NULL,
  'pending applications retain the no-reviewer invariant'
);

INSERT INTO public.ngo_applications (
  id,
  applicant_user_id,
  organization_name,
  registration_identifier,
  official_contact_email,
  official_contact_phone,
  status,
  reviewer_id,
  decided_at,
  review_reason
)
SELECT
  CASE applicant.label
    WHEN 'approved-applicant' THEN 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid
    WHEN 'rejected-applicant' THEN 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid
    ELSE 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'::uuid
  END,
  applicant.id,
  'Synthetic ' || applicant.label,
  'TEST-' || applicant.label,
  applicant.label || '@example.invalid',
  '0000000000',
  CASE applicant.label
    WHEN 'approved-applicant' THEN 'approved'
    WHEN 'rejected-applicant' THEN 'rejected'
    ELSE 'suspended'
  END,
  reviewer.id,
  '2026-01-02 03:04:05+00'::timestamptz,
  CASE applicant.label WHEN 'approved-applicant' THEN NULL ELSE 'Synthetic review reason' END
FROM healthbot_test_users AS applicant
CROSS JOIN healthbot_test_users AS reviewer
WHERE applicant.label IN ('approved-applicant', 'rejected-applicant', 'suspended-applicant')
  AND reviewer.label = 'reviewer';

INSERT INTO public.admin_audit_log (
  actor_id,
  action,
  application_id,
  target_user_id,
  details
)
SELECT
  reviewer.id,
  'ngo_application_' || app.status,
  app.id,
  app.applicant_user_id,
  jsonb_build_object('synthetic', true)
FROM public.ngo_applications AS app
CROSS JOIN healthbot_test_users AS reviewer
WHERE app.id IN (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'::uuid
)
  AND reviewer.label = 'reviewer';

-- Retain stable synthetic row identities for the focused assertions below.
-- Account deletion intentionally clears actor, target and application foreign
-- keys, so these test-owned audit rows cannot be identified by those fields
-- after the reviewer profile is deleted. Unrelated retained audit events from
-- other suites remain outside this assertion.
CREATE TEMP TABLE reviewer_account_review_audit_ids (
  id uuid PRIMARY KEY,
  action text NOT NULL
) ON COMMIT DROP;

INSERT INTO reviewer_account_review_audit_ids (id, action)
SELECT id, action
FROM public.admin_audit_log
WHERE application_id IN (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'::uuid
);

SELECT diag(
  'AIHB_REVIEWER_TEST_AUDIT_ROWS ' || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'audit_id', audit.id,
      'action', audit.action,
      'actor_id', audit.actor_id,
      'application_id', audit.application_id,
      'target_user_id', audit.target_user_id
    ) ORDER BY audit.action)::text
    FROM public.admin_audit_log AS audit
    JOIN reviewer_account_review_audit_ids AS owned USING (id)
  ), '[]')
);

DELETE FROM auth.users
WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'reviewer');

SELECT is(
  (SELECT status FROM public.ngo_applications WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid),
  'approved',
  'approved status remains unchanged'
);
SELECT is(
  (SELECT status FROM public.ngo_applications WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid),
  'rejected',
  'rejected status remains unchanged'
);
SELECT is(
  (SELECT status FROM public.ngo_applications WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'::uuid),
  'suspended',
  'suspended status remains unchanged'
);
SELECT is(
  (SELECT count(*)::integer FROM public.ngo_applications WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid),
  1,
  'approved application remains after reviewer deletion'
);
SELECT is(
  (SELECT count(*)::integer FROM public.ngo_applications WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid),
  1,
  'rejected application remains after reviewer deletion'
);
SELECT is(
  (SELECT count(*)::integer FROM public.ngo_applications WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'::uuid),
  1,
  'suspended application remains after reviewer deletion'
);
SELECT ok(
  (SELECT bool_and(reviewer_id IS NULL) FROM public.ngo_applications WHERE id IN (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'::uuid
  )),
  'reviewer references become null'
);
SELECT ok(
  (SELECT bool_and(decided_at = '2026-01-02 03:04:05+00'::timestamptz) FROM public.ngo_applications WHERE id IN (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'::uuid
  )),
  'decision timestamps remain unchanged'
);
SELECT is(
  (SELECT review_reason FROM public.ngo_applications WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid),
  'Synthetic review reason',
  'rejection reason remains unchanged'
);
SELECT is(
  (SELECT review_reason FROM public.ngo_applications WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'::uuid),
  'Synthetic review reason',
  'suspension reason remains unchanged'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.admin_audit_log AS audit
   JOIN reviewer_account_review_audit_ids AS owned USING (id)
   WHERE audit.action LIKE 'ngo_application_%'),
  3,
  'the three review audit events created by this test are retained'
);
SELECT ok(
  (SELECT count(*) = 3 AND bool_and(
      audit.actor_id IS NULL AND audit.target_user_id IS NULL
      AND audit.application_id IS NULL AND audit.details = '{}'::jsonb
      AND audit.anonymized_at IS NOT NULL
    )
   FROM public.admin_audit_log AS audit
   JOIN reviewer_account_review_audit_ids AS owned USING (id)),
  'the three review audit events created by this test are anonymized under the existing policy'
);

INSERT INTO public.ngo_applications (
  id,
  applicant_user_id,
  organization_name,
  registration_identifier,
  official_contact_email,
  official_contact_phone
)
SELECT
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1'::uuid,
  id,
  'Synthetic cascade applicant',
  'TEST-CASCADE',
  'cascade@example.invalid',
  '0000000000'
FROM healthbot_test_users
WHERE label = 'cascade-applicant';

INSERT INTO public.admin_audit_log (actor_id, action, application_id, target_user_id, details)
SELECT id, 'ngo_application_submitted', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1'::uuid, id, '{"synthetic":true}'::jsonb
FROM healthbot_test_users
WHERE label = 'cascade-applicant';

-- Capture this fixture's generated audit UUID while its original references
-- are still present. Later assertions join by this UUID, never by a broad
-- action/details predicate that can match retained events from other tests.
CREATE TEMP TABLE reviewer_applicant_deletion_audit_fixture (
  audit_id uuid PRIMARY KEY,
  expected_actor_id uuid NOT NULL,
  expected_application_id uuid NOT NULL,
  expected_target_user_id uuid NOT NULL,
  expected_action text NOT NULL,
  expected_details jsonb NOT NULL
) ON COMMIT DROP;

INSERT INTO reviewer_applicant_deletion_audit_fixture (
  audit_id, expected_actor_id, expected_application_id,
  expected_target_user_id, expected_action, expected_details
)
SELECT audit.id, audit.actor_id, audit.application_id,
       audit.target_user_id, audit.action, audit.details
FROM public.admin_audit_log AS audit
JOIN healthbot_test_users AS applicant ON applicant.id = audit.actor_id
WHERE applicant.label = 'cascade-applicant'
  AND audit.action = 'ngo_application_submitted'
  AND audit.application_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1'::uuid
  AND audit.target_user_id = applicant.id
  AND audit.details = '{"synthetic":true}'::jsonb;

SELECT diag(
  'AIHB_REVIEWER_APPLICANT_AUDIT_BEFORE_DELETE ' || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'audit_id', audit.id,
      'action', audit.action,
      'actor_id', audit.actor_id,
      'application_id', audit.application_id,
      'target_user_id', audit.target_user_id,
      'details', audit.details,
      'anonymized_at', audit.anonymized_at
    ) ORDER BY audit.id)::text
    FROM public.admin_audit_log AS audit
    JOIN reviewer_applicant_deletion_audit_fixture AS fixture
      ON fixture.audit_id = audit.id
  ), '[]')
);

INSERT INTO public.symptom_checks (user_id, symptoms, diagnosis, confidence, severity)
SELECT id, ARRAY['synthetic symptom'], 'Synthetic diagnosis', 50, 'low'
FROM healthbot_test_users
WHERE label = 'cascade-applicant';

DELETE FROM auth.users
WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'cascade-applicant');

SELECT is(
  (SELECT count(*)::integer FROM public.ngo_applications WHERE id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1'::uuid),
  0,
  'applicant deletion cascades its application'
);
SELECT is(
  (SELECT count(*)::integer FROM public.symptom_checks WHERE user_id = (SELECT id FROM healthbot_test_users WHERE label = 'cascade-applicant')),
  0,
  'applicant deletion cascades health assessments'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.admin_audit_log AS audit
   JOIN reviewer_applicant_deletion_audit_fixture AS fixture
     ON fixture.audit_id = audit.id
   WHERE fixture.expected_action = 'ngo_application_submitted'
     AND fixture.expected_actor_id = (
       SELECT id FROM healthbot_test_users WHERE label = 'cascade-applicant'
     )
     AND fixture.expected_application_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1'::uuid
     AND fixture.expected_target_user_id = fixture.expected_actor_id
     AND fixture.expected_details = '{"synthetic":true}'::jsonb
     AND audit.action = fixture.expected_action
     AND audit.actor_id IS NULL
     AND audit.application_id IS NULL
     AND audit.target_user_id IS NULL
     AND audit.details = '{}'::jsonb
     AND audit.anonymized_at IS NOT NULL),
  1,
  'the applicant-deletion fixture audit UUID is retained and fully anonymized'
);

SELECT diag(
  'AIHB_REVIEWER_APPLICANT_AUDIT_AFTER_DELETE ' || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'audit_id', audit.id,
      'action', audit.action,
      'actor_id', audit.actor_id,
      'application_id', audit.application_id,
      'target_user_id', audit.target_user_id,
      'details', audit.details,
      'anonymized_at', audit.anonymized_at
    ) ORDER BY audit.id)::text
    FROM public.admin_audit_log AS audit
    JOIN reviewer_applicant_deletion_audit_fixture AS fixture
      ON fixture.audit_id = audit.id
  ), '[]')
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM reviewer_preexisting_anonymized_ngo_audit AS before_row
    LEFT JOIN public.admin_audit_log AS after_row ON after_row.id = before_row.id
    WHERE after_row.id IS NULL
       OR ROW(after_row.action, after_row.actor_id, after_row.application_id,
              after_row.target_user_id, after_row.details, after_row.anonymized_at)
          IS DISTINCT FROM
          ROW(before_row.action, before_row.actor_id, before_row.application_id,
              before_row.target_user_id, before_row.details, before_row.anonymized_at)
  ),
  'preexisting anonymized NGO submission/review audit events remain present and unchanged'
);

SELECT diag(
  'AIHB_REVIEWER_PREEXISTING_ANON_NGO_AUDIT_AFTER ' || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'audit_id', audit.id,
      'action', audit.action,
      'actor_id', audit.actor_id,
      'application_id', audit.application_id,
      'target_user_id', audit.target_user_id,
      'details', audit.details,
      'anonymized_at', audit.anonymized_at
    ) ORDER BY audit.id)::text
    FROM public.admin_audit_log AS audit
    JOIN reviewer_preexisting_anonymized_ngo_audit AS before_row
      ON before_row.id = audit.id
  ), '[]')
);

CREATE TABLE public.healthbot_test_delete_blocker (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT
);
INSERT INTO public.healthbot_test_delete_blocker
SELECT id FROM healthbot_test_users WHERE label = 'rollback-applicant';

INSERT INTO public.ngo_applications (
  id,
  applicant_user_id,
  organization_name,
  registration_identifier,
  official_contact_email,
  official_contact_phone
)
SELECT
  'cccccccc-cccc-4ccc-8ccc-ccccccccccc1'::uuid,
  id,
  'Synthetic rollback applicant',
  'TEST-ROLLBACK',
  'rollback@example.invalid',
  '0000000000'
FROM healthbot_test_users
WHERE label = 'rollback-applicant';

INSERT INTO public.admin_audit_log (actor_id, action, application_id, target_user_id, details)
SELECT id, 'ngo_application_submitted', 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1'::uuid, id, '{"synthetic":true}'::jsonb
FROM healthbot_test_users
WHERE label = 'rollback-applicant';

SELECT throws_ok(
  format('DELETE FROM auth.users WHERE id = %L', (SELECT id FROM healthbot_test_users WHERE label = 'rollback-applicant')),
  '23503',
  NULL,
  'restrictive foreign key rejects Auth deletion'
);
SELECT ok(
  (SELECT EXISTS (SELECT 1 FROM auth.users WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'rollback-applicant'))
   AND EXISTS (SELECT 1 FROM public.profiles WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'rollback-applicant'))
   AND EXISTS (SELECT 1 FROM public.ngo_applications WHERE id = 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1'::uuid)
   AND EXISTS (SELECT 1 FROM public.admin_audit_log WHERE application_id = 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1'::uuid AND details = '{"synthetic":true}'::jsonb AND anonymized_at IS NULL)),
  'failed Auth deletion rolls back profile, application, and audit changes'
);

DELETE FROM public.healthbot_test_delete_blocker;
DELETE FROM auth.users
WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'rollback-applicant');
SELECT ok(
  NOT EXISTS (SELECT 1 FROM auth.users WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'rollback-applicant'))
  AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = (SELECT id FROM healthbot_test_users WHERE label = 'rollback-applicant'))
  AND NOT EXISTS (SELECT 1 FROM public.ngo_applications WHERE id = 'cccccccc-cccc-4ccc-8ccc-ccccccccccc1'::uuid)
  AND EXISTS (SELECT 1 FROM public.admin_audit_log WHERE action = 'ngo_application_submitted' AND application_id IS NULL AND target_user_id IS NULL AND actor_id IS NULL AND details = '{}'::jsonb AND anonymized_at IS NOT NULL),
  'deletion retry succeeds after removing the blocker'
);
DROP TABLE public.healthbot_test_delete_blocker;

SELECT ok(
  NOT has_table_privilege('anon', 'public.user_roles', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.user_roles', 'INSERT'),
  'ordinary roles cannot grant administrator roles'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.user_roles', 'DELETE')
  AND NOT has_table_privilege('authenticated', 'public.user_roles', 'DELETE'),
  'ordinary roles cannot revoke administrator roles'
);
SELECT ok(
  NOT has_function_privilege('anon', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE'),
  'ordinary roles cannot execute the privileged review RPC'
);


-- Stage 5J security regression assertions: least-privilege table ACLs.
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(
      COALESCE(c.relacl, acldefault('r', c.relowner))
    ) AS acl
    WHERE n.nspname = 'public'
      AND c.relname IN ('profiles', 'symptom_checks')
      AND acl.grantee = 0
  ),
  'PUBLIC has no direct table privileges on profiles or symptom checks'
);

SELECT ok(
  NOT EXISTS (
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
        0,
        (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
        (SELECT oid FROM pg_roles WHERE rolname = 'authenticated')
      )
  ),
  'PUBLIC, anon, and authenticated have no column-level ACL entries'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.profiles', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.profiles', 'INSERT')
  AND NOT has_table_privilege('anon', 'public.profiles', 'UPDATE')
  AND NOT has_table_privilege('anon', 'public.profiles', 'DELETE')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'DELETE')
  AND has_table_privilege('authenticated', 'public.profiles', 'SELECT')
  AND has_table_privilege('authenticated', 'public.profiles', 'UPDATE'),
  'profiles grants match the authenticated own-profile SELECT/UPDATE contract'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.symptom_checks', 'SELECT')
  AND has_table_privilege('anon', 'public.symptom_checks', 'INSERT')
  AND NOT has_table_privilege('anon', 'public.symptom_checks', 'UPDATE')
  AND NOT has_table_privilege('anon', 'public.symptom_checks', 'DELETE')
  AND has_table_privilege('authenticated', 'public.symptom_checks', 'SELECT')
  AND has_table_privilege('authenticated', 'public.symptom_checks', 'INSERT')
  AND has_table_privilege('authenticated', 'public.symptom_checks', 'DELETE')
  AND NOT has_table_privilege('authenticated', 'public.symptom_checks', 'UPDATE'),
  'symptom_checks grants match anonymous INSERT and authenticated SELECT/INSERT/DELETE'
);

SELECT ok(
  has_table_privilege('service_role', 'public.profiles', 'SELECT')
  AND has_table_privilege('service_role', 'public.profiles', 'INSERT')
  AND has_table_privilege('service_role', 'public.profiles', 'UPDATE')
  AND has_table_privilege('service_role', 'public.profiles', 'DELETE')
  AND has_table_privilege('service_role', 'public.symptom_checks', 'SELECT')
  AND has_table_privilege('service_role', 'public.symptom_checks', 'INSERT')
  AND has_table_privilege('service_role', 'public.symptom_checks', 'UPDATE')
  AND has_table_privilege('service_role', 'public.symptom_checks', 'DELETE')
  AND NOT has_table_privilege('service_role', 'public.profiles', 'TRUNCATE')
  AND NOT has_table_privilege('service_role', 'public.profiles', 'REFERENCES')
  AND NOT has_table_privilege('service_role', 'public.profiles', 'TRIGGER')
  AND NOT has_table_privilege('service_role', 'public.symptom_checks', 'TRUNCATE')
  AND NOT has_table_privilege('service_role', 'public.symptom_checks', 'REFERENCES')
  AND NOT has_table_privilege('service_role', 'public.symptom_checks', 'TRIGGER')
  AND CASE WHEN current_setting('server_version_num')::integer >= 170000
    THEN NOT has_table_privilege('service_role', 'public.profiles', 'MAINTAIN')
      AND NOT has_table_privilege('service_role', 'public.symptom_checks', 'MAINTAIN')
    ELSE true
  END
  AND NOT has_any_column_privilege('service_role', 'public.profiles', 'REFERENCES')
  AND NOT has_any_column_privilege('service_role', 'public.symptom_checks', 'REFERENCES'),
  'service_role retains CRUD while structural table privileges are removed'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_attribute AS a
    CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
    WHERE a.attrelid IN (
      'public.profiles'::regclass,
      'public.symptom_checks'::regclass
    )
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND acl.grantee IN (
        0,
        (SELECT oid FROM pg_roles WHERE rolname = 'anon'),
        (SELECT oid FROM pg_roles WHERE rolname = 'authenticated'),
        (SELECT oid FROM pg_roles WHERE rolname = 'service_role')
      )
  ),
  'no PUBLIC, API-role, or service-role column ACLs remain on protected tables'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.profiles', 'TRUNCATE')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'TRUNCATE')
  AND NOT has_table_privilege('anon', 'public.symptom_checks', 'TRUNCATE')
  AND NOT has_table_privilege('authenticated', 'public.symptom_checks', 'TRUNCATE'),
  'API roles cannot TRUNCATE profiles or symptom checks'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.profiles', 'REFERENCES')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'REFERENCES')
  AND NOT has_table_privilege('anon', 'public.symptom_checks', 'REFERENCES')
  AND NOT has_table_privilege('authenticated', 'public.symptom_checks', 'REFERENCES'),
  'API roles cannot add foreign-key references to profiles or symptom checks'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.profiles', 'TRIGGER')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'TRIGGER')
  AND NOT has_table_privilege('anon', 'public.symptom_checks', 'TRIGGER')
  AND NOT has_table_privilege('authenticated', 'public.symptom_checks', 'TRIGGER'),
  'API roles cannot create triggers on profiles or symptom checks'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.profiles', 'DELETE')
  AND NOT has_table_privilege('authenticated', 'public.profiles', 'DELETE'),
  'API roles have no direct DELETE grant on profiles'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.symptom_checks', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.symptom_checks', 'UPDATE'),
  'API roles have no direct UPDATE grant on symptom checks'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.profiles', 'UPDATE')
  AND has_table_privilege('authenticated', 'public.profiles', 'UPDATE'),
  'only authenticated users have the direct profile UPDATE grant'
);

SELECT * FROM finish();
ROLLBACK;
