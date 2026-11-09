-- Run only after 20261107120000_admin_ngo_reinstatement.sql in a fresh,
-- disposable PostgreSQL 17 Supabase-compatible database. All fixture rows roll back.
BEGIN;
SELECT no_plan();

CREATE TEMP TABLE reinstatement_test_users (
  label text PRIMARY KEY,
  user_id uuid NOT NULL DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL DEFAULT gen_random_uuid()
) ON COMMIT DROP;

INSERT INTO reinstatement_test_users (label)
VALUES ('administrator'), ('standard-reviewer'), ('successful-applicant'),
       ('self-reinstatement-administrator'), ('pending-applicant'),
       ('older-application-applicant'), ('concurrent-applicant'), ('role-mismatch-applicant');

DO $collision_guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = session_user::name AND rolsuper
  ) THEN
    RAISE EXCEPTION 'Membership-path regression requires a direct superuser test session';
  END IF;

  IF EXISTS (
    SELECT 1 FROM reinstatement_test_users AS ids
    WHERE EXISTS (SELECT 1 FROM auth.users AS u WHERE u.id = ids.user_id)
       OR EXISTS (SELECT 1 FROM public.profiles AS p WHERE p.id = ids.user_id)
       OR EXISTS (SELECT 1 FROM public.user_roles AS r WHERE r.user_id = ids.user_id)
       OR EXISTS (SELECT 1 FROM public.ngo_applications AS a WHERE a.id = ids.application_id)
       OR EXISTS (SELECT 1 FROM public.admin_audit_log AS l WHERE l.actor_id = ids.user_id OR l.target_user_id = ids.user_id)
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = 'aihb_reinstate_rpc_bridge_test'
  ) OR (SELECT count(DISTINCT user_id) FROM reinstatement_test_users) <> 8
     OR (SELECT count(DISTINCT application_id) FROM reinstatement_test_users) <> 8
  THEN RAISE EXCEPTION 'Synthetic reinstatement identifiers collide with existing fixture rows'; END IF;
END;
$collision_guard$;

-- This synthetic graph models authenticated -> SET ROLE bridge -> inherited
-- service_role. The membership changes and roles are rolled back with this
-- test's transaction; no production or persistent fixture membership changes.
CREATE ROLE aihb_reinstate_rpc_bridge_test NOLOGIN INHERIT;
GRANT service_role TO aihb_reinstate_rpc_bridge_test
  WITH INHERIT TRUE, SET FALSE;
GRANT aihb_reinstate_rpc_bridge_test TO authenticated
  WITH INHERIT FALSE, SET TRUE;

-- Test-only copy of the migration's exact API SET ROLE traversal. It accepts
-- the expected guard message so both the transactional preflight and the
-- independent postcondition failure contract can be asserted with pgTAP.
CREATE FUNCTION pg_temp.assert_reinstatement_api_execute_boundary(p_message text)
RETURNS void
LANGUAGE plpgsql
AS $test_guard$
DECLARE
  function_oid oid := pg_catalog.to_regprocedure(
    'public.reinstate_ngo_application(uuid,uuid,text)'
  );
BEGIN
  IF function_oid IS NULL THEN
    RAISE EXCEPTION 'Reinstatement RPC is missing in membership-path test';
  END IF;

  IF EXISTS (
    WITH RECURSIVE api_roots(root_oid) AS (
      VALUES ('anon'::regrole::oid), ('authenticated'::regrole::oid)
    ), settable_roles(root_oid, role_oid, role_path) AS (
      SELECT root_oid, root_oid, ARRAY[root_oid]::oid[] FROM api_roots
      UNION ALL
      SELECT s.root_oid, m.roleid, s.role_path || m.roleid
      FROM settable_roles AS s
      JOIN pg_catalog.pg_auth_members AS m ON m.member = s.role_oid
      WHERE m.set_option AND NOT (m.roleid = ANY(s.role_path))
    )
    SELECT 1
    FROM settable_roles AS s
    WHERE s.role_oid <> s.root_oid
      AND pg_catalog.has_function_privilege(
        s.role_oid, function_oid, 'EXECUTE'
      )
  ) THEN
    RAISE EXCEPTION '%', p_message;
  END IF;
END;
$test_guard$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
SELECT user_id, 'authenticated', 'authenticated', label || '@example.invalid', '', now(),
       '{}'::jsonb, jsonb_build_object('full_name', label), now(), now()
