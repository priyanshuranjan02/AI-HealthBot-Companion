-- AI HealthBot: NGO verification and administrator authorization
-- LOCAL CANDIDATE ONLY — review and test before deployment.
-- Prerequisites:
--   1. Profile-role protection migration
--   2. Profile role/signup hardening migration
--   3. Privacy-preserving NGO analytics migration
--
-- Administrator privileges are separate from profiles.role.
-- The first administrator must be provisioned by a trusted operator.

BEGIN;

-- SECURITY DEFINER RPCs and tables below must be owned by postgres. Connect
-- using a direct superuser login, then SET ROLE postgres in the same session:
-- session_user proves the trusted login, while current_user determines object
-- ownership, default ACLs, and the privileges actually used by this migration.
-- Do not substitute role membership or the login identity for object ownership.
DO $runner_preflight$
DECLARE
  session_is_superuser boolean;
  postgres_oid oid;
  profiles_owner oid;
  signup_owner oid;
  role_function_owner oid;
  analytics_owner oid;
BEGIN
  SELECT r.rolsuper INTO session_is_superuser
  FROM pg_catalog.pg_roles AS r
  WHERE r.rolname = session_user::name;

  IF session_is_superuser IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'Admin/NGO migration requires a direct superuser login session';
  END IF;

  SELECT r.oid INTO postgres_oid
  FROM pg_catalog.pg_roles AS r
  WHERE r.rolname = 'postgres';

  SELECT c.relowner INTO profiles_owner
  FROM pg_catalog.pg_class AS c
  WHERE c.oid = 'public.profiles'::regclass;
  SELECT p.proowner INTO signup_owner
  FROM pg_catalog.pg_proc AS p
  WHERE p.oid = to_regprocedure('public.handle_new_user()');
  SELECT p.proowner INTO role_function_owner
  FROM pg_catalog.pg_proc AS p
  WHERE p.oid = to_regprocedure('public.prevent_profile_role_escalation()');
  SELECT p.proowner INTO analytics_owner
  FROM pg_catalog.pg_proc AS p
  WHERE p.oid = to_regprocedure('public.get_ngo_dashboard_stats()');

  IF postgres_oid IS NULL
     OR current_user <> 'postgres'
     OR profiles_owner IS DISTINCT FROM postgres_oid
     OR signup_owner IS DISTINCT FROM postgres_oid
     OR role_function_owner IS DISTINCT FROM postgres_oid
     OR analytics_owner IS DISTINCT FROM postgres_oid
     OR NOT has_schema_privilege(current_user, 'public', 'USAGE')
     OR NOT has_schema_privilege(current_user, 'public', 'CREATE') THEN
    RAISE EXCEPTION
      'Admin/NGO migration requires current_user=postgres to own public.profiles and the existing signup, role-protection, and analytics functions and have public USAGE/CREATE; no objects were created';
  END IF;
END;
$runner_preflight$;

-- ============================================================
-- 1. Administrator roles
-- ============================================================

CREATE TABLE public.user_roles (
  user_id uuid NOT NULL
    REFERENCES public.profiles(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role = 'admin'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role)
);

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- New public tables can inherit broad default ACLs, including for service_role.
-- Clear those table-specific grants before restoring the intended matrix.
REVOKE ALL PRIVILEGES ON TABLE public.user_roles
  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON TABLE public.user_roles TO service_role;


-- ============================================================
-- 2. NGO applications
-- ============================================================

