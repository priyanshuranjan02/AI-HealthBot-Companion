-- Add an audited, administrator-only transition from suspended to approved.
-- Forward-only migration; do not edit or replay earlier NGO workflow migrations.

BEGIN;

DO $reinstatement_preflight$
DECLARE
  postgres_oid oid;
  action_attnum smallint;
  action_constraint_oid oid;
  action_constraint_definition text;
BEGIN
  SELECT r.oid INTO postgres_oid
  FROM pg_catalog.pg_roles AS r
  WHERE r.rolname = 'postgres';

  IF session_user <> 'postgres' OR current_user <> 'postgres'
     OR postgres_oid IS NULL
     OR NOT has_schema_privilege(current_user, 'public', 'USAGE')
     OR NOT has_schema_privilege(current_user, 'public', 'CREATE') THEN
    RAISE EXCEPTION
      'Reinstatement migration requires the postgres session and effective role with public USAGE and CREATE';
  END IF;

  IF to_regclass('public.profiles') IS NULL
     OR to_regclass('public.user_roles') IS NULL
     OR to_regclass('public.ngo_applications') IS NULL
     OR to_regclass('public.admin_audit_log') IS NULL THEN
    RAISE EXCEPTION 'Required Admin/NGO tables are missing; refusing reinstatement migration';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS c
    WHERE c.oid IN (
      'public.profiles'::regclass,
      'public.user_roles'::regclass,
      'public.ngo_applications'::regclass,
      'public.admin_audit_log'::regclass
    )
      AND c.relowner IS DISTINCT FROM postgres_oid
  ) THEN
    RAISE EXCEPTION 'Reinstatement migration requires postgres ownership of all workflow tables';
  END IF;

  IF to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Reinstatement RPC already exists; refusing to replace an unreviewed implementation';
  END IF;

  SELECT a.attnum INTO action_attnum
  FROM pg_catalog.pg_attribute AS a
  WHERE a.attrelid = 'public.admin_audit_log'::regclass
    AND a.attname = 'action'
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.atttypid = 'text'::regtype;

  SELECT c.oid, pg_catalog.pg_get_constraintdef(c.oid)
  INTO action_constraint_oid, action_constraint_definition
  FROM pg_catalog.pg_constraint AS c
  WHERE c.conrelid = 'public.admin_audit_log'::regclass
    AND c.conname = 'admin_audit_log_action_check'
    AND c.contype = 'c'
    AND c.convalidated
    AND c.conkey = ARRAY[action_attnum]::smallint[];

  IF action_attnum IS NULL OR action_constraint_oid IS NULL
     OR action_constraint_definition IS DISTINCT FROM
       'CHECK ((action = ANY (ARRAY[' ||
       '''ngo_application_submitted''::text, ' ||
       '''ngo_application_approved''::text, ' ||
       '''ngo_application_rejected''::text, ' ||
       '''ngo_application_suspended''::text])))' THEN
    RAISE EXCEPTION
      'admin_audit_log_action_check differs from the verified four-action baseline; refusing to replace it';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.admin_audit_log AS l
    WHERE l.action NOT IN (
      'ngo_application_submitted',
      'ngo_application_approved',
      'ngo_application_rejected',
      'ngo_application_suspended'
    )
  ) THEN
    RAISE EXCEPTION 'admin_audit_log contains an unexpected action; refusing reinstatement migration';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'service_role')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'anon')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
    RAISE EXCEPTION 'Required Supabase API roles are missing';
  END IF;

  -- The RPC does not exist yet, so EXECUTE reachability cannot be evaluated
  -- accurately in this baseline block. The exact effective-privilege
  -- preflight runs after the function's final ACL is staged below and before
  -- COMMIT; any unsafe path rolls back the whole migration transaction.
END;
$reinstatement_preflight$;

-- Fail closed rather than replacing an unexpected workflow implementation.
-- The source fingerprints are for the submit RPC from 20261019090000 and the
-- self-review-protected review RPC from 20261101120000. CREATE OR REPLACE
-- retains their owner and ACL; this migration changes only their lock order.
DO $workflow_lock_preflight$
DECLARE
  submit_oid oid := pg_catalog.to_regprocedure(
    'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'
  );
  review_oid oid := pg_catalog.to_regprocedure(
    'public.review_ngo_application(uuid,uuid,text,text)'
  );
  postgres_oid oid := 'postgres'::regrole::oid;
  service_role_oid oid := 'service_role'::regrole::oid;