FROM reinstatement_test_users;

INSERT INTO public.user_roles (user_id, role)
SELECT user_id, 'admin' FROM reinstatement_test_users
WHERE label IN ('administrator', 'self-reinstatement-administrator');

INSERT INTO public.ngo_applications (
  id, applicant_user_id, organization_name, registration_identifier,
  official_contact_email, official_contact_phone, website,
  evidence_references, status, reviewer_id, decided_at, review_reason, created_at
)
SELECT application_id, user_id, 'Synthetic ' || label, 'REINSTATE-' || label,
       label || '@example.invalid', '+10000000000', '', '[]'::jsonb,
       'suspended',
       CASE WHEN label = 'self-reinstatement-administrator' THEN user_id
            ELSE (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator') END,
       now(), 'Original suspension reason', now() - interval '2 days'
FROM reinstatement_test_users
WHERE label IN ('successful-applicant', 'self-reinstatement-administrator',
                'older-application-applicant', 'concurrent-applicant', 'role-mismatch-applicant');

UPDATE public.profiles
SET role = 'ngo'
WHERE id = (SELECT user_id FROM reinstatement_test_users WHERE label = 'role-mismatch-applicant');

INSERT INTO public.ngo_applications (
  id, applicant_user_id, organization_name, registration_identifier,
  official_contact_email, official_contact_phone, website, evidence_references, status, created_at
)
SELECT application_id, user_id, 'Synthetic pending applicant', 'REINSTATE-pending-applicant',
       'pending-applicant@example.invalid', '+10000000000', '', '[]'::jsonb, 'pending', now()
FROM reinstatement_test_users WHERE label = 'pending-applicant';

-- A newer pending application makes the older suspended application ineligible.
INSERT INTO public.ngo_applications (
  applicant_user_id, organization_name, registration_identifier,
  official_contact_email, official_contact_phone, website, evidence_references,
  status, created_at
)
SELECT user_id, 'Synthetic newer application', 'REINSTATE-older-newer',
       'older-newer@example.invalid', '+10000000000', '', '[]'::jsonb,
       'pending', now() - interval '1 day'
FROM reinstatement_test_users WHERE label = 'older-application-applicant';

INSERT INTO public.admin_audit_log (actor_id, action, application_id, target_user_id, details)
SELECT (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
       'ngo_application_suspended', application_id, user_id,
       jsonb_build_object('reason', 'Original suspension reason', 'from_status', 'approved', 'to_status', 'suspended')
FROM reinstatement_test_users WHERE label = 'successful-applicant';

SELECT lives_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'successful-applicant'),
    'Verified corrective actions completed'),
  'an administrator may reinstate a suspended applicant with a reason'
);

SELECT ok(
  (SELECT status = 'approved'
          AND reviewer_id = (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator')
          AND decided_at IS NOT NULL AND review_reason IS NULL
   FROM public.ngo_applications
   WHERE id = (SELECT application_id FROM reinstatement_test_users WHERE label = 'successful-applicant'))
  AND (SELECT role = 'ngo' FROM public.profiles
       WHERE id = (SELECT user_id FROM reinstatement_test_users WHERE label = 'successful-applicant')),
  'successful reinstatement approves the latest application and restores the NGO profile role'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.admin_audit_log
          WHERE action = 'ngo_application_suspended'
            AND application_id = (SELECT application_id FROM reinstatement_test_users WHERE label = 'successful-applicant')
            AND details->>'reason' = 'Original suspension reason')
  AND EXISTS (SELECT 1 FROM public.admin_audit_log
              WHERE action = 'ngo_application_reinstated'
                AND actor_id = (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator')
                AND target_user_id = (SELECT user_id FROM reinstatement_test_users WHERE label = 'successful-applicant')
                AND application_id = (SELECT application_id FROM reinstatement_test_users WHERE label = 'successful-applicant')
                AND details->>'reason' = 'Verified corrective actions completed'
                AND details->>'from_status' = 'suspended'
                AND details->>'to_status' = 'approved')
  AND (SELECT count(*) = 2 FROM public.admin_audit_log
       WHERE application_id = (SELECT application_id FROM reinstatement_test_users WHERE label = 'successful-applicant')),
  'reinstatement adds a distinct audit reason and preserves the original suspension audit event'
);

SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, NULL)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'self-reinstatement-administrator')),
  '22023', 'Reviewer, application, and reinstatement reason are required', 'a missing reason is rejected'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'self-reinstatement-administrator'), '   '),
  '22023', 'A nonblank reinstatement reason is required', 'a blank reason is rejected'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'self-reinstatement-administrator'), repeat('x', 2001)),
  '22023', 'Reinstatement reason exceeds 2,000 characters', 'a reason longer than 2,000 characters is rejected'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'standard-reviewer'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'self-reinstatement-administrator'), 'Attempt'),
  '42501', 'Administrator access required', 'a non-administrator cannot reinstate an application'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'self-reinstatement-administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'self-reinstatement-administrator'), 'Attempt'),
  '42501', 'Administrators cannot reinstate their own NGO application', 'an administrator cannot reinstate their own application'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'pending-applicant'), 'Attempt'),
  'P0002', 'Application not found or not eligible for reinstatement', 'a non-suspended application cannot be reinstated'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'older-application-applicant'), 'Attempt'),
  'P0002', 'Application not found or not eligible for reinstatement',
  'an older suspended application cannot be reinstated when a newer application exists'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'role-mismatch-applicant'), 'Attempt'),
  'P0002', 'Application not found or not eligible for reinstatement',
  'an applicant whose profile role is not user cannot be reinstated'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(NULL, %L, %L)',
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'successful-applicant'), 'Attempt'),
  '22023', 'Reviewer, application, and reinstatement reason are required',
  'a null reviewer is rejected'
);
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, NULL, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'), 'Attempt'),
  '22023', 'Reviewer, application, and reinstatement reason are required',
  'a null application is rejected'
);