CREATE TABLE public.ngo_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  applicant_user_id uuid NOT NULL
    REFERENCES public.profiles(id) ON DELETE CASCADE,

  organization_name text NOT NULL
    CHECK (char_length(trim(organization_name)) BETWEEN 2 AND 200),

  registration_identifier text NOT NULL
    CHECK (char_length(trim(registration_identifier)) BETWEEN 2 AND 160),

  official_contact_email text NOT NULL
    CHECK (
      char_length(trim(official_contact_email)) BETWEEN 3 AND 320
      AND official_contact_email ~
        '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),

  official_contact_phone text NOT NULL
    CHECK (char_length(trim(official_contact_phone)) BETWEEN 3 AND 64),

  website text
    CHECK (
      website IS NULL
      OR website = ''
      OR (
        char_length(website) <= 2048
        AND website ~* '^https?://[^[:space:]]+$'
      )
    ),

  evidence_references jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (
      jsonb_typeof(evidence_references) = 'array'
      AND jsonb_array_length(evidence_references) <= 10
    ),

  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'suspended')),

  reviewer_id uuid
    REFERENCES public.profiles(id) ON DELETE SET NULL,

  decided_at timestamptz,
  review_reason text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CHECK (
    (
      status = 'pending'
      AND reviewer_id IS NULL
      AND decided_at IS NULL
      AND review_reason IS NULL
    )
    OR (
      status = 'approved'
      AND reviewer_id IS NOT NULL
      AND decided_at IS NOT NULL
    )
    OR (
      status IN ('rejected', 'suspended')
      AND reviewer_id IS NOT NULL
      AND decided_at IS NOT NULL
      AND coalesce(length(trim(review_reason)), 0) > 0
    )
  )
);

CREATE INDEX ngo_applications_status_created_idx
  ON public.ngo_applications (status, created_at DESC);

CREATE INDEX ngo_applications_registration_idx
  ON public.ngo_applications (lower(trim(registration_identifier)));

-- One pending application per user.
-- Rejected applications may be resubmitted.
CREATE UNIQUE INDEX ngo_applications_one_pending_per_user_idx
  ON public.ngo_applications (applicant_user_id)
  WHERE status = 'pending';

ALTER TABLE public.ngo_applications ENABLE ROW LEVEL SECURITY;

-- All client access is mediated by authenticated Edge Functions.
REVOKE ALL PRIVILEGES ON TABLE public.ngo_applications
  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.ngo_applications TO service_role;


-- ============================================================
-- 3. Administrator audit log
-- ============================================================

CREATE TABLE public.admin_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  actor_id uuid NOT NULL
    REFERENCES public.profiles(id) ON DELETE RESTRICT,

  action text NOT NULL
    CHECK (
      action IN (
        'ngo_application_submitted',
        'ngo_application_approved',
        'ngo_application_rejected',
        'ngo_application_suspended'
      )
    ),

  application_id uuid
    REFERENCES public.ngo_applications(id) ON DELETE SET NULL,

  target_user_id uuid
    REFERENCES public.profiles(id) ON DELETE SET NULL,

  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX admin_audit_log_application_idx
  ON public.admin_audit_log (application_id, created_at DESC);

ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES ON TABLE public.admin_audit_log
  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, INSERT ON TABLE public.admin_audit_log TO service_role;


