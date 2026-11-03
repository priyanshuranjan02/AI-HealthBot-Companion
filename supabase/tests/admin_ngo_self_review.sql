-- Run after 20261019090000_admin_ngo_verification.sql and
-- 20261101120000_prevent_admin_ngo_self_review.sql in a disposable database.
-- All synthetic Auth, profile, application, role and audit changes roll back.
BEGIN;

SELECT no_plan();

CREATE TEMP TABLE admin_self_review_users (
  label text PRIMARY KEY,
  user_id uuid NOT NULL DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL DEFAULT gen_random_uuid()
);

INSERT INTO admin_self_review_users (label)
VALUES
  ('administrator'),
  ('other-applicant'),
  ('self-approve'),
  ('self-reject'),
  ('self-suspend'),
  ('unauthorized-reviewer');

DO $collision_guard$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM admin_self_review_users AS ids
    WHERE EXISTS (SELECT 1 FROM auth.users AS u WHERE u.id = ids.user_id)
       OR EXISTS (SELECT 1 FROM public.profiles AS p WHERE p.id = ids.user_id)
       OR EXISTS (SELECT 1 FROM public.user_roles AS r WHERE r.user_id = ids.user_id)
       OR EXISTS (SELECT 1 FROM public.admin_audit_log AS l WHERE l.actor_id = ids.user_id OR l.target_user_id = ids.user_id)
       OR EXISTS (SELECT 1 FROM public.ngo_applications AS a WHERE a.id = ids.application_id)
       OR EXISTS (SELECT 1 FROM public.admin_audit_log AS l WHERE l.application_id = ids.application_id)
  ) OR (SELECT count(DISTINCT user_id) FROM admin_self_review_users) <> 6
     OR (SELECT count(DISTINCT application_id) FROM admin_self_review_users) <> 6
     OR (SELECT count(DISTINCT synthetic_id) FROM (
           SELECT user_id AS synthetic_id FROM admin_self_review_users
           UNION ALL
           SELECT application_id FROM admin_self_review_users
         ) AS all_ids) <> 12
  THEN
    RAISE EXCEPTION 'Synthetic admin self-review test identifiers collide with existing data';
  END IF;
END;
$collision_guard$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
SELECT
  user_id,
  'authenticated',
  'authenticated',
  label || '@example.invalid',
  '',
  now(),
  '{}'::jsonb,
  jsonb_build_object('full_name', label),
  now(),
  now()
FROM admin_self_review_users;

INSERT INTO public.user_roles (user_id, role)
SELECT user_id, 'admin'
FROM admin_self_review_users
WHERE label IN ('administrator', 'self-approve', 'self-reject', 'self-suspend');

INSERT INTO public.ngo_applications (
  id, applicant_user_id, organization_name, registration_identifier,
  official_contact_email, official_contact_phone, website,
  evidence_references, status, reviewer_id, decided_at, review_reason
)
SELECT
  application_id,
  user_id,
  'Synthetic ' || label,
  'SYN-' || label,
  label || '@example.invalid',
  '+10000000000',
  '',
  '[]'::jsonb,
  CASE WHEN label = 'self-suspend' THEN 'approved' ELSE 'pending' END,
  CASE WHEN label = 'self-suspend'
    THEN (SELECT user_id FROM admin_self_review_users WHERE label = 'administrator')
    ELSE NULL
  END,
  CASE WHEN label = 'self-suspend' THEN now() ELSE NULL END,
  NULL
FROM admin_self_review_users
WHERE label <> 'administrator' AND label <> 'unauthorized-reviewer';

SELECT lives_ok(
  format(
    'SELECT public.review_ngo_application(%L, %L, %L, NULL)',
    (SELECT user_id FROM admin_self_review_users WHERE label = 'administrator'),
    (SELECT application_id FROM admin_self_review_users WHERE label = 'other-applicant'),
    'approved'
  ),
  'an administrator may approve another user’s pending application'
);

SELECT ok(
  (SELECT status = 'approved' FROM public.ngo_applications
   WHERE id = (SELECT application_id FROM admin_self_review_users WHERE label = 'other-applicant'))
  AND (SELECT role = 'ngo' FROM public.profiles
       WHERE id = (SELECT user_id FROM admin_self_review_users WHERE label = 'other-applicant'))
  AND EXISTS (
    SELECT 1 FROM public.admin_audit_log
    WHERE actor_id = (SELECT user_id FROM admin_self_review_users WHERE label = 'administrator')
      AND application_id = (SELECT application_id FROM admin_self_review_users WHERE label = 'other-applicant')
      AND action = 'ngo_application_approved'
  ),
  'allowed review preserves status, role assignment, and audit logging'
);

SELECT throws_ok(
  format(
    'SELECT public.review_ngo_application(%L, %L, %L, NULL)',
    (SELECT user_id FROM admin_self_review_users WHERE label = 'self-approve'),
    (SELECT application_id FROM admin_self_review_users WHERE label = 'self-approve'),
    'approved'
  ),
  '42501',
  'Administrators cannot review their own NGO application',
  'an administrator cannot approve their own application'
);

SELECT throws_ok(
  format(
    'SELECT public.review_ngo_application(%L, %L, %L, %L)',
    (SELECT user_id FROM admin_self_review_users WHERE label = 'self-reject'),
    (SELECT application_id FROM admin_self_review_users WHERE label = 'self-reject'),
    'rejected',
    'Synthetic rejection reason'
  ),
  '42501',
  'Administrators cannot review their own NGO application',
  'an administrator cannot reject their own application'
);

SELECT throws_ok(
  format(
    'SELECT public.review_ngo_application(%L, %L, %L, %L)',
    (SELECT user_id FROM admin_self_review_users WHERE label = 'self-suspend'),
    (SELECT application_id FROM admin_self_review_users WHERE label = 'self-suspend'),
    'suspended',
    'Synthetic suspension reason'
  ),
  '42501',
  'Administrators cannot review their own NGO application',
  'an administrator cannot suspend their own application'
);

SELECT ok(
  (SELECT status = 'pending' FROM public.ngo_applications
   WHERE id = (SELECT application_id FROM admin_self_review_users WHERE label = 'self-approve'))
  AND (SELECT status = 'pending' FROM public.ngo_applications
       WHERE id = (SELECT application_id FROM admin_self_review_users WHERE label = 'self-reject'))
  AND (SELECT status = 'approved' FROM public.ngo_applications
       WHERE id = (SELECT application_id FROM admin_self_review_users WHERE label = 'self-suspend'))
  AND NOT EXISTS (
    SELECT 1 FROM public.admin_audit_log
    WHERE application_id IN (
      SELECT application_id FROM admin_self_review_users
      WHERE label IN ('self-approve', 'self-reject', 'self-suspend')
    )
  ),
  'rejected self-reviews leave application states and audit history unchanged'
);

SELECT throws_ok(
  format(
    'SELECT public.review_ngo_application(%L, %L, %L, NULL)',
    (SELECT user_id FROM admin_self_review_users WHERE label = 'unauthorized-reviewer'),
    (SELECT application_id FROM admin_self_review_users WHERE label = 'self-approve'),
    'approved'
  ),
  '42501',
  'Administrator access required',
  'a non-administrator remains unable to review applications'
);

SELECT ok(
  has_function_privilege('service_role', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE'),
  'ordinary API roles still cannot execute the privileged review RPC'
);

SELECT * FROM finish();
ROLLBACK;
