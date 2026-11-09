#!/bin/sh
# Deterministic transaction-order test for the applicant-profile lock shared
# by NGO submission, review, and reinstatement. Run only inside a fresh,
# disposable PostgreSQL 17 fixture with PGPASSFILE already configured.
set -eu

: "${REVIEWER_UUID:?REVIEWER_UUID must identify the synthetic fixture admin}"
if [ "${HEALTHBOT_REINSTATEMENT_DISPOSABLE_FIXTURE:-}" != "aihealthbot-admin-ngo-reinstatement-pg17" ]; then
  echo "FATAL: disposable-fixture marker is missing" >&2
  exit 2
fi

PGHOST=db-clean
PGPORT=5432
PGUSER=supabase_admin
PGDATABASE=postgres
export PGHOST PGPORT PGUSER PGDATABASE

psqlq() {
  psql -X -v ON_ERROR_STOP=1 -Atq "$@"
}

server_major="$(psqlq -c "SELECT current_setting('server_version_num')::integer / 10000")"
[ "$server_major" = "17" ] || { echo "FATAL: expected PostgreSQL 17, found major $server_major" >&2; exit 2; }
database_name="$(psqlq -c 'SELECT current_database()')"
[ "$database_name" = "postgres" ] || { echo "FATAL: unexpected database $database_name" >&2; exit 2; }

ids="$(psqlq -F '|' -c 'SELECT gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()')"
IFS='|' read -r applicant_submit applicant_reinstate app_submit_old app_reinstate_old <<EOF
$ids
EOF
for id in "$REVIEWER_UUID" "$applicant_submit" "$applicant_reinstate" "$app_submit_old" "$app_reinstate_old"; do
  printf '%s\n' "$id" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' || {
    echo "FATAL: fixture produced an invalid UUID" >&2
    exit 2
  }
done

case1_app="AIHB_SUBMIT_WINS_SUBMITTER"
case1_reinstate="AIHB_SUBMIT_WINS_REINSTATE"
case2_reinstate="AIHB_REINSTATE_WINS_REINSTATE"
case2_submit="AIHB_REINSTATE_WINS_SUBMITTER"
scratch="$(mktemp -d /tmp/aihb-submission-reinstatement.XXXXXX)"
submit_pid=''
competing_pid=''
gate_pid=''
gate_fifo=''
gate_writer_open=0
cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ "$gate_writer_open" -eq 1 ]; then
    exec 3>&-
    gate_writer_open=0
  fi
  for pid in "$submit_pid" "$competing_pid" "$gate_pid"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [ "$rc" -ne 0 ]; then
    for log in "$scratch"/*.log; do
      [ -f "$log" ] || continue
      echo "--- ${log##*/} ---" >&2
      cat "$log" >&2
    done
    echo "Concurrency-test scratch retained in container at $scratch for diagnostics." >&2
  else
    rm -rf "$scratch"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

collision="$(psqlq -c "
SELECT (
  EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='aihb_reinstatement_race')
  OR EXISTS (SELECT 1 FROM auth.users WHERE id IN ('$applicant_submit'::uuid, '$applicant_reinstate'::uuid))
  OR EXISTS (SELECT 1 FROM public.ngo_applications WHERE id IN ('$app_submit_old'::uuid, '$app_reinstate_old'::uuid))
  OR NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id='$REVIEWER_UUID'::uuid AND role='admin')
)")"
[ "$collision" = "f" ] || { echo "FATAL: synthetic fixture collision or reviewer is not an admin" >&2; exit 2; }

psqlq -v reviewer="$REVIEWER_UUID" -v a1="$applicant_submit" -v a2="$applicant_reinstate" \
  -v app1="$app_submit_old" -v app2="$app_reinstate_old" <<'SQL'
CREATE SCHEMA aihb_reinstatement_race;
CREATE TABLE aihb_reinstatement_race.barriers (
  case_name text PRIMARY KEY,
  applicant_id uuid NOT NULL UNIQUE,
  block_application_name text NOT NULL,
  released boolean NOT NULL DEFAULT false
);

