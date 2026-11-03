-- A single Auth Admin DELETE of auth.users lets PostgreSQL apply these
-- cascades and the audit anonymization trigger in that database transaction.
-- The HTTP request/response is outside that transaction and can be ambiguous.

BEGIN;

ALTER TABLE public.symptom_checks
  DROP CONSTRAINT IF EXISTS symptom_checks_user_id_fkey,
  ADD CONSTRAINT symptom_checks_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES auth.users(id)
    ON DELETE CASCADE;

ALTER TABLE public.admin_audit_log
  DROP CONSTRAINT IF EXISTS admin_audit_log_actor_id_fkey,
  ALTER COLUMN actor_id DROP NOT NULL,
  ADD CONSTRAINT admin_audit_log_actor_id_fkey
    FOREIGN KEY (actor_id)
    REFERENCES public.profiles(id)
    ON DELETE SET NULL,
  ADD COLUMN anonymized_at timestamptz;

CREATE OR REPLACE FUNCTION public.anonymize_account_audit_records()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.anonymize_account_audit_records()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS anonymize_account_audit_records_before_profile_delete
  ON public.profiles;

CREATE TRIGGER anonymize_account_audit_records_before_profile_delete
BEFORE DELETE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.anonymize_account_audit_records();

DO $owner_postcondition$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS p
    WHERE p.oid = to_regprocedure('public.anonymize_account_audit_records()')
      AND p.proowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'postgres')
      AND p.prosecdef
      AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
      AND p.proconfig = ARRAY['search_path=""']::text[]
  ) THEN
    RAISE EXCEPTION 'Account-audit SECURITY DEFINER function must retain the reviewed postgres owner and safe attributes';
  END IF;
END;
$owner_postcondition$;

COMMIT;
