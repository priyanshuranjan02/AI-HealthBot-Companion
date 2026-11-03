-- Run after 20261019090000_admin_ngo_verification.sql in an isolated
-- PostgreSQL 17 Supabase-compatible database. The transaction is rolled back.
BEGIN;
SET LOCAL ROLE postgres;
SELECT no_plan();

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = session_user::name AND rolsuper
  )
  AND current_user = 'postgres'
  AND EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = current_user::name
  ),
  'test runs with a direct superuser login and the postgres object-owner role'
);

SELECT ok(
  has_schema_privilege(current_user, 'public', 'USAGE')
  AND has_schema_privilege(current_user, 'public', 'CREATE')
  AND NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS c
    WHERE c.oid IN (
      'public.profiles'::regclass,
      'public.symptom_checks'::regclass,
      'public.user_roles'::regclass,
      'public.ngo_applications'::regclass,
      'public.admin_audit_log'::regclass
    )
      AND c.relowner <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'postgres')
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    WHERE p.oid IN (
      'public.handle_new_user()'::regprocedure,
      'public.prevent_profile_role_escalation()'::regprocedure,
      'public.get_ngo_dashboard_stats()'::regprocedure,
      'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'::regprocedure,
      'public.review_ngo_application(uuid,uuid,text,text)'::regprocedure
    )
      AND p.proowner <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'postgres')
  ),
  'postgres owns all protected tables and security-definer functions required at this migration stage and can create in public'
);

SELECT ok(
  (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'public.user_roles'::regclass)
  AND (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'public.ngo_applications'::regclass)
  AND (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'public.admin_audit_log'::regclass)
  AND NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy
    WHERE polrelid IN (
      'public.user_roles'::regclass,
      'public.ngo_applications'::regclass,
      'public.admin_audit_log'::regclass
    )
  ),
  'Admin/NGO tables have RLS enabled and no client policies'
);