CREATE FUNCTION aihb_reinstatement_race.wait_for_barrier()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $barrier$
DECLARE
  app_name text := pg_catalog.current_setting('application_name', true);
  test_case text;
  expected_app_name text;
  is_released boolean;
BEGIN
  IF TG_TABLE_SCHEMA = 'public' AND TG_TABLE_NAME = 'ngo_applications' AND TG_OP = 'INSERT' THEN
    SELECT b.case_name, b.block_application_name
      INTO test_case, expected_app_name
    FROM aihb_reinstatement_race.barriers AS b
    WHERE b.applicant_id = NEW.applicant_user_id;
  ELSIF TG_TABLE_SCHEMA = 'public' AND TG_TABLE_NAME = 'profiles'
        AND TG_OP = 'UPDATE' AND NEW.role = 'ngo' THEN
    SELECT b.case_name, b.block_application_name
      INTO test_case, expected_app_name
    FROM aihb_reinstatement_race.barriers AS b
    WHERE b.applicant_id = NEW.id;
  ELSE
    RETURN NEW;
  END IF;

  IF test_case IS NULL OR app_name IS DISTINCT FROM expected_app_name THEN
    RETURN NEW;
  END IF;

  -- The test controller holds this row lock until it explicitly releases
  -- the gate. This is a database barrier, not timing-based synchronization.
  SELECT b.released INTO is_released
  FROM aihb_reinstatement_race.barriers AS b
  WHERE b.case_name = test_case
  FOR UPDATE;
  IF is_released IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Concurrency test barrier was not explicitly released';
  END IF;
  RETURN NEW;
END;
$barrier$;
REVOKE ALL ON FUNCTION aihb_reinstatement_race.wait_for_barrier() FROM PUBLIC;

CREATE TRIGGER aihb_reinstatement_race_submission_barrier
BEFORE INSERT ON public.ngo_applications
FOR EACH ROW EXECUTE FUNCTION aihb_reinstatement_race.wait_for_barrier();
CREATE TRIGGER aihb_reinstatement_race_reinstatement_barrier
AFTER UPDATE OF role ON public.profiles
FOR EACH ROW EXECUTE FUNCTION aihb_reinstatement_race.wait_for_barrier();

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES
  (:'a1'::uuid, 'authenticated', 'authenticated', 'race-submit-' || :'a1' || '@example.invalid', '', now(), '{}'::jsonb, '{"full_name":"Synthetic submit race"}'::jsonb, now(), now()),
  (:'a2'::uuid, 'authenticated', 'authenticated', 'race-reinstate-' || :'a2' || '@example.invalid', '', now(), '{}'::jsonb, '{"full_name":"Synthetic reinstate race"}'::jsonb, now(), now());

INSERT INTO public.ngo_applications (
  id, applicant_user_id, organization_name, registration_identifier,
  official_contact_email, official_contact_phone, website,
  evidence_references, status, reviewer_id, decided_at, review_reason, created_at
) VALUES
  (:'app1'::uuid, :'a1'::uuid, 'Race applicant submission wins', 'RACE-SUBMIT-' || :'a1',
   'race-submit-' || :'a1' || '@example.invalid', '+10000000000', NULL, '[]'::jsonb,
   'suspended', :'reviewer'::uuid, now(), 'Original submission-wins suspension', now() - interval '2 days'),
  (:'app2'::uuid, :'a2'::uuid, 'Race applicant reinstatement wins', 'RACE-REINSTATE-' || :'a2',
   'race-reinstate-' || :'a2' || '@example.invalid', '+10000000000', NULL, '[]'::jsonb,
   'suspended', :'reviewer'::uuid, now(), 'Original reinstatement-wins suspension', now() - interval '2 days');

INSERT INTO public.admin_audit_log (actor_id, action, application_id, target_user_id, details)
VALUES
  (:'reviewer'::uuid, 'ngo_application_suspended', :'app1'::uuid, :'a1'::uuid,
   '{"reason":"Original submission-wins suspension"}'::jsonb),
  (:'reviewer'::uuid, 'ngo_application_suspended', :'app2'::uuid, :'a2'::uuid,
   '{"reason":"Original reinstatement-wins suspension"}'::jsonb);