BEGIN
  IF submit_oid IS NULL OR review_oid IS NULL THEN
    RAISE EXCEPTION 'Required NGO submission/review RPC is missing; refusing lock-order correction';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_language AS l ON l.oid = p.prolang
    WHERE p.oid = submit_oid
      AND p.proowner = postgres_oid
      AND l.lanname = 'plpgsql'
      AND p.prosecdef
      AND p.proconfig = ARRAY['search_path=""']::text[]
      AND pg_catalog.md5(p.prosrc) = 'e398c933d3d13d61d3ac2c0595b478a6'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_language AS l ON l.oid = p.prolang
    WHERE p.oid = review_oid
      AND p.proowner = postgres_oid
      AND l.lanname = 'plpgsql'
      AND p.prosecdef
      AND p.proconfig = ARRAY['search_path=""']::text[]
      AND pg_catalog.md5(p.prosrc) = '372488ffd2325aa067c1fbd06d3ec726'
  ) THEN
    RAISE EXCEPTION 'NGO submission/review RPC source or security attributes differ from the reviewed baseline';
  END IF;

  IF has_function_privilege('anon', submit_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', submit_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', submit_oid, 'EXECUTE')
     OR has_function_privilege('anon', review_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', review_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', review_oid, 'EXECUTE')
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_proc AS p
       CROSS JOIN LATERAL pg_catalog.aclexplode(
         COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
       ) AS acl
       WHERE p.oid IN (submit_oid, review_oid)
         AND (
           acl.grantee NOT IN (p.proowner, service_role_oid)
           OR (acl.grantee = service_role_oid
               AND (acl.privilege_type <> 'EXECUTE'
                    OR acl.grantor <> p.proowner
                    OR acl.is_grantable))
         )
     ) OR (
       SELECT count(*)
       FROM pg_catalog.pg_proc AS p
       CROSS JOIN LATERAL pg_catalog.aclexplode(
         COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
       ) AS acl
       WHERE p.oid IN (submit_oid, review_oid)
         AND acl.grantee = service_role_oid
         AND acl.privilege_type = 'EXECUTE'
         AND acl.grantor = p.proowner
         AND NOT acl.is_grantable
     ) <> 2 THEN
    RAISE EXCEPTION 'NGO submission/review RPC EXECUTE ACL differs from the service_role-only contract';
  END IF;
END;
$workflow_lock_preflight$;

-- All three applicant workflows serialize on profiles before they lock or
-- insert application rows. READ COMMITTED is required so statements issued
-- after a lock wait take a fresh snapshot and see a winning submission.
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
AS $function$
DECLARE
  application_id uuid;
  applicant_role text;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'NGO application submission requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  IF p_applicant_user_id IS NULL THEN
    RAISE EXCEPTION 'Applicant is required'
      USING ERRCODE = '22023';
  END IF;

  -- This row lock is shared with review/reinstatement. Re-read the role from
  -- the row returned after any lock wait before applying eligibility rules.
  SELECT p.role
    INTO applicant_role
    FROM public.profiles AS p
    WHERE p.id = p_applicant_user_id
    FOR UPDATE;

  IF applicant_role IS DISTINCT FROM 'user' THEN
    RAISE EXCEPTION 'Only standard user accounts may submit NGO applications'
      USING ERRCODE = '42501';
  END IF;

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
     AND (char_length(p_website) > 2048
          OR p_website !~* '^https?://[^[:space:]]+$') THEN
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
     ) THEN
    RAISE EXCEPTION 'Evidence references must be an array of at most 10 valid strings'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.ngo_applications (
    applicant_user_id, organization_name, registration_identifier,
    official_contact_email, official_contact_phone, website, evidence_references
  ) VALUES (
    p_applicant_user_id, trim(p_organization_name), trim(p_registration_identifier),
    lower(trim(p_official_contact_email)), trim(p_official_contact_phone),
    nullif(trim(p_website), ''), p_evidence_references
  ) RETURNING id INTO application_id;

  INSERT INTO public.admin_audit_log (
    actor_id, action, application_id, target_user_id, details
  ) VALUES (
    p_applicant_user_id, 'ngo_application_submitted', application_id,
    p_applicant_user_id,
    pg_catalog.jsonb_build_object('organization_name', trim(p_organization_name))
  );

  RETURN application_id;