SELECT ok(
  NOT EXISTS (
    WITH expected(role_name, relation_name, privilege_name, allowed) AS (
      VALUES
        ('anon', 'public.user_roles', 'SELECT', false),
        ('anon', 'public.user_roles', 'INSERT', false),
        ('anon', 'public.user_roles', 'UPDATE', false),
        ('anon', 'public.user_roles', 'DELETE', false),
        ('anon', 'public.user_roles', 'TRUNCATE', false),
        ('anon', 'public.user_roles', 'REFERENCES', false),
        ('anon', 'public.user_roles', 'TRIGGER', false),
        ('anon', 'public.user_roles', 'MAINTAIN', false),
        ('authenticated', 'public.user_roles', 'SELECT', false),
        ('authenticated', 'public.user_roles', 'INSERT', false),
        ('authenticated', 'public.user_roles', 'UPDATE', false),
        ('authenticated', 'public.user_roles', 'DELETE', false),
        ('authenticated', 'public.user_roles', 'TRUNCATE', false),
        ('authenticated', 'public.user_roles', 'REFERENCES', false),
        ('authenticated', 'public.user_roles', 'TRIGGER', false),
        ('authenticated', 'public.user_roles', 'MAINTAIN', false),
        ('service_role', 'public.user_roles', 'SELECT', true),
        ('service_role', 'public.user_roles', 'INSERT', false),
        ('service_role', 'public.user_roles', 'UPDATE', false),
        ('service_role', 'public.user_roles', 'DELETE', false),
        ('service_role', 'public.user_roles', 'TRUNCATE', false),
        ('service_role', 'public.user_roles', 'REFERENCES', false),
        ('service_role', 'public.user_roles', 'TRIGGER', false),
        ('service_role', 'public.user_roles', 'MAINTAIN', false),
        ('anon', 'public.admin_audit_log', 'SELECT', false),
        ('anon', 'public.admin_audit_log', 'INSERT', false),
        ('anon', 'public.admin_audit_log', 'UPDATE', false),
        ('anon', 'public.admin_audit_log', 'DELETE', false),
        ('anon', 'public.admin_audit_log', 'TRUNCATE', false),
        ('anon', 'public.admin_audit_log', 'REFERENCES', false),
        ('anon', 'public.admin_audit_log', 'TRIGGER', false),
        ('anon', 'public.admin_audit_log', 'MAINTAIN', false),
        ('authenticated', 'public.admin_audit_log', 'SELECT', false),
        ('authenticated', 'public.admin_audit_log', 'INSERT', false),
        ('authenticated', 'public.admin_audit_log', 'UPDATE', false),
        ('authenticated', 'public.admin_audit_log', 'DELETE', false),
        ('authenticated', 'public.admin_audit_log', 'TRUNCATE', false),
        ('authenticated', 'public.admin_audit_log', 'REFERENCES', false),
        ('authenticated', 'public.admin_audit_log', 'TRIGGER', false),
        ('authenticated', 'public.admin_audit_log', 'MAINTAIN', false),
        ('service_role', 'public.admin_audit_log', 'SELECT', true),
        ('service_role', 'public.admin_audit_log', 'INSERT', true),
        ('service_role', 'public.admin_audit_log', 'UPDATE', false),
        ('service_role', 'public.admin_audit_log', 'DELETE', false),
        ('service_role', 'public.admin_audit_log', 'TRUNCATE', false),
        ('service_role', 'public.admin_audit_log', 'REFERENCES', false),
        ('service_role', 'public.admin_audit_log', 'TRIGGER', false),
        ('service_role', 'public.admin_audit_log', 'MAINTAIN', false),
        ('anon', 'public.ngo_applications', 'SELECT', false),
        ('anon', 'public.ngo_applications', 'INSERT', false),
        ('anon', 'public.ngo_applications', 'UPDATE', false),
        ('anon', 'public.ngo_applications', 'DELETE', false),
        ('anon', 'public.ngo_applications', 'TRUNCATE', false),
        ('anon', 'public.ngo_applications', 'REFERENCES', false),
        ('anon', 'public.ngo_applications', 'TRIGGER', false),
        ('anon', 'public.ngo_applications', 'MAINTAIN', false),
        ('authenticated', 'public.ngo_applications', 'SELECT', false),
        ('authenticated', 'public.ngo_applications', 'INSERT', false),
        ('authenticated', 'public.ngo_applications', 'UPDATE', false),
        ('authenticated', 'public.ngo_applications', 'DELETE', false),
        ('authenticated', 'public.ngo_applications', 'TRUNCATE', false),
        ('authenticated', 'public.ngo_applications', 'REFERENCES', false),
        ('authenticated', 'public.ngo_applications', 'TRIGGER', false),
        ('authenticated', 'public.ngo_applications', 'MAINTAIN', false),
        ('service_role', 'public.ngo_applications', 'SELECT', true),
        ('service_role', 'public.ngo_applications', 'INSERT', true),
        ('service_role', 'public.ngo_applications', 'UPDATE', true),
        ('service_role', 'public.ngo_applications', 'DELETE', true),
        ('service_role', 'public.ngo_applications', 'TRUNCATE', false),
        ('service_role', 'public.ngo_applications', 'REFERENCES', false),
        ('service_role', 'public.ngo_applications', 'TRIGGER', false),
        ('service_role', 'public.ngo_applications', 'MAINTAIN', false)
    )
    SELECT 1 FROM expected AS e
    WHERE has_table_privilege(e.role_name, e.relation_name, e.privilege_name)
          IS DISTINCT FROM e.allowed
  ),
  'effective table privileges match the least-privilege matrix, including PostgreSQL 17 MAINTAIN'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS c
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) AS acl
    WHERE c.oid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    )
      AND acl.grantee = 0
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS a
    CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) AS acl
    WHERE a.attrelid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    )
      AND a.attnum > 0 AND NOT a.attisdropped AND acl.grantee = 0
  ),
  'no direct PUBLIC table or column ACL remains on the protected workflow tables'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS c
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) AS acl
    WHERE c.oid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    ) AND acl.grantee = 'service_role'::regrole::oid AND acl.is_grantable
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS a
    CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) AS acl
    WHERE a.attrelid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    )
      AND a.attnum > 0 AND NOT a.attisdropped
      AND acl.grantee IN (
        0,
        'anon'::regrole::oid,
        'authenticated'::regrole::oid,
        'service_role'::regrole::oid
      )
  ),
  'service_role has no grant options and no API role has column-level workflow ACLs'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS c
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) AS acl
    WHERE c.oid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    )
      AND acl.grantee IN (
        0,
        'anon'::regrole::oid,
        'authenticated'::regrole::oid
      )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS c
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) AS acl
    WHERE c.oid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    )
      AND acl.grantee = 'service_role'::regrole::oid
      AND acl.is_grantable
  )
  AND NOT EXISTS (
    WITH expected(relation_oid, privilege_type) AS (
      VALUES
        ('public.user_roles'::regclass::oid, 'SELECT'::text),
        ('public.admin_audit_log'::regclass::oid, 'SELECT'::text),
        ('public.admin_audit_log'::regclass::oid, 'INSERT'::text),
        ('public.ngo_applications'::regclass::oid, 'SELECT'::text),
        ('public.ngo_applications'::regclass::oid, 'INSERT'::text),
        ('public.ngo_applications'::regclass::oid, 'UPDATE'::text),
        ('public.ngo_applications'::regclass::oid, 'DELETE'::text)
    ), actual(relation_oid, privilege_type) AS (
      SELECT c.oid, acl.privilege_type
      FROM pg_catalog.pg_class AS c
      CROSS JOIN LATERAL pg_catalog.aclexplode(
        COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))
      ) AS acl
      WHERE c.oid IN (
        'public.user_roles'::regclass,
        'public.admin_audit_log'::regclass,
        'public.ngo_applications'::regclass
      )
        AND acl.grantee = 'service_role'::regrole::oid
        AND NOT acl.is_grantable
    )
    SELECT relation_oid, privilege_type FROM expected
    EXCEPT ALL
    SELECT relation_oid, privilege_type FROM actual
  )
  AND NOT EXISTS (
    WITH expected(relation_oid, privilege_type) AS (
      VALUES
        ('public.user_roles'::regclass::oid, 'SELECT'::text),
        ('public.admin_audit_log'::regclass::oid, 'SELECT'::text),
        ('public.admin_audit_log'::regclass::oid, 'INSERT'::text),
        ('public.ngo_applications'::regclass::oid, 'SELECT'::text),
        ('public.ngo_applications'::regclass::oid, 'INSERT'::text),
        ('public.ngo_applications'::regclass::oid, 'UPDATE'::text),
        ('public.ngo_applications'::regclass::oid, 'DELETE'::text)
    ), actual(relation_oid, privilege_type) AS (
      SELECT c.oid, acl.privilege_type
      FROM pg_catalog.pg_class AS c
      CROSS JOIN LATERAL pg_catalog.aclexplode(
        COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))
      ) AS acl
      WHERE c.oid IN (
        'public.user_roles'::regclass,
        'public.admin_audit_log'::regclass,
        'public.ngo_applications'::regclass
      )
        AND acl.grantee = 'service_role'::regrole::oid
        AND NOT acl.is_grantable
    )
    SELECT relation_oid, privilege_type FROM actual
    EXCEPT ALL
    SELECT relation_oid, privilege_type FROM expected
  ),
  'direct table ACLs contain no PUBLIC/API grants or grant options and service_role matches the exact matrix'
);