INSERT INTO aihb_reinstatement_race.barriers
  (case_name, applicant_id, block_application_name)
VALUES
  ('submission-wins', :'a1'::uuid, 'AIHB_SUBMIT_WINS_SUBMITTER'),
  ('reinstatement-wins', :'a2'::uuid, 'AIHB_REINSTATE_WINS_REINSTATE');
SQL

wait_for_activity() {
  app="$1"
  predicate="$2"
  attempt=0
  while [ "$attempt" -lt 600 ]; do
    found="$(psqlq -c "SELECT EXISTS (
      SELECT 1 FROM pg_catalog.pg_stat_activity
      WHERE application_name = '$app'
        AND ($predicate)
    )")"
    [ "$found" = "t" ] && return 0
    attempt=$((attempt + 1))
    sleep 0.05
  done
  echo "FATAL: timed out waiting for explicit PostgreSQL barrier/lock state for $app" >&2
  return 1
}

hold_barrier() {
  case_name="$1"
  gate_app="AIHB_GATE_$case_name"
  gate_fifo="$scratch/$case_name.fifo"
  mkfifo "$gate_fifo"
  PGAPPNAME="$gate_app" psql -X -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    <"$gate_fifo" >"$scratch/$gate_app.log" 2>&1 &
  gate_pid=$!
  exec 3>"$gate_fifo"
  gate_writer_open=1
  printf "BEGIN; UPDATE aihb_reinstatement_race.barriers SET released=false WHERE case_name='%s'; SELECT 'GATE_LOCKED';\n" "$case_name" >&3
  wait_for_activity "$gate_app" "state = 'idle in transaction'" || return 1
  grep -F 'GATE_LOCKED' "$scratch/$gate_app.log" >/dev/null || { echo "FATAL: database barrier did not confirm lock acquisition" >&2; return 1; }
}

release_barrier() {
  case_name="$1"
  [ "$gate_writer_open" -eq 1 ] || { echo "FATAL: no open database barrier to release" >&2; return 1; }
  printf "UPDATE aihb_reinstatement_race.barriers SET released=true WHERE case_name='%s'; COMMIT;\\q\n" "$case_name" >&3
  exec 3>&-
  gate_writer_open=0
  if wait "$gate_pid"; then
    gate_pid=''
  else
    status=$?
    echo "FATAL: database barrier controller failed with exit $status" >&2
    gate_pid=''
    return 1
  fi
  changed="$(psqlq -c "SELECT released::text FROM aihb_reinstatement_race.barriers WHERE case_name='$case_name'")"
  [ "$changed" = "true" ] || { echo "FATAL: expected barrier row was not released" >&2; return 1; }
}

start_submit() {
  app_name="$1"
  applicant="$2"
  registration="$3"
  psql -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    -c "BEGIN; SET LOCAL application_name='$app_name'; SET LOCAL ROLE service_role; SELECT public.submit_ngo_application('$applicant'::uuid, 'Synthetic concurrent submission', '$registration', 'race-$applicant@example.invalid', '+10000000000', NULL, '[]'::jsonb); COMMIT" \
    >"$scratch/$app_name.log" 2>&1 &
  submit_pid=$!
}

start_reinstate() {
  app_name="$1"
  applicant_app="$2"
  psql -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    -c "BEGIN; SET LOCAL application_name='$app_name'; SET LOCAL ROLE service_role; SELECT public.reinstate_ngo_application('$REVIEWER_UUID'::uuid, '$applicant_app'::uuid, 'Synthetic deterministic race reinstatement'); COMMIT" \
    >"$scratch/$app_name.log" 2>&1 &
  competing_pid=$!
}

wait_success() {
  pid="$1"
  label="$2"
  if wait "$pid"; then
    return 0
  else
    status=$?
    echo "FATAL: $label unexpectedly failed with exit $status" >&2
    return 1
  fi
}

wait_expected_error() {
  pid="$1"
  expected_state="$2"
  label="$3"
  if wait "$pid"; then
    echo "FATAL: $label unexpectedly succeeded" >&2
    return 1
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || { echo "FATAL: $label did not report a failing SQL call" >&2; return 1; }
  grep -F "ERROR:  $expected_state:" "$scratch/$label.log" >/dev/null || {
    echo "FATAL: $label failed for an unexpected SQLSTATE; expected $expected_state" >&2
    return 1
  }
}

