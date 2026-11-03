-- NGO analytics remains fail-closed until a trusted, consented analytics
-- dataset and its ingestion rules are approved. symptom_checks currently
-- permits caller-controlled authenticated and anonymous inserts, so a cohort
-- threshold or overlapping aggregate can be manipulated and differenced.
-- This function deliberately returns no statistics. This is not differential
-- privacy. Do not enable aggregates until the data-model decision is resolved.
-- Profile role/signup hardening is applied separately by
-- 20261018214500_profile_role_signup_hardening.sql.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_ngo_dashboard_stats()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
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
$$;

-- Clear platform default ACL entries before granting the single intended API
-- executor. The owner retains the inherent ability to manage its function.
REVOKE ALL ON FUNCTION public.get_ngo_dashboard_stats()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_ngo_dashboard_stats() TO service_role;

DO $analytics_postconditions$
DECLARE
  stats_oid oid := 'public.get_ngo_dashboard_stats()'::regprocedure;
  function_owner oid;
  service_oid oid := 'service_role'::regrole::oid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    WHERE p.oid = stats_oid
      AND p.prorettype = 'jsonb'::regtype
      AND p.prolang = (SELECT l.oid FROM pg_catalog.pg_language AS l WHERE l.lanname = 'sql')
      AND p.prosecdef
      AND p.proconfig = ARRAY['search_path=""']::text[]
      AND p.prosrc = $stats_body$
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
$stats_body$
  ) THEN
    RAISE EXCEPTION 'Fail-closed NGO analytics function definition differs from its reviewed contract';
  END IF;

  SELECT p.proowner INTO function_owner
  FROM pg_catalog.pg_proc AS p WHERE p.oid = stats_oid;

  IF function_owner IS DISTINCT FROM (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'postgres')
     OR has_function_privilege('anon', stats_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', stats_oid, 'EXECUTE')
     OR NOT has_function_privilege(service_oid, stats_oid, 'EXECUTE')
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_proc AS p
       CROSS JOIN LATERAL pg_catalog.aclexplode(
         COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
       ) AS acl
       WHERE p.oid = stats_oid
         AND acl.grantee NOT IN (function_owner, service_oid)
     )
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.pg_proc AS p
       CROSS JOIN LATERAL pg_catalog.aclexplode(
         COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
       ) AS acl
       WHERE p.oid = stats_oid AND acl.grantee = service_oid AND acl.is_grantable
     ) THEN
    RAISE EXCEPTION 'NGO analytics EXECUTE privileges are not restricted to the owner and service_role';
  END IF;
END;
$analytics_postconditions$;

COMMIT;