-- The opt-in disposable integration test submits two concurrent API RPC calls;
-- this SQL assertion covers the serialized retry outcome without claiming to
-- create simultaneous sessions inside pgTAP.
SELECT throws_ok(
  format('SELECT public.reinstate_ngo_application(%L, %L, %L)',
    (SELECT user_id FROM reinstatement_test_users WHERE label = 'administrator'),
    (SELECT application_id FROM reinstatement_test_users WHERE label = 'successful-applicant'), 'Concurrent retry'),
  'P0002', 'Application not found or not eligible for reinstatement',
  'a repeated attempt cannot repeat an already completed transition'
);

SELECT ok(
  (SELECT status = 'suspended' FROM public.ngo_applications
   WHERE id = (SELECT application_id FROM reinstatement_test_users WHERE label = 'self-reinstatement-administrator'))
  AND (SELECT status = 'pending' FROM public.ngo_applications
       WHERE id = (SELECT application_id FROM reinstatement_test_users WHERE label = 'pending-applicant'))
  AND NOT EXISTS (
    SELECT 1 FROM public.admin_audit_log
    WHERE application_id IN (
      SELECT application_id FROM reinstatement_test_users
      WHERE label IN ('self-reinstatement-administrator', 'pending-applicant', 'older-application-applicant', 'role-mismatch-applicant')
    ) AND action = 'ngo_application_reinstated'
  ),
  'rejected attempts leave application state and reinstatement audit history unchanged'
);

