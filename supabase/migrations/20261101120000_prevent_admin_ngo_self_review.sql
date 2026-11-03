-- Prevent an administrator from reviewing their own NGO application.
-- Forward-only follow-up to 20261019090000_admin_ngo_verification.sql.
-- CREATE OR REPLACE preserves the existing owner and EXECUTE ACL.

BEGIN;

DO $preflight$
DECLARE
  review_oid oid := to_regprocedure(
    'public.review_ngo_application(uuid,uuid,text,text)'
  );
  review_owner oid;
  runner_is_superuser boolean;
BEGIN
  IF to_regclass('public.user_roles') IS NULL
     OR to_regclass('public.ngo_applications') IS NULL
     OR to_regclass('public.profiles') IS NULL
     OR to_regclass('public.admin_audit_log') IS NULL
  THEN
    RAISE EXCEPTION 'Admin NGO verification objects are missing; refusing self-review hardening';
  END IF;

  IF review_oid IS NULL THEN
    RAISE EXCEPTION 'public.review_ngo_application(uuid,uuid,text,text) is missing';
  END IF;

  SELECT p.proowner
  INTO review_owner
  FROM pg_catalog.pg_proc AS p
  WHERE p.oid = review_oid
    AND p.prosecdef
    AND p.prolang = (
      SELECT l.oid FROM pg_catalog.pg_language AS l WHERE l.lanname = 'plpgsql'
    )
    AND p.prorettype = 'pg_catalog.void'::regtype
    AND p.proconfig = ARRAY['search_path=""']::text[];

  IF review_owner IS NULL THEN
    RAISE EXCEPTION 'Review RPC security attributes do not match the expected contract';
  END IF;

  SELECT r.rolsuper
  INTO runner_is_superuser
  FROM pg_catalog.pg_roles AS r
  WHERE r.rolname = current_user;

  IF NOT coalesce(runner_is_superuser, false)
     AND review_owner <> (SELECT r.oid FROM pg_catalog.pg_roles AS r WHERE r.rolname = current_user)
  THEN
    RAISE EXCEPTION 'Migration runner must own the review RPC or be a superuser';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_attribute AS a
    WHERE a.attrelid = 'public.ngo_applications'::regclass
      AND a.attname = 'applicant_user_id'
      AND a.attnum > 0
      AND NOT a.attisdropped
  ) THEN
    RAISE EXCEPTION 'ngo_applications.applicant_user_id is missing';
  END IF;
END;
$preflight$;

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

  -- Independently verify the reviewer before looking up application ownership.
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

  -- Lock the application so concurrent status changes cannot race the
  -- conflict-of-interest check.
  SELECT app.applicant_user_id
  INTO applicant_id
  FROM public.ngo_applications AS app
  WHERE app.id = p_application_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application not found or transition is not permitted'
      USING ERRCODE = 'P0002';
  END IF;

  IF applicant_id = p_reviewer_id THEN
    RAISE EXCEPTION 'Administrators cannot review their own NGO application'
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
$function$;

COMMIT;