-- ============================================================
-- 4. Submit NGO application
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_ngo_application(
  p_applicant_user_id uuid,
  p_organization_name text,
  p_registration_identifier text,
  p_official_contact_email text,
  p_official_contact_phone text,
  p_website text,
  p_evidence_references jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  application_id uuid;
  applicant_role text;
BEGIN
  IF p_applicant_user_id IS NULL THEN
    RAISE EXCEPTION 'Applicant is required'
      USING ERRCODE = '22023';
  END IF;

  -- Only standard user accounts can apply.
  SELECT p.role
    INTO applicant_role
    FROM public.profiles AS p
    WHERE p.id = p_applicant_user_id;

  IF applicant_role IS DISTINCT FROM 'user' THEN
    RAISE EXCEPTION 'Only standard user accounts may submit NGO applications'
      USING ERRCODE = '42501';
  END IF;

  -- Validate required fields at the database boundary too.
  IF p_organization_name IS NULL
     OR char_length(trim(p_organization_name)) NOT BETWEEN 2 AND 200
     OR p_registration_identifier IS NULL
     OR char_length(trim(p_registration_identifier)) NOT BETWEEN 2 AND 160
     OR p_official_contact_email IS NULL
     OR char_length(trim(p_official_contact_email)) NOT BETWEEN 3 AND 320
     OR p_official_contact_email !~
       '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     OR p_official_contact_phone IS NULL
     OR char_length(trim(p_official_contact_phone)) NOT BETWEEN 3 AND 64
  THEN
    RAISE EXCEPTION 'Invalid NGO application details'
      USING ERRCODE = '22023';
  END IF;

  IF coalesce(p_website, '') <> ''
     AND (
       char_length(p_website) > 2048
       OR p_website !~* '^https?://[^[:space:]]+$'
     )
  THEN
    RAISE EXCEPTION 'Website must be a valid HTTP or HTTPS URL'
      USING ERRCODE = '22023';
  END IF;

  IF p_evidence_references IS NULL
     OR jsonb_typeof(p_evidence_references) <> 'array'
     OR jsonb_array_length(p_evidence_references) > 10
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_evidence_references) AS item(value)
       WHERE jsonb_typeof(item.value) <> 'string'
          OR char_length(trim(item.value #>> '{}')) NOT BETWEEN 1 AND 2048
     )
  THEN
    RAISE EXCEPTION 'Evidence references must be an array of at most 10 valid strings'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.ngo_applications (
    applicant_user_id,
    organization_name,
    registration_identifier,
    official_contact_email,
    official_contact_phone,
    website,
    evidence_references
  )
  VALUES (
    p_applicant_user_id,
    trim(p_organization_name),
    trim(p_registration_identifier),
    lower(trim(p_official_contact_email)),
    trim(p_official_contact_phone),
    nullif(trim(p_website), ''),
    p_evidence_references
  )
  RETURNING id INTO application_id;

  INSERT INTO public.admin_audit_log (
    actor_id,
    action,
    application_id,
    target_user_id,
    details
  )
  VALUES (
    p_applicant_user_id,
    'ngo_application_submitted',
    application_id,
    p_applicant_user_id,
    jsonb_build_object(
      'organization_name', trim(p_organization_name)
    )
  );

  RETURN application_id;
END;
$$;


-- ============================================================
-- 5. Review, approve, reject, or suspend NGO applications
-- ============================================================

CREATE OR REPLACE FUNCTION public.review_ngo_application(
  p_reviewer_id uuid,
  p_application_id uuid,
  p_status text,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  applicant_id uuid;
  is_admin boolean;
BEGIN
  IF p_reviewer_id IS NULL OR p_application_id IS NULL THEN
    RAISE EXCEPTION 'Reviewer and application are required'
      USING ERRCODE = '22023';
  END IF;

  IF p_status IS NULL
     OR p_status NOT IN ('approved', 'rejected', 'suspended')
  THEN
    RAISE EXCEPTION 'Invalid review status'
      USING ERRCODE = '22023';
  END IF;

  IF p_status IN ('rejected', 'suspended')
     AND coalesce(length(trim(p_reason)), 0) = 0
  THEN
    RAISE EXCEPTION 'A reason is required for rejection or suspension'
      USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NOT NULL AND char_length(p_reason) > 2000 THEN
    RAISE EXCEPTION 'Review reason is too long'
      USING ERRCODE = '22023';
  END IF;

  -- Independently verify the reviewer against the protected role table.
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles AS ur
    WHERE ur.user_id = p_reviewer_id
      AND ur.role = 'admin'
  )
  INTO is_admin;

  IF NOT is_admin THEN
    RAISE EXCEPTION 'Administrator access required'
      USING ERRCODE = '42501';
  END IF;

  -- Allowed transitions:
  -- pending  -> approved
  -- pending  -> rejected
  -- approved -> suspended
  UPDATE public.ngo_applications AS app
  SET status = p_status,
      reviewer_id = p_reviewer_id,
      decided_at = now(),
      review_reason = nullif(trim(p_reason), ''),
      updated_at = now()
  WHERE app.id = p_application_id
    AND (
      (
        app.status = 'pending'
        AND p_status IN ('approved', 'rejected')
      )
      OR (
        app.status = 'approved'
        AND p_status = 'suspended'
      )
    )
  RETURNING app.applicant_user_id INTO applicant_id;

  IF applicant_id IS NULL THEN
    RAISE EXCEPTION 'Application not found or transition is not permitted'
      USING ERRCODE = 'P0002';
  END IF;

  -- Approved NGO accounts have role 'ngo'.
  -- Rejected/suspended accounts return to role 'user'.
  UPDATE public.profiles AS p
  SET role = CASE
        WHEN p_status = 'approved' THEN 'ngo'
        ELSE 'user'
      END,
      updated_at = now()
  WHERE p.id = applicant_id;

  INSERT INTO public.admin_audit_log (
    actor_id,
    action,
    application_id,
    target_user_id,
    details
  )
  VALUES (
    p_reviewer_id,
    ('ngo_application_' || p_status),
    p_application_id,
    applicant_id,
    jsonb_build_object(
      'reason', nullif(trim(p_reason), ''),
      'status', p_status
    )
  );
END;
$$;


-- ============================================================
-- 6. Function execution permissions
-- ============================================================

REVOKE ALL ON FUNCTION public.submit_ngo_application(
  uuid, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.review_ngo_application(
  uuid, uuid, text, text
) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.submit_ngo_application(
  uuid, text, text, text, text, text, jsonb
) TO service_role;

GRANT EXECUTE ON FUNCTION public.review_ngo_application(
  uuid, uuid, text, text
) TO service_role;

-- Verify exact direct grants and effective rights after applying the
-- table-specific revokes. MAINTAIN is included for the PostgreSQL 17 target.
DO $privilege_postconditions$
DECLARE
  anon_oid oid := 'anon'::regrole::oid;
  authenticated_oid oid := 'authenticated'::regrole::oid;
  service_oid oid := 'service_role'::regrole::oid;
  postgres_oid oid := 'postgres'::regrole::oid;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS c
    WHERE c.oid IN (
      'public.user_roles'::regclass,
      'public.ngo_applications'::regclass,
      'public.admin_audit_log'::regclass
    )
      AND c.relowner <> postgres_oid
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS p
    WHERE p.oid IN (
      'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'::regprocedure,
      'public.review_ngo_application(uuid,uuid,text,text)'::regprocedure
    )
      AND p.proowner <> postgres_oid
  ) THEN
    RAISE EXCEPTION 'Admin/NGO tables and SECURITY DEFINER RPCs must be owned by postgres';
  END IF;

  IF EXISTS (
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
      AND (
        acl.grantee IN (0, anon_oid, authenticated_oid)
        OR (acl.grantee = service_oid AND acl.is_grantable)
        OR (acl.grantee = service_oid AND NOT EXISTS (
          SELECT 1
          FROM (VALUES
            ('public.user_roles'::regclass::oid, 'SELECT'::text),
            ('public.admin_audit_log'::regclass::oid, 'SELECT'::text),
            ('public.admin_audit_log'::regclass::oid, 'INSERT'::text),
            ('public.ngo_applications'::regclass::oid, 'SELECT'::text),
            ('public.ngo_applications'::regclass::oid, 'INSERT'::text),
            ('public.ngo_applications'::regclass::oid, 'UPDATE'::text),
            ('public.ngo_applications'::regclass::oid, 'DELETE'::text)
          ) AS expected(relation_oid, privilege_type)
          WHERE expected.relation_oid = c.oid
            AND expected.privilege_type = acl.privilege_type
        ))
      )
  ) THEN
    RAISE EXCEPTION
      'Admin/NGO table ACL contains an unintended PUBLIC/API grant, service_role privilege, or grant option';
  END IF;

  IF EXISTS (
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
      AND acl.grantee = service_oid
    GROUP BY c.oid, acl.privilege_type
    HAVING count(*) <> 1
  ) THEN
    RAISE EXCEPTION 'Duplicate direct service_role table ACL entries were found';
  END IF;

  IF EXISTS (
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
      ) AND acl.grantee = service_oid AND NOT acl.is_grantable
    )
    SELECT relation_oid, privilege_type FROM expected
    EXCEPT ALL
    SELECT relation_oid, privilege_type FROM actual
  ) OR EXISTS (
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
      ) AND acl.grantee = service_oid AND NOT acl.is_grantable
    )
    SELECT relation_oid, privilege_type FROM actual
    EXCEPT ALL
    SELECT relation_oid, privilege_type FROM expected
  ) THEN
    RAISE EXCEPTION 'Direct service_role grants do not exactly match the intended table matrix';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS a
    CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) AS acl
    WHERE a.attrelid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    )
      AND a.attnum > 0 AND NOT a.attisdropped
      AND acl.grantee IN (0, anon_oid, authenticated_oid, service_oid)
  ) THEN
    RAISE EXCEPTION 'Unexpected column-level ACL exists on an Admin/NGO table';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS c
    WHERE c.oid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    ) AND NOT c.relrowsecurity
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy AS p
    WHERE p.polrelid IN (
      'public.user_roles'::regclass,
      'public.admin_audit_log'::regclass,
      'public.ngo_applications'::regclass
    )
  ) THEN
    RAISE EXCEPTION 'Admin/NGO table RLS or no-client-policy contract failed';
  END IF;

  IF has_table_privilege(anon_oid, 'public.user_roles', 'SELECT')
     OR has_table_privilege(anon_oid, 'public.user_roles', 'INSERT')
     OR has_table_privilege(anon_oid, 'public.user_roles', 'UPDATE')
     OR has_table_privilege(anon_oid, 'public.user_roles', 'DELETE')
     OR has_table_privilege(anon_oid, 'public.user_roles', 'TRUNCATE')
     OR has_table_privilege(anon_oid, 'public.user_roles', 'REFERENCES')
     OR has_table_privilege(anon_oid, 'public.user_roles', 'TRIGGER')
     OR has_table_privilege(anon_oid, 'public.user_roles', 'MAINTAIN')
     OR has_table_privilege(authenticated_oid, 'public.user_roles', 'SELECT')
     OR has_table_privilege(authenticated_oid, 'public.user_roles', 'INSERT')
     OR has_table_privilege(authenticated_oid, 'public.user_roles', 'UPDATE')
     OR has_table_privilege(authenticated_oid, 'public.user_roles', 'DELETE')
     OR has_table_privilege(authenticated_oid, 'public.user_roles', 'TRUNCATE')
     OR has_table_privilege(authenticated_oid, 'public.user_roles', 'REFERENCES')
     OR has_table_privilege(authenticated_oid, 'public.user_roles', 'TRIGGER')
     OR has_table_privilege(authenticated_oid, 'public.user_roles', 'MAINTAIN')
     OR has_table_privilege(service_oid, 'public.user_roles', 'SELECT') IS DISTINCT FROM true
     OR has_table_privilege(service_oid, 'public.user_roles', 'INSERT')
     OR has_table_privilege(service_oid, 'public.user_roles', 'UPDATE')
     OR has_table_privilege(service_oid, 'public.user_roles', 'DELETE')
     OR has_table_privilege(service_oid, 'public.user_roles', 'TRUNCATE')
     OR has_table_privilege(service_oid, 'public.user_roles', 'REFERENCES')
     OR has_table_privilege(service_oid, 'public.user_roles', 'TRIGGER')
     OR has_table_privilege(service_oid, 'public.user_roles', 'MAINTAIN') THEN
    RAISE EXCEPTION 'user_roles effective privilege matrix failed';
  END IF;

  IF has_table_privilege(anon_oid, 'public.admin_audit_log', 'SELECT')
     OR has_table_privilege(anon_oid, 'public.admin_audit_log', 'INSERT')
     OR has_table_privilege(anon_oid, 'public.admin_audit_log', 'UPDATE')
     OR has_table_privilege(anon_oid, 'public.admin_audit_log', 'DELETE')
     OR has_table_privilege(anon_oid, 'public.admin_audit_log', 'TRUNCATE')
     OR has_table_privilege(anon_oid, 'public.admin_audit_log', 'REFERENCES')
     OR has_table_privilege(anon_oid, 'public.admin_audit_log', 'TRIGGER')
     OR has_table_privilege(anon_oid, 'public.admin_audit_log', 'MAINTAIN')
     OR has_table_privilege(authenticated_oid, 'public.admin_audit_log', 'SELECT')
     OR has_table_privilege(authenticated_oid, 'public.admin_audit_log', 'INSERT')
     OR has_table_privilege(authenticated_oid, 'public.admin_audit_log', 'UPDATE')
     OR has_table_privilege(authenticated_oid, 'public.admin_audit_log', 'DELETE')
     OR has_table_privilege(authenticated_oid, 'public.admin_audit_log', 'TRUNCATE')
     OR has_table_privilege(authenticated_oid, 'public.admin_audit_log', 'REFERENCES')
     OR has_table_privilege(authenticated_oid, 'public.admin_audit_log', 'TRIGGER')
     OR has_table_privilege(authenticated_oid, 'public.admin_audit_log', 'MAINTAIN')
     OR has_table_privilege(service_oid, 'public.admin_audit_log', 'SELECT') IS DISTINCT FROM true
     OR has_table_privilege(service_oid, 'public.admin_audit_log', 'INSERT') IS DISTINCT FROM true
     OR has_table_privilege(service_oid, 'public.admin_audit_log', 'UPDATE')
     OR has_table_privilege(service_oid, 'public.admin_audit_log', 'DELETE')
     OR has_table_privilege(service_oid, 'public.admin_audit_log', 'TRUNCATE')
     OR has_table_privilege(service_oid, 'public.admin_audit_log', 'REFERENCES')
     OR has_table_privilege(service_oid, 'public.admin_audit_log', 'TRIGGER')
     OR has_table_privilege(service_oid, 'public.admin_audit_log', 'MAINTAIN') THEN
    RAISE EXCEPTION 'admin_audit_log effective privilege matrix failed';
  END IF;

  IF has_table_privilege(anon_oid, 'public.ngo_applications', 'SELECT')
     OR has_table_privilege(anon_oid, 'public.ngo_applications', 'INSERT')
     OR has_table_privilege(anon_oid, 'public.ngo_applications', 'UPDATE')
     OR has_table_privilege(anon_oid, 'public.ngo_applications', 'DELETE')
     OR has_table_privilege(anon_oid, 'public.ngo_applications', 'TRUNCATE')
     OR has_table_privilege(anon_oid, 'public.ngo_applications', 'REFERENCES')
     OR has_table_privilege(anon_oid, 'public.ngo_applications', 'TRIGGER')
     OR has_table_privilege(anon_oid, 'public.ngo_applications', 'MAINTAIN')
     OR has_table_privilege(authenticated_oid, 'public.ngo_applications', 'SELECT')
     OR has_table_privilege(authenticated_oid, 'public.ngo_applications', 'INSERT')
     OR has_table_privilege(authenticated_oid, 'public.ngo_applications', 'UPDATE')
     OR has_table_privilege(authenticated_oid, 'public.ngo_applications', 'DELETE')
     OR has_table_privilege(authenticated_oid, 'public.ngo_applications', 'TRUNCATE')
     OR has_table_privilege(authenticated_oid, 'public.ngo_applications', 'REFERENCES')
     OR has_table_privilege(authenticated_oid, 'public.ngo_applications', 'TRIGGER')
     OR has_table_privilege(authenticated_oid, 'public.ngo_applications', 'MAINTAIN')
     OR has_table_privilege(service_oid, 'public.ngo_applications', 'SELECT') IS DISTINCT FROM true
     OR has_table_privilege(service_oid, 'public.ngo_applications', 'INSERT') IS DISTINCT FROM true
     OR has_table_privilege(service_oid, 'public.ngo_applications', 'UPDATE') IS DISTINCT FROM true
     OR has_table_privilege(service_oid, 'public.ngo_applications', 'DELETE') IS DISTINCT FROM true
     OR has_table_privilege(service_oid, 'public.ngo_applications', 'TRUNCATE')
     OR has_table_privilege(service_oid, 'public.ngo_applications', 'REFERENCES')
     OR has_table_privilege(service_oid, 'public.ngo_applications', 'TRIGGER')
     OR has_table_privilege(service_oid, 'public.ngo_applications', 'MAINTAIN') THEN
    RAISE EXCEPTION 'ngo_applications effective privilege matrix failed';
  END IF;

  IF has_any_column_privilege(anon_oid, 'public.user_roles', 'SELECT')
     OR has_any_column_privilege(anon_oid, 'public.user_roles', 'INSERT')
     OR has_any_column_privilege(anon_oid, 'public.user_roles', 'UPDATE')
     OR has_any_column_privilege(anon_oid, 'public.user_roles', 'REFERENCES')
     OR has_any_column_privilege(authenticated_oid, 'public.user_roles', 'SELECT')
     OR has_any_column_privilege(authenticated_oid, 'public.user_roles', 'INSERT')
     OR has_any_column_privilege(authenticated_oid, 'public.user_roles', 'UPDATE')
     OR has_any_column_privilege(authenticated_oid, 'public.user_roles', 'REFERENCES')
     OR has_any_column_privilege(service_oid, 'public.user_roles', 'INSERT')
     OR has_any_column_privilege(service_oid, 'public.user_roles', 'UPDATE')
     OR has_any_column_privilege(service_oid, 'public.user_roles', 'REFERENCES')
     OR has_any_column_privilege(anon_oid, 'public.admin_audit_log', 'SELECT')
     OR has_any_column_privilege(anon_oid, 'public.admin_audit_log', 'INSERT')
     OR has_any_column_privilege(anon_oid, 'public.admin_audit_log', 'UPDATE')
     OR has_any_column_privilege(anon_oid, 'public.admin_audit_log', 'REFERENCES')
     OR has_any_column_privilege(authenticated_oid, 'public.admin_audit_log', 'SELECT')
     OR has_any_column_privilege(authenticated_oid, 'public.admin_audit_log', 'INSERT')
     OR has_any_column_privilege(authenticated_oid, 'public.admin_audit_log', 'UPDATE')
     OR has_any_column_privilege(authenticated_oid, 'public.admin_audit_log', 'REFERENCES')
     OR has_any_column_privilege(service_oid, 'public.admin_audit_log', 'UPDATE')
     OR has_any_column_privilege(service_oid, 'public.admin_audit_log', 'REFERENCES')
     OR has_any_column_privilege(anon_oid, 'public.ngo_applications', 'SELECT')
     OR has_any_column_privilege(anon_oid, 'public.ngo_applications', 'INSERT')
     OR has_any_column_privilege(anon_oid, 'public.ngo_applications', 'UPDATE')
     OR has_any_column_privilege(anon_oid, 'public.ngo_applications', 'REFERENCES')
     OR has_any_column_privilege(authenticated_oid, 'public.ngo_applications', 'SELECT')
     OR has_any_column_privilege(authenticated_oid, 'public.ngo_applications', 'INSERT')
     OR has_any_column_privilege(authenticated_oid, 'public.ngo_applications', 'UPDATE')
     OR has_any_column_privilege(authenticated_oid, 'public.ngo_applications', 'REFERENCES')
     OR has_any_column_privilege(service_oid, 'public.ngo_applications', 'REFERENCES') THEN
    RAISE EXCEPTION 'Unexpected effective column-level privilege exists on an Admin/NGO table';
  END IF;

  IF EXISTS (
    WITH RECURSIVE api_roots(root_oid) AS (
      VALUES (anon_oid), (authenticated_oid), (service_oid)
    ), settable_roles(root_oid, role_oid, role_path) AS (
      SELECT root_oid, root_oid, ARRAY[root_oid]::oid[] FROM api_roots
      UNION ALL
      SELECT s.root_oid, m.roleid, s.role_path || m.roleid
      FROM settable_roles AS s
      JOIN pg_catalog.pg_auth_members AS m ON m.member = s.role_oid
      WHERE m.set_option AND NOT (m.roleid = ANY (s.role_path))
    ), expected(root_oid, relation_oid, privilege_name, allowed) AS (
      SELECT roots.root_oid, relations.relation_oid, privileges.privilege_name,
             roots.root_oid = service_oid AND (
               (relations.relation_oid = 'public.user_roles'::regclass::oid
                AND privileges.privilege_name = 'SELECT')
               OR (relations.relation_oid = 'public.admin_audit_log'::regclass::oid
                   AND privileges.privilege_name IN ('SELECT', 'INSERT'))
               OR (relations.relation_oid = 'public.ngo_applications'::regclass::oid
                   AND privileges.privilege_name IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE'))
             ) AS allowed
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
    FROM settable_roles AS s
    JOIN expected AS e ON e.root_oid = s.root_oid
    WHERE has_table_privilege(s.role_oid, e.relation_oid, e.privilege_name)
          IS DISTINCT FROM e.allowed
       OR (e.privilege_name IN ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
           AND e.allowed = false
           AND has_any_column_privilege(s.role_oid, e.relation_oid, e.privilege_name))
  ) THEN
    RAISE EXCEPTION 'API role SET ROLE path violates the Admin/NGO table privilege matrix';
  END IF;

  IF has_function_privilege(anon_oid, 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
     OR has_function_privilege(authenticated_oid, 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege(service_oid, 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
     OR has_function_privilege(anon_oid, 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
     OR has_function_privilege(authenticated_oid, 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
     OR NOT has_function_privilege(service_oid, 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
     OR EXISTS (
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
           acl.grantee NOT IN (p.proowner, service_oid)
           OR (acl.grantee = service_oid AND acl.is_grantable)
         )
     ) THEN
    RAISE EXCEPTION 'Admin/NGO RPC EXECUTE privileges must be limited to the function owner and non-grantable service_role';
  END IF;

  IF EXISTS (
    WITH RECURSIVE api_roots(root_oid) AS (
      VALUES (anon_oid), (authenticated_oid)
    ), settable_roles(root_oid, role_oid, role_path) AS (
      SELECT root_oid, root_oid, ARRAY[root_oid]::oid[] FROM api_roots
      UNION ALL
      SELECT s.root_oid, m.roleid, s.role_path || m.roleid
      FROM settable_roles AS s
      JOIN pg_catalog.pg_auth_members AS m ON m.member = s.role_oid
      WHERE m.set_option AND NOT (m.roleid = ANY (s.role_path))
    )
    SELECT 1
    FROM settable_roles AS s
    WHERE s.role_oid <> s.root_oid
      AND (
        has_function_privilege(s.role_oid, 'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)', 'EXECUTE')
        OR has_function_privilege(s.role_oid, 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
      )
  ) THEN
    RAISE EXCEPTION 'An API role can SET ROLE to a role that executes an Admin/NGO RPC';
  END IF;
END;
$privilege_postconditions$;

COMMIT;