SELECT ok(
  (SELECT p.proowner = 'postgres'::regrole::oid AND p.prosecdef
          AND l.lanname = 'plpgsql' AND p.proconfig = ARRAY['search_path=""']::text[]
   FROM pg_catalog.pg_proc AS p JOIN pg_catalog.pg_language AS l ON l.oid = p.prolang
   WHERE p.oid = to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)'))
  AND NOT has_function_privilege('anon', 'public.reinstate_ngo_application(uuid,uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.reinstate_ngo_application(uuid,uuid,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.reinstate_ngo_application(uuid,uuid,text)', 'EXECUTE')
  AND (SELECT count(*) = 1
       FROM pg_catalog.pg_proc AS p CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) AS acl
       WHERE p.oid = to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)')
         AND acl.grantee = 'service_role'::regrole::oid AND acl.grantor = p.proowner
         AND acl.privilege_type = 'EXECUTE' AND NOT acl.is_grantable)
  AND NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))) AS acl
    WHERE p.oid = to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)')
      AND acl.grantee <> p.proowner AND acl.grantee <> 'service_role'::regrole::oid
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))) AS acl
    WHERE p.oid = to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)')
      AND acl.grantee = 'service_role'::regrole::oid
      AND (acl.privilege_type <> 'EXECUTE' OR acl.grantor <> p.proowner OR acl.is_grantable)
  ),
  'RPC owner, PL/pgSQL SECURITY DEFINER attributes, empty search_path, and exact service_role-only EXECUTE ACL match the contract'
);
SELECT ok(
  EXISTS (SELECT 1 FROM pg_catalog.pg_constraint AS c
          WHERE c.conrelid = 'public.admin_audit_log'::regclass
            AND c.conname = 'admin_audit_log_action_check' AND c.convalidated
            AND pg_catalog.pg_get_constraintdef(c.oid) LIKE '%ngo_application_reinstated%')
  AND EXISTS (SELECT 1 FROM public.admin_audit_log WHERE action = 'ngo_application_reinstated'),
  'validated audit action constraint admits and records reinstatement events'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_catalog.pg_auth_members AS m
    WHERE m.member = 'authenticated'::regrole::oid
      AND m.roleid = 'aihb_reinstate_rpc_bridge_test'::regrole::oid
      AND m.set_option AND NOT m.inherit_option AND NOT m.admin_option
  )
  AND EXISTS (
    SELECT 1 FROM pg_catalog.pg_auth_members AS m
    WHERE m.member = 'aihb_reinstate_rpc_bridge_test'::regrole::oid
      AND m.roleid = 'service_role'::regrole::oid
      AND m.inherit_option AND NOT m.set_option AND NOT m.admin_option
  )
  AND pg_catalog.has_function_privilege(
    'aihb_reinstate_rpc_bridge_test',
    'public.reinstate_ngo_application(uuid,uuid,text)',
    'EXECUTE'
  )
  AND NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.reinstate_ngo_application(uuid,uuid,text)',
    'EXECUTE'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members AS m
    WHERE m.member = 'authenticated'::regrole::oid
      AND m.roleid = 'service_role'::regrole::oid
      AND m.set_option
  ),
  'synthetic intermediate role is SET-reachable from authenticated and inherits RPC EXECUTE from service_role'
);

SELECT throws_ok(
  'SELECT pg_temp.assert_reinstatement_api_execute_boundary(' ||
    quote_literal('An API role can SET ROLE to a role that executes the reinstatement RPC') || ')',
  'P0001',
  'An API role can SET ROLE to a role that executes the reinstatement RPC',
  'the effective-privilege preflight predicate rejects the intermediate inherited EXECUTE path'
);

SELECT throws_ok(
  'SELECT pg_temp.assert_reinstatement_api_execute_boundary(' ||
    quote_literal('Reinstatement RPC EXECUTE privileges do not match the exact service_role-only contract') || ')',
  'P0001',
  'Reinstatement RPC EXECUTE privileges do not match the exact service_role-only contract',
  'the postcondition predicate detects the same unsafe path introduced after migration'
);

REVOKE aihb_reinstate_rpc_bridge_test FROM authenticated;
REVOKE service_role FROM aihb_reinstate_rpc_bridge_test;
DROP ROLE aihb_reinstate_rpc_bridge_test;

SELECT ok(
  (
    SELECT count(*) = 3
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_language AS l ON l.oid = p.prolang
    WHERE p.oid IN (
      'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'::regprocedure,
      'public.review_ngo_application(uuid,uuid,text,text)'::regprocedure,
      'public.reinstate_ngo_application(uuid,uuid,text)'::regprocedure
    )
      AND p.proowner = 'postgres'::regrole
      AND l.lanname = 'plpgsql'
      AND p.prosecdef
      AND p.proconfig = ARRAY['search_path=""']::text[]
      AND p.prosrc LIKE '%transaction_isolation%'
      AND p.prosrc LIKE '%FOR UPDATE%'
  )
  AND has_function_privilege(
    'service_role',
    'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)',
    'EXECUTE'
  )
  AND has_function_privilege(
    'service_role',
    'public.review_ngo_application(uuid,uuid,text,text)',
    'EXECUTE'
  )
  AND has_function_privilege(
    'service_role',
    'public.reinstate_ngo_application(uuid,uuid,text)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.review_ngo_application(uuid,uuid,text,text)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.reinstate_ngo_application(uuid,uuid,text)',
    'EXECUTE'
  ),
  'submission, review, and reinstatement use the reviewed security-definer and READ COMMITTED lock contract without broadening RPC execution'
);

SELECT * FROM finish();
ROLLBACK;