echo "Running deterministic order 1: submission obtains the applicant profile lock first."
hold_barrier submission-wins
start_submit "$case1_app" "$applicant_submit" "RACE-SUBMIT-NEW-$applicant_submit"
wait_for_activity "$case1_app" "state = 'active' AND wait_event_type = 'Lock'"
start_reinstate "$case1_reinstate" "$app_submit_old"
wait_for_activity "$case1_reinstate" "state = 'active' AND wait_event_type = 'Lock'"
release_barrier submission-wins
wait_success "$submit_pid" "$case1_app"
submit_pid=''
wait_expected_error "$competing_pid" P0002 "$case1_reinstate"
competing_pid=''

state="$(psqlq -F '|' -c "
SELECT
  (SELECT role='user' FROM public.profiles WHERE id='$applicant_submit'::uuid),
  (SELECT status='suspended' FROM public.ngo_applications WHERE id='$app_submit_old'::uuid),
  (SELECT count(*)=2 FROM public.ngo_applications WHERE applicant_user_id='$applicant_submit'::uuid),
  (SELECT count(*)=1 FROM public.ngo_applications WHERE applicant_user_id='$applicant_submit'::uuid AND status='pending' AND registration_identifier='RACE-SUBMIT-NEW-$applicant_submit'),
  (SELECT count(*)=1 FROM public.admin_audit_log WHERE application_id='$app_submit_old'::uuid AND action='ngo_application_suspended'),
  (SELECT count(*)=1 FROM public.admin_audit_log AS l JOIN public.ngo_applications AS a ON a.id=l.application_id WHERE a.applicant_user_id='$applicant_submit'::uuid AND a.status='pending' AND l.action='ngo_application_submitted'),
  (SELECT count(*)=0 FROM public.admin_audit_log WHERE application_id='$app_submit_old'::uuid AND action='ngo_application_reinstated')")"
[ "$state" = "t|t|t|t|t|t|t" ] || { echo "FATAL: submission-wins state/audit invariant failed: $state" >&2; exit 1; }
echo "PASS: submission won; reinstatement rejected the now-stale suspended application with P0002 and no partial changes."

# Retain the successful submission event's exact identity and references in
# the run log before the synthetic applicant is deleted/anonymized below.
submission_audit_id="$(psqlq -c "SELECT id::text FROM public.admin_audit_log
  WHERE action='ngo_application_submitted'
    AND target_user_id='$applicant_submit'::uuid
    AND application_id IN (
      SELECT id FROM public.ngo_applications WHERE applicant_user_id='$applicant_submit'::uuid
    )")"
printf '%s\n' "$submission_audit_id" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' || {
  echo "FATAL: successful synthetic submission did not create exactly one identifiable audit UUID" >&2
  exit 1
}
submission_audit_before="$(psqlq -c "SELECT jsonb_build_object(
    'audit_id', id, 'action', action, 'actor_id', actor_id,
    'application_id', application_id, 'target_user_id', target_user_id,
    'details', details, 'anonymized_at', anonymized_at
  )::text
  FROM public.admin_audit_log
  WHERE id='$submission_audit_id'::uuid
    AND actor_id='$applicant_submit'::uuid
    AND target_user_id='$applicant_submit'::uuid
    AND action='ngo_application_submitted'")"
[ -n "$submission_audit_before" ] || { echo "FATAL: successful submission audit row is missing its original references" >&2; exit 1; }
echo "AIHB_CONCURRENCY_SUBMISSION_AUDIT_BEFORE_DELETE $submission_audit_before"

echo "Running deterministic order 2: reinstatement obtains the applicant profile lock first."
hold_barrier reinstatement-wins
start_reinstate "$case2_reinstate" "$app_reinstate_old"
wait_for_activity "$case2_reinstate" "state = 'active' AND wait_event_type = 'Lock'"
start_submit "$case2_submit" "$applicant_reinstate" "RACE-REINSTATE-NEW-$applicant_reinstate"
wait_for_activity "$case2_submit" "state = 'active' AND wait_event_type = 'Lock'"
release_barrier reinstatement-wins
wait_success "$competing_pid" "$case2_reinstate"
competing_pid=''
wait_expected_error "$submit_pid" 42501 "$case2_submit"
submit_pid=''