SELECT ok(
  NOT EXISTS (
    WITH RECURSIVE api_roots(root_oid) AS (
      VALUES ('anon'::regrole::oid),
             ('authenticated'::regrole::oid),
             ('service_role'::regrole::oid)
    ), settable_roles(root_oid, role_oid, role_path) AS (
      SELECT root_oid, root_oid, ARRAY[root_oid]::oid[] FROM api_roots
      UNION ALL
      SELECT s.root_oid, m.roleid, s.role_path || m.roleid
      FROM settable_roles AS s
      JOIN pg_catalog.pg_auth_members AS m ON m.member = s.role_oid
      WHERE m.set_option AND NOT (m.roleid = ANY (s.role_path))
    ), expected(root_oid, relation_oid, privilege_name, allowed) AS (
      SELECT roots.root_oid, relations.relation_oid, privileges.privilege_name,
             roots.root_oid = 'service_role'::regrole::oid AND (
               (relations.relation_oid = 'public.user_roles'::regclass::oid
                AND privileges.privilege_name = 'SELECT')
               OR (relations.relation_oid = 'public.admin_audit_log'::regclass::oid
                   AND privileges.privilege_name IN ('SELECT', 'INSERT'))
               OR (relations.relation_oid = 'public.ngo_applications'::regclass::oid
                   AND privileges.privilege_name IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE'))
             )
      FROM api_roots AS roots
      CROSS JOIN (VALUES
        ('public.user_roles'::regclass::oid),
        ('public.admin_audit_log'::regclass::oid),
        ('public.ngo_applications'::regclass::oid)
      ) AS relations(relation_oid)
      CROSS JOIN (VALUES
        ('SELECT'::text), ('INSERT'::text), ('UPDATE'::text), ('DELETE'::text),
        ('TRUNCATE'::text), ('REFERENCES'::text), ('TRIGGER'::text), ('MAINTAIN'::text)
      ) AS privileges(privilege_name)
    )
    SELECT 1
    FROM settable_roles AS reachable
    JOIN expected ON expected.root_oid = reachable.root_oid
    WHERE has_table_privilege(reachable.role_oid, expected.relation_oid, expected.privilege_name)
          IS DISTINCT FROM expected.allowed
  ),
  'API role SET ROLE paths, including inherited privileges on each reachable role, preserve the same effective matrix'
);

SELECT ok(
  has_function_privilege('service_role', 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
    ) AS acl
    WHERE p.oid IN (
      'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'::regprocedure,
      'public.review_ngo_application(uuid,uuid,text,text)'::regprocedure
    )
      AND (
        acl.grantee = 0
        OR acl.grantee IN ('anon'::regrole::oid, 'authenticated'::regrole::oid)
        OR (acl.grantee = 'service_role'::regrole::oid AND acl.is_grantable)
        OR acl.grantee NOT IN (p.proowner, 'service_role'::regrole::oid)
      )
  ),
  'Admin/NGO RPC EXECUTE is effective only for trusted service_role and the owner, with no PUBLIC, API, or grant-option ACL'
);

SELECT * FROM finish();
ROLLBACK;