END;
$function$;

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
AS $function$
DECLARE
  applicant_id uuid;
  locked_applicant_id uuid;
  locked_profile_id uuid;
  is_admin boolean;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'NGO application review requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  IF p_reviewer_id IS NULL OR p_application_id IS NULL THEN
    RAISE EXCEPTION 'Reviewer and application are required'
      USING ERRCODE = '22023';
  END IF;

  IF p_status IS NULL OR p_status NOT IN ('approved', 'rejected', 'suspended') THEN
    RAISE EXCEPTION 'Invalid review status'
      USING ERRCODE = '22023';
  END IF;

  IF p_status IN ('rejected', 'suspended')
     AND coalesce(length(trim(p_reason)), 0) = 0 THEN
    RAISE EXCEPTION 'A reason is required for rejection or suspension'
      USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NOT NULL AND char_length(p_reason) > 2000 THEN
    RAISE EXCEPTION 'Review reason is too long'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.user_roles AS ur
    WHERE ur.user_id = p_reviewer_id AND ur.role = 'admin'
  ) INTO is_admin;

  IF NOT is_admin THEN
    RAISE EXCEPTION 'Administrator access required'
      USING ERRCODE = '42501';
  END IF;

  -- First read the applicant without locking the application. Then acquire
  -- the shared profile lock before taking the application lock.
  SELECT app.applicant_user_id INTO applicant_id
  FROM public.ngo_applications AS app
  WHERE app.id = p_application_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application not found or transition is not permitted'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT p.id INTO locked_profile_id
  FROM public.profiles AS p
  WHERE p.id = applicant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application applicant profile is missing'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT app.applicant_user_id INTO locked_applicant_id
  FROM public.ngo_applications AS app
  WHERE app.id = p_application_id
  FOR UPDATE;

  IF NOT FOUND OR locked_applicant_id IS DISTINCT FROM applicant_id THEN
    RAISE EXCEPTION 'Application applicant changed while acquiring workflow locks'
      USING ERRCODE = 'P0002';
  END IF;

  IF applicant_id = p_reviewer_id THEN
    RAISE EXCEPTION 'Administrators cannot review their own NGO application'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.ngo_applications AS app
  SET status = p_status,
      reviewer_id = p_reviewer_id,
      decided_at = pg_catalog.now(),
      review_reason = nullif(trim(p_reason), ''),
      updated_at = pg_catalog.now()
  WHERE app.id = p_application_id
    AND app.applicant_user_id = applicant_id
    AND ((app.status = 'pending' AND p_status IN ('approved', 'rejected'))
         OR (app.status = 'approved' AND p_status = 'suspended'))
  RETURNING app.applicant_user_id INTO locked_applicant_id;

  IF locked_applicant_id IS DISTINCT FROM applicant_id THEN
    RAISE EXCEPTION 'Application not found or transition is not permitted'
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.profiles AS p
  SET role = CASE WHEN p_status = 'approved' THEN 'ngo' ELSE 'user' END,
      updated_at = pg_catalog.now()
  WHERE p.id = applicant_id;

  INSERT INTO public.admin_audit_log (
    actor_id, action, application_id, target_user_id, details
  ) VALUES (
    p_reviewer_id, 'ngo_application_' || p_status, p_application_id,
    applicant_id,
    pg_catalog.jsonb_build_object('reason', nullif(trim(p_reason), ''), 'status', p_status)
  );
END;
$function$;

ALTER TABLE public.admin_audit_log
  DROP CONSTRAINT admin_audit_log_action_check;