state="$(psqlq -F '|' -c "
SELECT
  (SELECT role='ngo' FROM public.profiles WHERE id='$applicant_reinstate'::uuid),
  (SELECT status='approved' FROM public.ngo_applications WHERE id='$app_reinstate_old'::uuid),
  (SELECT review_reason IS NULL FROM public.ngo_applications WHERE id='$app_reinstate_old'::uuid),
  (SELECT count(*)=1 FROM public.ngo_applications WHERE applicant_user_id='$applicant_reinstate'::uuid),
  (SELECT count(*)=2 FROM public.admin_audit_log WHERE application_id='$app_reinstate_old'::uuid),
  (SELECT count(*)=1 FROM public.admin_audit_log WHERE application_id='$app_reinstate_old'::uuid AND action='ngo_application_suspended'),
  (SELECT count(*)=1 FROM public.admin_audit_log WHERE application_id='$app_reinstate_old'::uuid AND action='ngo_application_reinstated' AND details->>'reason'='Synthetic deterministic race reinstatement'),
  (SELECT count(*)=0 FROM public.admin_audit_log WHERE target_user_id='$applicant_reinstate'::uuid AND action='ngo_application_submitted')")"
[ "$state" = "t|t|t|t|t|t|t|t" ] || { echo "FATAL: reinstatement-wins state/audit invariant failed: $state" >&2; exit 1; }
echo "PASS: reinstatement won; profile became ngo and the later submission rejected with 42501 without inserting an application."

psqlq <<'SQL'
DROP TRIGGER aihb_reinstatement_race_submission_barrier ON public.ngo_applications;
DROP TRIGGER aihb_reinstatement_race_reinstatement_barrier ON public.profiles;
DROP SCHEMA aihb_reinstatement_race CASCADE;
SQL
psqlq -v a1="$applicant_submit" -v a2="$applicant_reinstate" <<'SQL'
DELETE FROM auth.users WHERE id IN (:'a1'::uuid, :'a2'::uuid);
SQL
state="$(psqlq -F '|' -c "
SELECT
  (SELECT count(*)=0 FROM auth.users WHERE id IN ('$applicant_submit'::uuid, '$applicant_reinstate'::uuid)),
  (SELECT count(*)=0 FROM public.profiles WHERE id IN ('$applicant_submit'::uuid, '$applicant_reinstate'::uuid)),
  (SELECT count(*)=0 FROM public.ngo_applications WHERE applicant_user_id IN ('$applicant_submit'::uuid, '$applicant_reinstate'::uuid))")"
[ "$state" = "t|t|t" ] || { echo "FATAL: test cleanup did not remove only its two synthetic applicants" >&2; exit 1; }
submission_audit_after="$(psqlq -c "SELECT jsonb_build_object(
    'audit_id', id, 'action', action, 'actor_id', actor_id,
    'application_id', application_id, 'target_user_id', target_user_id,
    'details', details, 'anonymized_at', anonymized_at
  )::text
  FROM public.admin_audit_log WHERE id='$submission_audit_id'::uuid
    AND action='ngo_application_submitted'")"
submission_audit_after_valid="$(psqlq -c "SELECT COALESCE(bool_and(
    action='ngo_application_submitted'
    AND actor_id IS NULL AND application_id IS NULL AND target_user_id IS NULL
    AND details='{}'::jsonb AND anonymized_at IS NOT NULL
  ), false)
  FROM public.admin_audit_log WHERE id='$submission_audit_id'::uuid")"
echo "AIHB_CONCURRENCY_SUBMISSION_AUDIT_AFTER_DELETE ${submission_audit_after:-MISSING}"
[ "$submission_audit_after_valid" = "t" ] || { echo "FATAL: the exact synthetic submission audit event was not retained and anonymized" >&2; exit 1; }
echo "PASS: deterministic submission/reinstatement race verified in both serialization orders."