ALTER TABLE public.admin_audit_log
  ADD CONSTRAINT admin_audit_log_action_check CHECK (
    action IN (
      'ngo_application_submitted',
      'ngo_application_approved',
      'ngo_application_rejected',
      'ngo_application_suspended',
      'ngo_application_reinstated'
    )
  );

CREATE FUNCTION public.reinstate_ngo_application(
  p_reviewer_id uuid,
  p_application_id uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  reviewer_is_admin boolean;
  applicant_id uuid;
  locked_applicant_id uuid;
  application_status text;
  latest_application_id uuid;
  applicant_profile_role text;
  normalized_reason text;
  updated_rows integer;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'NGO application reinstatement requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  IF p_reviewer_id IS NULL OR p_application_id IS NULL OR p_reason IS NULL THEN
    RAISE EXCEPTION 'Reviewer, application, and reinstatement reason are required'
      USING ERRCODE = '22023';
  END IF;

  IF p_reason ~ '^[[:space:]]*$' THEN
    RAISE EXCEPTION 'A nonblank reinstatement reason is required'
      USING ERRCODE = '22023';
  END IF;

  IF char_length(p_reason) > 2000 THEN
    RAISE EXCEPTION 'Reinstatement reason exceeds 2,000 characters'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles AS ur
    WHERE ur.user_id = p_reviewer_id
      AND ur.role = 'admin'
  ) INTO reviewer_is_admin;

  IF NOT reviewer_is_admin THEN
    RAISE EXCEPTION 'Administrator access required'
      USING ERRCODE = '42501';
  END IF;

  -- The applicant id is immutable through the supported RPCs. Read it first
  -- without locking the application, then serialize on the applicant profile.
  SELECT app.applicant_user_id
  INTO applicant_id
  FROM public.ngo_applications AS app
  WHERE app.id = p_application_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application not found or not eligible for reinstatement'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT p.role INTO applicant_profile_role
  FROM public.profiles AS p
  WHERE p.id = applicant_id
  FOR UPDATE;

  IF NOT FOUND OR applicant_profile_role IS DISTINCT FROM 'user' THEN
    RAISE EXCEPTION 'Application not found or not eligible for reinstatement'
      USING ERRCODE = 'P0002';
  END IF;

  -- Re-read and lock the target after the shared profile lock. This both
  -- validates that its applicant did not change and follows one lock order.
  SELECT app.applicant_user_id, app.status
  INTO locked_applicant_id, application_status
  FROM public.ngo_applications AS app
  WHERE app.id = p_application_id
  FOR UPDATE;

  IF NOT FOUND
     OR locked_applicant_id IS DISTINCT FROM applicant_id
     OR application_status IS DISTINCT FROM 'suspended' THEN
    RAISE EXCEPTION 'Application not found or not eligible for reinstatement'
      USING ERRCODE = 'P0002';
  END IF;

  -- This query runs after acquiring the profile lock. Under the required
  -- READ COMMITTED isolation it sees a submission that won the lock first.
  SELECT app.id INTO latest_application_id
  FROM public.ngo_applications AS app
  WHERE app.applicant_user_id = applicant_id
  ORDER BY app.created_at DESC, app.id DESC
  LIMIT 1;

  IF latest_application_id IS DISTINCT FROM p_application_id THEN
    RAISE EXCEPTION 'Application not found or not eligible for reinstatement'
      USING ERRCODE = 'P0002';
  END IF;

  IF applicant_id = p_reviewer_id THEN
    RAISE EXCEPTION 'Administrators cannot reinstate their own NGO application'
      USING ERRCODE = '42501';
  END IF;

  normalized_reason := regexp_replace(p_reason, '^[[:space:]]+|[[:space:]]+$', '', 'g');

  UPDATE public.ngo_applications AS app
  SET status = 'approved',
      reviewer_id = p_reviewer_id,
      decided_at = pg_catalog.now(),
      review_reason = NULL,
      updated_at = pg_catalog.now()
  WHERE app.id = p_application_id
    AND app.status = 'suspended';
  GET DIAGNOSTICS updated_rows = ROW_COUNT;

  IF updated_rows <> 1 THEN
    RAISE EXCEPTION 'Application not found or not eligible for reinstatement'
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.profiles AS p
  SET role = 'ngo',
      updated_at = pg_catalog.now()
  WHERE p.id = applicant_id
    AND p.role = 'user';
  GET DIAGNOSTICS updated_rows = ROW_COUNT;

  IF updated_rows <> 1 THEN
    RAISE EXCEPTION 'Applicant profile is not eligible for reinstatement'
      USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.admin_audit_log (
    actor_id,
    action,
    application_id,
    target_user_id,
    details
  ) VALUES (
    p_reviewer_id,
    'ngo_application_reinstated',
    p_application_id,
    applicant_id,
    pg_catalog.jsonb_build_object(
      'reason', normalized_reason,
      'from_status', 'suspended',
      'to_status', 'approved'
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.reinstate_ngo_application(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;

-- Clear any additional role grants inherited from the migration runner's
-- default function ACL. The owner retains its inherent owner privileges.
DO $function_acl_cleanup$
DECLARE
  function_oid oid := 'public.reinstate_ngo_application(uuid,uuid,text)'::regprocedure;
  function_owner oid;
  service_role_oid oid := 'service_role'::regrole::oid;
  entry record;
  grantee_name name;
BEGIN
  SELECT p.proowner INTO function_owner
  FROM pg_catalog.pg_proc AS p WHERE p.oid = function_oid;

  FOR entry IN
    SELECT DISTINCT acl.grantee
    FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
    ) AS acl
    WHERE p.oid = function_oid
      AND acl.grantee <> function_owner
      AND acl.grantee <> service_role_oid
  LOOP
    IF entry.grantee = 0 THEN
      EXECUTE 'REVOKE ALL ON FUNCTION public.reinstate_ngo_application(uuid, uuid, text) FROM PUBLIC';
    ELSE
      SELECT r.rolname INTO grantee_name
      FROM pg_catalog.pg_roles AS r
      WHERE r.oid = entry.grantee;
      IF grantee_name IS NULL THEN
        RAISE EXCEPTION 'Cannot resolve an unexpected function ACL grantee; aborting';
      END IF;
      EXECUTE format(
        'REVOKE ALL ON FUNCTION public.reinstate_ngo_application(uuid, uuid, text) FROM %I',
        grantee_name
      );
    END IF;
  END LOOP;
END;
$function_acl_cleanup$;

GRANT EXECUTE ON FUNCTION public.reinstate_ngo_application(uuid, uuid, text)
  TO service_role;

-- The RPC now exists with its final ACL, so test the actual effective
-- privilege of every API-reachable SET ROLE target before this transaction
-- can commit. Any unsafe membership path rolls back the entire migration.
DO $api_execution_preflight$
DECLARE
  function_oid oid := to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)');
BEGIN
  IF function_oid IS NULL OR EXISTS (
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
    RAISE EXCEPTION 'An API role can SET ROLE to a role that executes the reinstatement RPC';
  END IF;
END;
$api_execution_preflight$;

DO $reinstatement_postconditions$
DECLARE
  function_oid oid := to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)');
  postgres_oid oid := 'postgres'::regrole::oid;
  service_role_oid oid := 'service_role'::regrole::oid;
  action_attnum smallint;
  action_constraint_definition text;
BEGIN
  SELECT a.attnum INTO action_attnum
  FROM pg_catalog.pg_attribute AS a
  WHERE a.attrelid = 'public.admin_audit_log'::regclass
    AND a.attname = 'action' AND a.attnum > 0 AND NOT a.attisdropped;

  SELECT pg_catalog.pg_get_constraintdef(c.oid)
  INTO action_constraint_definition
  FROM pg_catalog.pg_constraint AS c
  WHERE c.conrelid = 'public.admin_audit_log'::regclass
    AND c.conname = 'admin_audit_log_action_check'
    AND c.contype = 'c' AND c.convalidated
    AND c.conkey = ARRAY[action_attnum]::smallint[];

  IF current_user <> 'postgres'
     OR (SELECT p.proowner FROM pg_catalog.pg_proc AS p WHERE p.oid = function_oid) IS DISTINCT FROM postgres_oid
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_proc AS p
       JOIN pg_catalog.pg_language AS l ON l.oid = p.prolang
       WHERE p.oid = function_oid
         AND p.prorettype = 'pg_catalog.void'::regtype
         AND l.lanname = 'plpgsql'
         AND p.prosecdef
         AND p.proconfig = ARRAY['search_path=""']::text[]
     ) THEN
    RAISE EXCEPTION 'Reinstatement RPC owner or security attributes do not match the contract';
  END IF;

  IF action_constraint_definition IS DISTINCT FROM
       'CHECK ((action = ANY (ARRAY[' ||
       '''ngo_application_submitted''::text, ' ||
       '''ngo_application_approved''::text, ' ||
       '''ngo_application_rejected''::text, ' ||
       '''ngo_application_suspended''::text, ' ||
       '''ngo_application_reinstated''::text])))' THEN
    RAISE EXCEPTION 'Audit action constraint does not contain exactly the approved five actions';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
    ) AS acl
    WHERE p.oid = function_oid
      AND acl.grantee <> p.proowner
      AND acl.grantee <> service_role_oid
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
    ) AS acl
    WHERE p.oid = function_oid
      AND acl.grantee = service_role_oid
      AND (acl.privilege_type <> 'EXECUTE' OR acl.grantor <> p.proowner OR acl.is_grantable)
  ) OR (
    SELECT count(*)
    FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) AS acl
    WHERE p.oid = function_oid
      AND acl.grantee = service_role_oid
      AND acl.privilege_type = 'EXECUTE'
      AND acl.grantor = p.proowner
      AND NOT acl.is_grantable
  ) <> 1 OR has_function_privilege('anon', function_oid, 'EXECUTE')
    OR has_function_privilege('authenticated', function_oid, 'EXECUTE')
    OR NOT has_function_privilege('service_role', function_oid, 'EXECUTE')
    OR EXISTS (
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
    RAISE EXCEPTION 'Reinstatement RPC EXECUTE privileges do not match the exact service_role-only contract';
  END IF;
END;
$reinstatement_postconditions$;

DO $workflow_lock_postconditions$
DECLARE
  postgres_oid oid := 'postgres'::regrole::oid;
  service_role_oid oid := 'service_role'::regrole::oid;
  workflow_oids oid[] := ARRAY[
    pg_catalog.to_regprocedure('public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'),
    pg_catalog.to_regprocedure('public.review_ngo_application(uuid,uuid,text,text)')
  ];
BEGIN
  IF array_position(workflow_oids, NULL::oid) IS NOT NULL
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_proc AS p
       JOIN pg_catalog.pg_language AS l ON l.oid = p.prolang
       WHERE p.oid = ANY(workflow_oids)
         AND (p.proowner <> postgres_oid
              OR l.lanname <> 'plpgsql'
              OR NOT p.prosecdef
              OR p.proconfig IS DISTINCT FROM ARRAY['search_path=""']::text[]
              OR p.prosrc NOT LIKE '%transaction_isolation%'
              OR p.prosrc NOT LIKE '%FOR UPDATE%')
     )
     OR has_function_privilege('anon', workflow_oids[1], 'EXECUTE')
     OR has_function_privilege('authenticated', workflow_oids[1], 'EXECUTE')
     OR NOT has_function_privilege('service_role', workflow_oids[1], 'EXECUTE')
     OR has_function_privilege('anon', workflow_oids[2], 'EXECUTE')
     OR has_function_privilege('authenticated', workflow_oids[2], 'EXECUTE')
     OR NOT has_function_privilege('service_role', workflow_oids[2], 'EXECUTE')
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_proc AS p
       CROSS JOIN LATERAL pg_catalog.aclexplode(
         COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
       ) AS acl
       WHERE p.oid = ANY(workflow_oids)
         AND (acl.grantee NOT IN (p.proowner, service_role_oid)
              OR (acl.grantee = service_role_oid
                  AND (acl.privilege_type <> 'EXECUTE'
                       OR acl.grantor <> p.proowner
                       OR acl.is_grantable)))
     ) THEN
    RAISE EXCEPTION 'Submission/review lock-order function postconditions failed';
  END IF;
END;
$workflow_lock_postconditions$;

COMMIT;
