#!/usr/bin/env bash
# Host-side, disposable PostgreSQL 17.11 validation for the NGO reinstatement
# candidate. Run manually from macOS Terminal. Never connects to production.
# This script stages only an explicit, hash-pinned migration/test allowlist.

set -Eeuo pipefail
umask 077

SCRIPT_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")" || { printf 'Could not resolve the validation script path.\n' >&2; exit 72; }
[[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] || { printf 'Resolved validation script is not a regular file.\n' >&2; exit 72; }
ROOT="${AIHB_VALIDATION_WORKTREE_ROOT:-$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)}"
EXPECTED_BRANCH='feat/admin-ngo-reinstatement'
EXPECTED_HEAD='a0f7782ec17661b6bc503e4786e2e2ed11a7d582'
EXPECTED_DOCKER_CONTEXT='desktop-linux'
EXPECTED_DOCKER_ENDPOINT='unix:///Users/priyanshuranjan02/.docker/run/docker.sock'
EXPECTED_DOCKER_SERVER_NAME='docker-desktop'
EXPECTED_DOCKER_SERVER_ID='8786abc5-49d1-42b3-953e-8afa360c547b'
EXPECTED_DOCKER_OSTYPE='linux'
LOG_HOME='/private/tmp/aihb-admin-ngo-validation-logs'

# Re-exec through tee in a parent shell so the child's exit code and tee's
# exit code are both collected. No command tracing is enabled (secrets exist
# only in mode-0600 temporary files and Docker env files).
if [[ "${AIHB_VALIDATION_LOG_CHILD:-0}" != '1' ]]; then
  mkdir -p "$LOG_HOME"
  RUN_ID="$(date '+%Y%m%dT%H%M%S')-$(openssl rand -hex 6)"
  LOG_FILE="$LOG_HOME/validation-${RUN_ID}.log"
  SCRIPT_COPY_PATH="$LOG_HOME/validate-admin-ngo-reinstatement-host-${RUN_ID}.sh"
  if ! (set -o noclobber; : > "$LOG_FILE"); then
    printf 'Could not create a new exclusive validation log (refusing to overwrite): %s\n' "$LOG_FILE" >&2
    exit 73
  fi
  if ! python3 - "$SCRIPT_PATH" "$SCRIPT_COPY_PATH" <<'PRESERVE_SCRIPT'
import os, pathlib, shutil, sys
source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
fd = os.open(str(destination), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as target, source.open('rb') as original:
    shutil.copyfileobj(original, target)
    target.flush()
    os.fsync(target.fileno())
PRESERVE_SCRIPT
  then
    printf 'FATAL: could not preserve the exact validation script copy: %s\n' "$SCRIPT_COPY_PATH" | tee -a "$LOG_FILE" >&2
    exit 73
  fi
  SOURCE_SCRIPT_SHA256="$(shasum -a 256 "$SCRIPT_PATH" | awk '{print $1}')" || {
    printf 'FATAL: could not hash the original validation script: %s\n' "$SCRIPT_PATH" | tee -a "$LOG_FILE" >&2
    exit 73
  }
  SAVED_SCRIPT_SHA256="$(shasum -a 256 "$SCRIPT_COPY_PATH" | awk '{print $1}')" || {
    printf 'FATAL: could not hash the preserved validation script: %s\n' "$SCRIPT_COPY_PATH" | tee -a "$LOG_FILE" >&2
    exit 73
  }
  if [[ ! "$SOURCE_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ || "$SOURCE_SCRIPT_SHA256" != "$SAVED_SCRIPT_SHA256" ]]; then
    printf 'FATAL: validation script copy hash mismatch; refusing to run. Original=%s Saved=%s\n' "$SOURCE_SCRIPT_SHA256" "$SAVED_SCRIPT_SHA256" | tee -a "$LOG_FILE" >&2
    exit 73
  fi
  export AIHB_VALIDATION_LOG_CHILD=1 AIHB_VALIDATION_LOG_FILE="$LOG_FILE"
  export AIHB_VALIDATION_RUN_ID="$RUN_ID"
  export AIHB_VALIDATION_SOURCE_SCRIPT_PATH="$SCRIPT_PATH"
  export AIHB_VALIDATION_EXECUTED_SCRIPT_PATH="$SCRIPT_COPY_PATH"
  export AIHB_VALIDATION_SOURCE_SCRIPT_SHA256="$SOURCE_SCRIPT_SHA256"
  export AIHB_VALIDATION_SAVED_SCRIPT_SHA256="$SAVED_SCRIPT_SHA256"
  export AIHB_VALIDATION_WORKTREE_ROOT="$ROOT"
  set +e
  bash "$SCRIPT_COPY_PATH" "$@" 2>&1 | tee -a "$LOG_FILE"
  pipe_status=("${PIPESTATUS[@]}")
  set -e
  script_status="${pipe_status[0]}"
  tee_status="${pipe_status[1]}"
  if [[ "$tee_status" -ne 0 ]]; then
    printf 'ERROR: validation log writer failed (tee exit %s); output completeness is unverified. Log path: %s\n' "$tee_status" "$LOG_FILE" >&2
    exit 74
  fi
  printf 'Validation log: %s\n' "$LOG_FILE"
  exit "$script_status"
fi

case "${AIHB_VALIDATION_LOG_FILE:-}" in
  "$LOG_HOME"/validation-*.log) LOG_FILE="$AIHB_VALIDATION_LOG_FILE" ;;
  *) printf 'Invalid internal log handoff; refusing to run without the timestamped log wrapper.\n' >&2; exit 72 ;;
esac
[[ -f "$LOG_FILE" && ! -L "$LOG_FILE" ]] || { printf 'Internal log file is missing or not a regular file.\n' >&2; exit 72; }
RUN_ID="${AIHB_VALIDATION_RUN_ID:-}"
[[ "$RUN_ID" =~ ^[0-9]{8}T[0-9]{6}-[0-9a-f]{12}$ ]] || { printf 'Invalid validation run ID handoff.\n' >&2; exit 72; }
SOURCE_SCRIPT_PATH="${AIHB_VALIDATION_SOURCE_SCRIPT_PATH:-}"
EXECUTED_SCRIPT_PATH="${AIHB_VALIDATION_EXECUTED_SCRIPT_PATH:-}"
SOURCE_SCRIPT_SHA256="${AIHB_VALIDATION_SOURCE_SCRIPT_SHA256:-}"
SAVED_SCRIPT_SHA256="${AIHB_VALIDATION_SAVED_SCRIPT_SHA256:-}"
[[ "$EXECUTED_SCRIPT_PATH" == "$SCRIPT_PATH" && "$EXECUTED_SCRIPT_PATH" == "$LOG_HOME/validate-admin-ngo-reinstatement-host-${RUN_ID}.sh" ]] || { printf 'Executed validation script is not the preserved per-run copy.\n' >&2; exit 72; }
[[ "$SOURCE_SCRIPT_PATH" == "$ROOT/validate-admin-ngo-reinstatement-host.sh" && -f "$SOURCE_SCRIPT_PATH" && ! -L "$SOURCE_SCRIPT_PATH" ]] || { printf 'Original validation script path is missing or unexpected.\n' >&2; exit 72; }
CURRENT_SOURCE_SCRIPT_SHA256="$(shasum -a 256 "$SOURCE_SCRIPT_PATH" | awk '{print $1}')" || { printf 'Could not re-hash the original validation script.\n' >&2; exit 72; }
CURRENT_EXECUTED_SCRIPT_SHA256="$(shasum -a 256 "$SCRIPT_PATH" | awk '{print $1}')" || { printf 'Could not hash the running validation script copy.\n' >&2; exit 72; }
[[ "$SOURCE_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ && "$SAVED_SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ \
   && "$CURRENT_SOURCE_SCRIPT_SHA256" == "$SOURCE_SCRIPT_SHA256" \
   && "$CURRENT_EXECUTED_SCRIPT_SHA256" == "$SAVED_SCRIPT_SHA256" \
   && "$SOURCE_SCRIPT_SHA256" == "$SAVED_SCRIPT_SHA256" ]] || { printf 'Validation script hash verification failed; refusing to continue.\n' >&2; exit 72; }
LABEL_KEY='org.aihealthbot.synthetic-validation.run'
PREFIX="aihb-reinstate-${RUN_ID}"
NETWORK="${PREFIX}-internal"
VOL_CLEAN="${PREFIX}-pgdata-clean"
VOL_NEG="${PREFIX}-pgdata-negative"
DB_CLEAN="${PREFIX}-db-clean"
DB_NEG="${PREFIX}-db-negative"
AUTH_CLEAN="${PREFIX}-auth-clean"
AUTH_NEG="${PREFIX}-auth-negative"
REST="${PREFIX}-postgrest"
KONG="${PREFIX}-kong"
PG_RUNNER="${PREFIX}-pg-runner"
NODE_RUNNER="${PREFIX}-node-runner"
RUN_DIR=''
NETWORK_CREATED=0
VOLUMES_CREATED=()
VOLUMES_CREATED_COUNT=0
CONTAINERS_CREATED=()
CONTAINERS_CREATED_COUNT=0
FAILURE=0
VALIDATION_COMPLETE=0

readonly PG_IMAGE='public.ecr.aws/supabase/postgres@sha256:b15d862126dd2dac02da524696ccfde2dcce2ceaee0a58973b2727befe492706'
readonly PG_IMAGE_DIGEST='sha256:b15d862126dd2dac02da524696ccfde2dcce2ceaee0a58973b2727befe492706'
PG_IMAGE_ID=''
readonly PROVE_IMAGE='public.ecr.aws/supabase/pg_prove@sha256:eda7c5e68719e9c8287e78c017118407b48df904a51c935f5ab6098b8c0bc6bc'
readonly AUTH_IMAGE='public.ecr.aws/supabase/gotrue@sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b'
readonly REST_IMAGE='public.ecr.aws/supabase/postgrest@sha256:d155c6718ed9a9f990d159a2ab7c0a3f16944dbb6d0a0344557421042acfe0df'
readonly KONG_IMAGE='public.ecr.aws/supabase/kong@sha256:1b53405d8680a09d6f44494b7990bf7da2ea43f84a258c59717d4539abf09f6d'
readonly NODE_IMAGE='node@sha256:2c87ef9bd3c6a3bd4b472b4bec2ce9d16354b0c574f736c476489d09f560a203'
readonly AUTH_API_EXTERNAL_URL='http://kong:8000/auth/v1'

docker() { command docker --context "$EXPECTED_DOCKER_CONTEXT" "$@"; }
die() { printf 'FATAL: %s\n' "$*" >&2; FAILURE=1; exit 1; }
say() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

say "Run ID: $RUN_ID"
say "Original validation script: $SOURCE_SCRIPT_PATH"
say "Preserved executed script copy: $EXECUTED_SCRIPT_PATH"
say "Original script SHA-256: $SOURCE_SCRIPT_SHA256"
say "Saved/executed script SHA-256: $SAVED_SCRIPT_SHA256"
say 'Validation script hash comparison: PASS (original source, saved copy, and executed bytes match).'

snapshot_inventory() {
  local tag="$1"
  local dest="$RUN_DIR/inventory-${tag}"
  mkdir -p "$dest" || return 1
  docker ps -a --no-trunc --format '{{.ID}} {{.Names}} {{.Status}}' > "$dest/containers.txt" || return 1
  docker image ls --no-trunc --digests --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Digest}}' > "$dest/images.txt" || return 1
  docker network ls --no-trunc --format '{{.ID}} {{.Name}} {{.Driver}}' > "$dest/networks.txt" || return 1
  docker volume ls --format '{{.Name}}' > "$dest/volumes.txt" || return 1
  sort -u "$dest/containers.txt" -o "$dest/containers.txt" || return 1
  sort -u "$dest/images.txt" -o "$dest/images.txt" || return 1
  sort -u "$dest/networks.txt" -o "$dest/networks.txt" || return 1
  sort -u "$dest/volumes.txt" -o "$dest/volumes.txt" || return 1
  printf '%s\n' "--- Docker inventory ($tag) ---"
  printf 'containers=%s images=%s networks=%s volumes=%s\n' \
    "$(wc -l < "$dest/containers.txt" | tr -d ' ')" \
    "$(wc -l < "$dest/images.txt" | tr -d ' ')" \
    "$(wc -l < "$dest/networks.txt" | tr -d ' ')" \
    "$(wc -l < "$dest/volumes.txt" | tr -d ' ')"
  cat "$dest/containers.txt" "$dest/images.txt" "$dest/networks.txt" "$dest/volumes.txt" || return 1
}

verify_created_volumes() {
  docker volume inspect "$VOL_CLEAN" "$VOL_NEG" > "$RUN_DIR/volumes-create-inspect.json"
  python3 - "$RUN_ID" "$LABEL_KEY" "$VOL_CLEAN" "$VOL_NEG" "$RUN_DIR/volumes-create-inspect.json" <<'PY'
import json,pathlib,sys
run,key,v1,v2,path=sys.argv[1:]; rows=json.loads(pathlib.Path(path).read_text())
found={r.get('Name'):r for r in rows}
if set(found)!={v1,v2}: raise SystemExit('FAIL: exact newly created volume set mismatch')
for name,v in found.items():
 if (v.get('Labels') or {}).get(key)!=run: raise SystemExit(f'FAIL: refusing unowned volume {name}')
 if v.get('Driver')!='local': raise SystemExit(f'FAIL: unexpected volume driver for {name}')
print('PASS: both newly created volumes carry this run label and use the local driver')
PY
}

safe_remove_container() {
  local id="$1" name label
  name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null)" || { say "Cleanup could not inspect tracked container ID $id; preserving it."; return 1; }
  name="${name#/}"
  label="$(docker inspect -f "{{ index .Config.Labels \"$LABEL_KEY\" }}" "$id" 2>/dev/null)" || { say "Cleanup could not inspect label for $name; preserving it."; return 1; }
  if [[ "$label" != "$RUN_ID" || "$name" != "$PREFIX"-* ]]; then
    say "Cleanup identity mismatch for $name; preserving it."
    return 1
  fi
  if ! docker rm -f "$id" >/dev/null; then
    say "Cleanup failed to remove owned container $name ($id)."
    return 1
  fi
  say "Removed script-created container $name ($id)."
}

safe_remove_volume() {
  local name="$1" label
  label="$(docker volume inspect -f "{{ index .Labels \"$LABEL_KEY\" }}" "$name" 2>/dev/null)" || { say "Cleanup could not inspect volume $name; preserving it."; return 1; }
  [[ "$label" == "$RUN_ID" ]] || { say "Cleanup volume label mismatch for $name; preserving it."; return 1; }
  if ! docker volume rm "$name" >/dev/null; then
    say "Cleanup failed to remove owned volume $name."
    return 1
  fi
  say "Removed script-created volume $name."
}

safe_remove_network() {
  local label
  label="$(docker network inspect -f "{{ index .Labels \"$LABEL_KEY\" }}" "$NETWORK" 2>/dev/null)" || { say "Cleanup could not inspect network $NETWORK; preserving it."; return 1; }
  [[ "$label" == "$RUN_ID" ]] || { say "Cleanup network label mismatch; preserving $NETWORK."; return 1; }
  if ! docker network rm "$NETWORK" >/dev/null; then
    say "Cleanup failed to remove owned network $NETWORK."
    return 1
  fi
  say "Removed script-created network $NETWORK."
}

cleanup() {
  local original_rc="$?" rc=0 id volume
  trap - EXIT INT TERM
  set +e
  say "Cleanup begins for run_id=$RUN_ID; only IDs/names recorded after this script created them are eligible."
  for ((i=CONTAINERS_CREATED_COUNT-1; i>=0; i--)); do
    id="${CONTAINERS_CREATED[$i]}"
    safe_remove_container "$id" || rc=1
  done
  for ((i=0; i<VOLUMES_CREATED_COUNT; i++)); do
    volume="${VOLUMES_CREATED[$i]}"
    safe_remove_volume "$volume" || rc=1
  done
  if [[ "$NETWORK_CREATED" -eq 1 ]]; then safe_remove_network || rc=1; fi
  if [[ -n "$RUN_DIR" && -d "$RUN_DIR" && -d "$RUN_DIR/inventory-before" ]]; then
    snapshot_inventory after || rc=1
    if [[ -f "$RUN_DIR/inventory-before/containers.txt" \
          && -f "$RUN_DIR/inventory-before/images.txt" \
          && -f "$RUN_DIR/inventory-before/networks.txt" \
          && -f "$RUN_DIR/inventory-before/volumes.txt" \
          && -f "$RUN_DIR/inventory-after/containers.txt" \
          && -f "$RUN_DIR/inventory-after/images.txt" \
          && -f "$RUN_DIR/inventory-after/networks.txt" \
          && -f "$RUN_DIR/inventory-after/volumes.txt" ]]; then
      python3 - "$RUN_DIR" "$PREFIX" "$NETWORK" "$VOL_CLEAN" "$VOL_NEG" "${PG_IMAGE_ID:-}" "${PROVE_IMAGE_ID:-}" "${AUTH_IMAGE_ID:-}" "${REST_IMAGE_ID:-}" "${KONG_IMAGE_ID:-}" "${NODE_IMAGE_ID:-}" <<'PYINV' || rc=1
import pathlib,sys
root=pathlib.Path(sys.argv[1]); prefix,net,vc,vn,*allowed_images=sys.argv[2:]
allowed_images={x for x in allowed_images if x}
def rows(p): return [x.split() for x in p.read_text().splitlines() if x.strip()]
before={k:rows(root/'inventory-before'/f) for k,f in [('containers','containers.txt'),('networks','networks.txt'),('volumes','volumes.txt'),('images','images.txt')]}
after={k:rows(root/'inventory-after'/f) for k,f in [('containers','containers.txt'),('networks','networks.txt'),('volumes','volumes.txt'),('images','images.txt')]}
for key in before:
    old={tuple(r) for r in before[key]}; new={tuple(r) for r in after[key]}
    if key != 'images' and old != new:
        raise SystemExit(f'FAIL {key} inventory changed across fixture run; before-only={sorted(old-new)} after-only={sorted(new-old)}')
    if key == 'images':
        missing=old-new
        if missing: raise SystemExit(f'FAIL pre-existing image inventory rows changed or disappeared: {sorted(missing)}')
        unexpected={r[0] for r in new-old if r[0] not in allowed_images}
        if unexpected: raise SystemExit(f'FAIL unexpected image IDs appeared during run: {sorted(unexpected)}')
if any(len(r)>1 and r[1].startswith(prefix) for r in after['containers']): raise SystemExit('FAIL run-prefixed container remains')
if any(len(r)>1 and r[1]==net for r in after['networks']): raise SystemExit('FAIL run network remains')
if any(r and r[0] in (vc,vn) for r in after['volumes']): raise SystemExit('FAIL run volume remains')
print('PASS: pre-existing containers/networks/volumes unchanged; pre-existing images retained; only approved image IDs added; fixture resources removed')
PYINV
    else
      say 'Cleanup could not compare inventories because a before/after inventory file is missing.'
      rc=1
    fi
  fi
  if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
    if ! rm -rf "$RUN_DIR"; then
      say "Cleanup could not remove temporary run directory: $RUN_DIR"
      rc=1
    fi
  fi
  if [[ -d "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
    printf 'ERROR: expected validation log is missing or not a regular file: %s\n' "$LOG_FILE" >&2
    rc=1
  fi
  if [[ "$rc" -ne 0 && "$original_rc" -eq 0 ]]; then original_rc=1; fi
  if [[ "$original_rc" -eq 0 && "$VALIDATION_COMPLETE" -eq 1 && "$rc" -eq 0 ]]; then
    say 'SUCCESS: all required disposable validation, regression, application, and cleanup checks passed. Synthetic fixture evidence only; not production parity.'
  elif [[ "$original_rc" -eq 0 ]]; then
    say 'FATAL: validation did not reach a complete successful state; suppressing success result.'
    original_rc=1
  fi
  exit "$original_rc"
}

on_signal() { exit "$1"; }

check_container_names() {
  local name
  for name in "$DB_CLEAN" "$DB_NEG" "$AUTH_CLEAN" "$AUTH_NEG" "$REST" "$KONG" "$PG_RUNNER" "$NODE_RUNNER"; do
    if awk -v n="$name" '$2 == n { found=1 } END { exit !found }' "$RUN_DIR/inventory-before/containers.txt"; then
      die "Container name collision: $name"; return 1
    fi
  done
  if awk -v n="$NETWORK" '$2 == n { found=1 } END { exit !found }' "$RUN_DIR/inventory-before/networks.txt"; then die "Network name collision: $NETWORK"; return 1; fi
  for name in "$VOL_CLEAN" "$VOL_NEG"; do
    if awk -v n="$name" '$1 == n { found=1 } END { exit !found }' "$RUN_DIR/inventory-before/volumes.txt"; then die "Volume name collision: $name"; return 1; fi
  done
}

stage_sources() {
  local file expected actual src dst
  mkdir -p "$RUN_DIR/inputs/migrations" "$RUN_DIR/inputs/tests" "$RUN_DIR/evidence"
  cat > "$RUN_DIR/manifest.tsv" <<'MANIFEST'
cc9e7e62779a42b0516566eefa1fe085453d9ea39bad234628a33ceb11bfaae6 supabase/migrations/20260328173528_aa29a1fc-f82d-48f7-87ac-2c172ea6b335.sql
6a643dca57ad8b25c905e1df3d4f03bb3c7cd02b5b68adb2338fce8e5e18c3e3 supabase/migrations/20260329060841_0d1febd4-8a8b-4e5d-bf8b-642971433cc6.sql
5531238f871fb77ed180df9147c8da7308146b60cc2e2975be519fd695b3d7e1 supabase/migrations/20260709051821_f5b004d5-8cda-4625-a3a2-55ad72b3a0aa.sql
049bc579bc441086078ce8de2a37c89f5456e1197cd5a13cd3afd390770b973e supabase/migrations/20260710044655_8832d8b6-11fe-4347-a84c-dda4cda668aa.sql
4bfadbbce9d6a5a7dc43067248907cbf464c5c8d944b0397e6f551ab426a3146 supabase/migrations/20260710044723_94ee13bb-e711-42c5-9477-4dad9523dfa6.sql
eb3aa19179ab8ad6a07e0fe2e1157d86628ee39a6d12a250c6d1da23c61c2f7b supabase/migrations/20260710044743_4a976141-cf64-43f1-8b29-3f35f7d6d6ef.sql
38afbfaddb8de30c42350c393b500e2743576f361d72b33851957289ab62a892 supabase/migrations/20261018213000_secure_profile_roles.sql
3b12bc309d722e4af564d898bae713440fb09782478e10524d784f1c1bb27f59 supabase/migrations/20261018214500_profile_role_signup_hardening.sql
deb232433a0b59c73789eaf1ea76757cded28ba91ccfe305fd61dbb4b76e71fe supabase/migrations/20261018220000_privacy_preserving_ngo_analytics.sql
84b01c61c9be91b546a78067e7a3bf71e2f59f6526f52e95b6243964bcd02b43 supabase/migrations/20261019090000_admin_ngo_verification.sql
b8570a3de34696ee592a688084cf7cba57951448bfd0c721e805c098b8938542 supabase/migrations/20261019095000_allow_reviewer_profile_deletion.sql
7e8d11f1852665e0d084cf739ca6af69ca0f175ee436bb43626feb408080d8c8 supabase/migrations/20261019100000_atomic_account_deletion.sql
dfc36c3af62c97812f821e521c9ce434526fb655ad8f9c99d2338a3c630c6897 supabase/migrations/20261019120000_harden_profile_insert_privileges.sql
46d923d6f0453768fe309e6e878cfee9569ca839d97ec331d26d2e85f63f2db3 supabase/migrations/20261027180000_least_privilege_profile_symptom_grants.sql
250d68c32f3f7c414923aefb2c0c611840607dc9764636629cf0e5eacf9ff4c9 supabase/migrations/20261028100000_assert_profile_symptom_security_contract.sql
9bd177bd3e2fc0703a7ed8e32ca99bd26a64988d38308bef1f362e4cd2f09b24 supabase/migrations/20261030151837_revoke_service_role_maintain_privilege.sql
38c2da726335e81f423cea6a01d13cb5f5e5a8337bac555b43e292f454944042 supabase/migrations/20261101120000_prevent_admin_ngo_self_review.sql
1b2129ad9e93443f3d7caed40530a0cca7c1fca2bf6db66330b811249f91c1e4 supabase/migrations/20261107120000_admin_ngo_reinstatement.sql
e25377aaa0f40126c35e673387dcecb3c3eeb6f2808de15370a7b9a6f59fe678 supabase/tests/admin_ngo_reinstatement.sql
d524bf29523265fa0158ad99de925be1120379c94f97b2d00b9007bbe7e58ea2 supabase/tests/admin_ngo_privilege_contract.sql
ac64283de8cb919b8367ce18ddc1efff7ee222326b637bd5a2f2c93abf9c8bce supabase/tests/admin_ngo_self_review.sql
0ff0f5cc329ac740b8a63d9827c7482e1d8539f91ac8ec18863d9da7cfce4a4b supabase/tests/profile_symptom_maintain_upgrade.sql
5d480eeef15e57b7853ecb0041192eb2fa0d8c6bb8c9d0c1fa05491d62e8ef50 supabase/tests/reviewer_account_deletion.sql
c60ff8544b36404e8922a9cf7f1b52613cc27bfced0ce8eeadc7abbae41deab7 src/test/adminReinstatementConcurrency.integration.test.ts
d0a16178703b3213d7f1d05c15126776450a973cd0f702942116bea16320aa7e src/test/adminReinstatementSecurity.test.ts
0c96037267e5932073ef7a1d5ee55c11eb0d8515236e6992fafccf9a70ec1ea0 supabase/tests/admin_ngo_submission_reinstatement_concurrency.sh
ce321cdd474f2022517bf7a62bab056b293bee432d622f4f5b362bf9914b4726 src/test/ngoDashboard.test.tsx
MANIFEST
  while IFS=' ' read -r expected src; do
    [[ -n "$expected" && -n "$src" ]] || continue
    [[ -f "$ROOT/$src" ]] || { die "Required source file missing: $src"; return 1; }
    actual="$(shasum -a 256 "$ROOT/$src" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || { die "Source hash mismatch for $src (expected $expected, got $actual)"; return 1; }
    case "$src" in
      supabase/migrations/*) dst="$RUN_DIR/inputs/migrations/${src##*/}" ;;
      supabase/tests/*) dst="$RUN_DIR/inputs/tests/${src##*/}" ;;
      *) dst="$RUN_DIR/inputs/tests/${src##*/}" ;;
    esac
    cp "$ROOT/$src" "$dst"
    actual="$(shasum -a 256 "$dst" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || { die "Staged source hash mismatch: $src"; return 1; }
    printf '%s  %s\n' "$expected" "$src" >> "$RUN_DIR/evidence/source-manifest.sha256"
  done < "$RUN_DIR/manifest.tsv"
  say 'All manifest-listed source files matched their approved SHA-256 values and staged copies.'
  cat "$RUN_DIR/evidence/source-manifest.sha256"
  python3 - "$ROOT/supabase/migrations/20261107120000_admin_ngo_reinstatement.sql" "$RUN_DIR/inputs/postcondition.sql" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
start_marker = "DO $reinstatement_postconditions$"
end_marker = "$reinstatement_postconditions$;"
start = source.find(start_marker)
if start < 0:
    raise SystemExit("missing exact reinstatement postcondition block")
end = source.find(end_marker, start)
if end < 0:
    raise SystemExit("unterminated reinstatement postcondition block")
end += len(end_marker)
pathlib.Path(sys.argv[2]).write_text(source[start:end] + "\n")
PY
  grep -q '^DO \$reinstatement_postconditions\$' "$RUN_DIR/inputs/postcondition.sql"
  grep -q '^\$reinstatement_postconditions\$;' "$RUN_DIR/inputs/postcondition.sql"
}

stage_application_snapshot() {
  local snapshot_dir="$RUN_DIR/app-source"
  [[ ! -e "$snapshot_dir" ]] || die "Application snapshot path already exists: $snapshot_dir"
  mkdir -p "$snapshot_dir" "$RUN_DIR/evidence" || die 'Could not create the disposable application source snapshot'
  say 'Building a disposable application source snapshot from tracked, staged, modified, and non-ignored untracked project files.'
  python3 - "$ROOT" "$snapshot_dir" "$RUN_DIR/evidence/app-source-manifest.json" "$RUN_DIR/evidence/source-manifest.sha256" <<'PYSNAPSHOT'
import hashlib, json, os, pathlib, shutil, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
destination = pathlib.Path(sys.argv[2]).resolve()
manifest_path = pathlib.Path(sys.argv[3])
approved_manifest_path = pathlib.Path(sys.argv[4])
raw = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=str(root)
)
stage_rows = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=str(root))
gitlinks = {}
for item in stage_rows.split(b'\0'):
    if not item:
        continue
    metadata, path_bytes = item.split(b'\t', 1)
    mode, object_id, _stage = metadata.split()
    if mode == b'160000':
        gitlinks[os.fsdecode(path_bytes)] = hashlib.sha256(object_id).hexdigest()
excluded_dirs = {'.git', 'node_modules', 'dist', 'dist-ssr', '.vite', 'coverage', '.turbo', '.cache'}
secret_names = {'.env', '.env.local', '.env.development', '.env.production', '.env.test', '.env.staging'}
entries = []
for name_bytes in raw.split(b'\0'):
    if not name_bytes:
        continue
    relative = os.fsdecode(name_bytes)
    rel = pathlib.PurePosixPath(relative)
    if rel.is_absolute() or '..' in rel.parts:
        raise SystemExit('FAIL unsafe repository path in Git source inventory')
    if any(part in excluded_dirs for part in rel.parts):
        continue
    if rel.name in secret_names or (rel.name.startswith('.env.') and rel.name.endswith('.local')):
        raise SystemExit('FAIL environment secret file is tracked or otherwise included; refusing to snapshot it')
    source = root.joinpath(*rel.parts)
    target = destination.joinpath(*rel.parts)
    if relative in gitlinks:
        if not source.is_dir() or any(source.iterdir()):
            raise SystemExit('FAIL tracked gitlink is unavailable or nonempty; refusing an incomplete submodule snapshot')
        target.mkdir(parents=True, exist_ok=True)
        entries.append({'path': relative, 'kind': 'empty-gitlink', 'sha256': gitlinks[relative]})
        continue
    if not source.exists() and not source.is_symlink():
        raise SystemExit('FAIL Git-listed source is missing; refusing an incomplete application snapshot')
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        link = os.readlink(str(source))
        resolved = (source.parent / link).resolve()
        if root != resolved and root not in resolved.parents:
            raise SystemExit('FAIL repository symlink resolves outside the worktree')
        os.symlink(link, str(target))
        digest = hashlib.sha256(os.fsencode(link)).hexdigest()
        kind = 'symlink'
    elif source.is_file():
        shutil.copy2(str(source), str(target))
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise SystemExit('FAIL copied source hash mismatch')
        kind = 'file'
    else:
        raise SystemExit('FAIL unsupported non-file repository entry')
    entries.append({'path': relative, 'kind': kind, 'sha256': digest})
if not entries:
    raise SystemExit('FAIL empty application source snapshot')
entries.sort(key=lambda row: row['path'].encode('utf-8', 'surrogateescape'))
manifest = json.dumps(entries, ensure_ascii=True, sort_keys=True, separators=(',', ':')) + '\n'
manifest_path.write_text(manifest, encoding='utf-8')
expected = {row['path']: (row['kind'], row['sha256']) for row in entries}
observed = {}
for path in destination.rglob('*'):
    rel = path.relative_to(destination).as_posix()
    if rel in gitlinks and path.is_dir() and not path.is_symlink():
        observed[rel] = ('empty-gitlink', gitlinks[rel])
    elif path.is_symlink():
        observed[rel] = ('symlink', hashlib.sha256(os.fsencode(os.readlink(str(path)))).hexdigest())
    elif path.is_file():
        observed[rel] = ('file', hashlib.sha256(path.read_bytes()).hexdigest())
if observed != expected:
    raise SystemExit('FAIL snapshot manifest does not match the copied source tree exactly')
approved = {}
for line in approved_manifest_path.read_text(encoding='utf-8').splitlines():
    digest, relative = line.split(None, 1)
    approved[relative] = digest
snapshot_hashes = {row['path']: row['sha256'] for row in entries if row['kind'] == 'file'}
if not approved or any(snapshot_hashes.get(path) != digest for path, digest in approved.items()):
    raise SystemExit('FAIL one or more approved migration/test source hashes differ in the application snapshot')
print(f'PASS source snapshot: {len(entries)} tracked files, symlinks, and empty gitlink markers; manifest_sha256={hashlib.sha256(manifest.encode("utf-8")).hexdigest()}')
print('PASS source snapshot includes tracked and non-ignored untracked files; excludes .git, node_modules, build/cache outputs, and environment secret files')
print(f'PASS all {len(approved)} approved migration/test inputs match the exact staged SHA-256 values')
PYSNAPSHOT
  [[ -s "$RUN_DIR/evidence/app-source-manifest.json" ]] || die 'Application source snapshot manifest was not written'
}

write_helpers() {
  local dbpass jwtsecret
  DBPASS="$(openssl rand -hex 32)"
  JWTSECRET="$(openssl rand -hex 48)"
  printf 'POSTGRES_USER=supabase_admin\nPOSTGRES_DB=postgres\nPOSTGRES_PASSWORD=%s\nPGDATA=/var/lib/postgresql/data\n' "$DBPASS" > "$RUN_DIR/postgres.env"
  chmod 600 "$RUN_DIR/postgres.env"
  for suffix in clean negative; do
    local dbhost="db-${suffix}"
    cat > "$RUN_DIR/gotrue-${suffix}.env" <<EOF
GOTRUE_API_HOST=0.0.0.0
GOTRUE_API_PORT=9999
API_EXTERNAL_URL=${AUTH_API_EXTERNAL_URL}
GOTRUE_DB_DRIVER=postgres
GOTRUE_DB_DATABASE_URL=postgres://supabase_auth_admin:${DBPASS}@${dbhost}:5432/postgres?sslmode=disable
GOTRUE_DB_NAMESPACE=auth
GOTRUE_SITE_URL=http://localhost:3000
GOTRUE_URI_ALLOW_LIST=http://localhost:3000/**
GOTRUE_JWT_SECRET=${JWTSECRET}
GOTRUE_JWT_EXP=3600
GOTRUE_JWT_AUD=authenticated
GOTRUE_JWT_ADMIN_ROLES=service_role
GOTRUE_EXTERNAL_EMAIL_ENABLED=true
GOTRUE_MAILER_AUTOCONFIRM=true
EOF
    chmod 600 "$RUN_DIR/gotrue-${suffix}.env"
  done
  cat > "$RUN_DIR/postgrest.env" <<EOF
PGRST_DB_URI=postgres://authenticator:${DBPASS}@db-clean:5432/postgres?sslmode=disable
PGRST_DB_SCHEMAS=public,auth
PGRST_DB_ANON_ROLE=anon
PGRST_JWT_SECRET=${JWTSECRET}
PGRST_SERVER_PORT=3000
PGRST_DB_USE_LEGACY_GUCS=false
EOF
  chmod 600 "$RUN_DIR/postgrest.env"
  cat > "$RUN_DIR/kong.yml" <<'KONG'
_format_version: "2.1"
_transform: true
services:
  - name: auth-v1
    url: http://auth-clean:9999/
    routes:
      - name: auth-v1-route
        paths: [/auth/v1]
        strip_path: true
  - name: rest-v1
    url: http://postgrest:3000/
    routes:
      - name: rest-v1-route
        paths: [/rest/v1]
        strip_path: true
KONG
  chmod 600 "$RUN_DIR/kong.yml"
  python3 - "$RUN_DIR/gotrue-clean.env" "$RUN_DIR/gotrue-negative.env" "$AUTH_API_EXTERNAL_URL" "$RUN_DIR/kong.yml" <<'PYAUTHCONFIG'
import pathlib, sys
from urllib.parse import parse_qs, urlsplit

clean_path, negative_path, expected_api_url, kong_path = sys.argv[1:]
expected_api = urlsplit(expected_api_url)
if (expected_api.scheme, expected_api.hostname, expected_api.port, expected_api.path) != ('http', 'kong', 8000, '/auth/v1'):
    raise SystemExit('FAIL: API_EXTERNAL_URL must target the isolated Kong alias and Auth route')
kong = pathlib.Path(kong_path).read_text()
if 'url: http://auth-clean:9999/' not in kong or 'paths: [/auth/v1]' not in kong:
    raise SystemExit('FAIL: Kong Auth route does not forward /auth/v1 to the clean GoTrue service')
for path, expected_db_host in ((clean_path, 'db-clean'), (negative_path, 'db-negative')):
    values = {}
    for line in pathlib.Path(path).read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            values[key] = value
    if values.get('API_EXTERNAL_URL') != expected_api_url:
        raise SystemExit(f'FAIL: API_EXTERNAL_URL mismatch in {pathlib.Path(path).name}')
    if values.get('GOTRUE_API_HOST') != '0.0.0.0' or values.get('GOTRUE_API_PORT') != '9999':
        raise SystemExit(f'FAIL: unexpected GoTrue bind address/port in {pathlib.Path(path).name}')
    if values.get('GOTRUE_DB_DRIVER') != 'postgres' or values.get('GOTRUE_DB_NAMESPACE') != 'auth':
        raise SystemExit(f'FAIL: unexpected GoTrue database driver/namespace in {pathlib.Path(path).name}')
    for required in ('GOTRUE_DB_DATABASE_URL', 'GOTRUE_JWT_SECRET', 'GOTRUE_SITE_URL'):
        if not values.get(required):
            raise SystemExit(f'FAIL: required GoTrue setting is empty in {pathlib.Path(path).name}: {required}')
    database = urlsplit(values['GOTRUE_DB_DATABASE_URL'])
    if (database.scheme, database.username, database.hostname, database.port, database.path) != (
        'postgres', 'supabase_auth_admin', expected_db_host, 5432, '/postgres'
    ) or not database.password or parse_qs(database.query).get('sslmode') != ['disable']:
        raise SystemExit(f'FAIL: GoTrue database URL targets the wrong disposable database in {pathlib.Path(path).name}')
print('PASS: GoTrue API URLs route to internal Kong; clean/negative GoTrue DB targets and required settings verified without printing secret values')
PYAUTHCONFIG
  printf '*:5432:postgres:supabase_admin:%s\n*:5432:postgres:postgres:%s\n*:5432:postgres:supabase_auth_admin:%s\n*:5432:postgres:authenticator:%s\n' "$DBPASS" "$DBPASS" "$DBPASS" "$DBPASS" > "$RUN_DIR/pgpass"
  chmod 600 "$RUN_DIR/pgpass"
  {
    printf "\\set fixture_password '%s'\n" "$DBPASS"
    cat <<'SQL'
DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='postgres')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='supabase_auth_admin')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='authenticator') THEN
    RAISE EXCEPTION 'Supabase database image is missing required platform roles';
  END IF;
END;
$roles$;
ALTER ROLE postgres PASSWORD :'fixture_password';
ALTER ROLE supabase_auth_admin PASSWORD :'fixture_password';
ALTER ROLE authenticator PASSWORD :'fixture_password';
SQL
  } > "$RUN_DIR/role-passwords.psql"
  chmod 600 "$RUN_DIR/role-passwords.psql"
  printf '%s' "$JWTSECRET" > "$RUN_DIR/jwt.secret"
  chmod 600 "$RUN_DIR/jwt.secret"
  node - "$RUN_DIR/jwt.secret" "$RUN_DIR/service-role.jwt" "$RUN_DIR/node.env" <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const secret = fs.readFileSync(process.argv[2], 'utf8');
const b64 = (v) => Buffer.from(JSON.stringify(v)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const header = b64({ alg: 'HS256', typ: 'JWT' });
const payload = b64({ aud: 'authenticated', exp: now + 3600, iat: now, iss: 'supabase', role: 'service_role' });
const unsigned = `${header}.${payload}`;
const signature = crypto.createHmac('sha256', secret).update(unsigned).digest('base64url');
const token = `${unsigned}.${signature}`;
fs.writeFileSync(process.argv[3], token, { mode: 0o600 });
fs.writeFileSync(process.argv[4], `HEALTHBOT_REINSTATEMENT_LOCAL_SUPABASE_URL=http://127.0.0.1:8000\nHEALTHBOT_REINSTATEMENT_LOCAL_SERVICE_ROLE_KEY=${token}\nHEALTHBOT_REINSTATEMENT_LOCAL_ADMIN_USER_ID=${process.env.AIHB_REVIEWER_UUID}\nHEALTHBOT_REINSTATEMENT_DISPOSABLE_FIXTURE=aihealthbot-admin-ngo-reinstatement-pg17\n`, { mode: 0o600 });
NODE
  chmod 600 "$RUN_DIR/node.env"
  unset DBPASS JWTSECRET
}

create_resource() {
  local name="$1"; shift
  local id
  id="$(docker create --name "$name" --label "$LABEL_KEY=$RUN_ID" "$@")"
  [[ "$id" =~ ^[0-9a-f]{12,64}$ ]] || { die "docker create returned an invalid container ID for $name"; return 1; }
  CONTAINERS_CREATED+=("$id")
  CONTAINERS_CREATED_COUNT=$((CONTAINERS_CREATED_COUNT + 1))
  CREATED_ID="$id"
}

db_psql() {
  local host="$1" user="$2" database="$3"; shift 3
  docker exec -i "$PG_RUNNER" env PGPASSFILE=/run/pgpass \
    PGOPTIONS='-c search_path="$user",public,auth,extensions' \
    psql -X -v ON_ERROR_STOP=1 -h "$host" -p 5432 -U "$user" -d "$database" "$@"
}

run_sql_suite() {
  local file="$1" context="$2"
  say "Running SQL suite $file ($context) against the clean disposable database."
  docker exec "$PG_RUNNER" env PGPASSFILE=/run/pgpass PGOPTIONS='-c search_path="$user",public,auth,extensions' \
    pg_prove --verbose --failures --host db-clean --port 5432 --username supabase_admin --dbname postgres "/inputs/tests/$file"
}

# Auth service logs can contain connection URLs, JWTs, or other configured
# secret values. Never inspect or print container environment variables.
redact_auth_logs() {
  python3 -c '
import re, sys

patterns = [
    (re.compile(r"(?i)\bBearer\s+[^\s,;]+"), "Bearer [REDACTED]"),
    (re.compile(r"(?i)([\"\x27]?[\w.-]*(?:password|passwd|secret|jwt|token|api[_-]?key|authorization|database[_-]?url|dsn|db[_-]?uri)[\w.-]*[\"\x27]?\s*[:=]\s*[\"\x27]?)([^\"\x27\s,;}]+)"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\b((?:postgres(?:ql)?|https?)://)[^/@\s:]+:[^/@\s]+@"), r"\1[REDACTED]@"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"), "[REDACTED_JWT]"),
]
total = 0
for raw in sys.stdin:
    line = raw.rstrip("\r\n")
    for pattern, replacement in patterns:
        line = pattern.sub(replacement, line)
    if len(line) > 2000:
        line = line[:2000] + " ...[line truncated]"
    remaining = 25000 - total
    if remaining <= 0:
        print("...[Auth log output capped]")
        break
    line = line[:remaining]
    print(line)
    total += len(line) + 1
    if total >= 25000:
        print("...[Auth log output capped]")
        break
'
}

show_auth_readiness_diagnostics() {
  local container host migration_table
  say 'Collecting bounded, redacted GoTrue diagnostics before cleanup; no container environment is read or printed.'
  for container in "$AUTH_CLEAN" "$AUTH_NEG"; do
    say "Auth container status: $container"
    if ! docker inspect --format '{{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}{{if .State.Health}} health={{.State.Health.Status}}{{else}} health=not-configured{{end}}' "$container"; then
      say "Could not inspect Auth container state: $container"
    fi
    say "Last 100 log lines from $container (sanitized; output capped at 25,000 characters):"
    if ! docker logs --timestamps --tail 100 "$container" 2>&1 | redact_auth_logs; then
      say "Could not retrieve complete logs from $container; any returned lines above are partial diagnostics."
    fi
  done

  for host in db-clean db-negative; do
    say "Read-only Auth catalog diagnostics for $host."
    if ! db_psql "$host" supabase_admin postgres <<'SQL'
BEGIN READ ONLY;
SELECT current_database() AS database_name, session_user, current_user;
SELECT to_regclass('auth.users') AS auth_users_relation,
       to_regclass('auth.schema_migrations') AS auth_migrations_relation;
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'auth'
  AND table_name = 'users'
  AND column_name IN ('email_confirmed_at', 'confirmed_at')
ORDER BY column_name;
ROLLBACK;
SQL
    then
      say "Read-only auth.users/catalog inspection failed for $host."
    fi

    if migration_table="$(db_psql "$host" supabase_admin postgres -qAtc "BEGIN READ ONLY; SELECT to_regclass('auth.schema_migrations') IS NOT NULL; ROLLBACK;")" \
       && [[ "$migration_table" == 't' ]]; then
      if ! db_psql "$host" supabase_admin postgres <<'SQL'
BEGIN READ ONLY;
SELECT count(*) AS migration_count,
       min(version) AS first_version,
       max(version) AS latest_version,
       array_agg(version ORDER BY version) AS applied_versions
FROM auth.schema_migrations;
ROLLBACK;
SQL
      then
        say "Could not read Auth migration metadata for $host."
      fi
    else
      say "Auth migration metadata relation is absent or could not be resolved for $host."
    fi
  done
}

auth_readiness_redaction_self_test() {
  local output
  output="$(printf '%s\n' \
    'GOTRUE_DB_DATABASE_URL=postgres://authuser:synthetic-db-secret@db-clean:5432/postgres' \
    'GOTRUE_JWT_SECRET=synthetic-jwt-secret Authorization: Bearer synthetic-access-token' \
    'api_key: synthetic-api-key' \
    '{"password":"synthetic-json-password","connection":"postgres://authuser:synthetic-url-secret@db-negative:5432/postgres"}' \
    'eyJsyntheticHeader123456.eyJsyntheticPayload123456.syntheticSignature123456' | redact_auth_logs)" || die 'Auth diagnostic redaction self-test could not run'
  [[ "$output" != *'synthetic-db-secret'* \
     && "$output" != *'synthetic-jwt-secret'* \
     && "$output" != *'synthetic-access-token'* \
     && "$output" != *'synthetic-api-key'* \
     && "$output" != *'synthetic-json-password'* \
     && "$output" != *'synthetic-url-secret'* \
     && "$output" != *'syntheticHeader123456'* ]] || die 'Auth diagnostic redaction self-test leaked a synthetic secret'
  printf 'PASS: Auth diagnostic redaction self-test removed synthetic URL, password, JWT-secret, bearer-token, API-key, and raw-JWT values\n'
}

auth_schema_ready() {
  local host="$1" result
  if ! result="$(db_psql "$host" supabase_admin postgres -qAt 2>/dev/null <<'SQL'
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SELECT CASE WHEN to_regclass('auth.schema_migrations') IS NOT NULL THEN 'true' ELSE 'false' END
       AS auth_migrations_exists \gset
\if :auth_migrations_exists
  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM auth.schema_migrations WHERE version = '20260831180000'
  ) THEN 'true' ELSE 'false' END AS auth_latest_version_applied \gset
\else
  \set auth_latest_version_applied false
\endif
SELECT (
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users'
      AND column_name = 'email_confirmed_at'
  )
  AND :'auth_latest_version_applied'::boolean
) AS auth_ready;
ROLLBACK;
SQL
)"; then
    return 1
  fi
  [[ "$result" == 't' ]]
}

verify_fresh_baseline() {
  local host="$1"
  say "Checking the clean Supabase platform baseline on $host using a read-only transaction."
  db_psql "$host" supabase_admin postgres <<'SQL'
BEGIN READ ONLY;
DO $fresh_fixture_preflight$
DECLARE
  user_count bigint;
BEGIN
  IF current_database() <> 'postgres'
     OR session_user <> 'supabase_admin'
     OR current_user <> 'supabase_admin'
     OR current_setting('server_version') NOT LIKE '17.11%' THEN
    RAISE EXCEPTION 'Unexpected database identity, runner, or PostgreSQL version';
  END IF;
  IF to_regclass('auth.users') IS NULL
     OR to_regnamespace('auth') IS NULL
     OR to_regnamespace('extensions') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='postgres' AND NOT rolsuper AND rolbypassrls)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='supabase_admin' AND rolsuper)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='anon')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='authenticated')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='service_role')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='supabase_auth_admin')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='authenticator') THEN
    RAISE EXCEPTION 'Required Supabase platform schema/table/role contract is not present';
  END IF;
  SELECT count(*) INTO user_count FROM auth.users;
  IF user_count <> 0 THEN
    RAISE EXCEPTION 'Fresh disposable fixture unexpectedly contains Auth users';
  END IF;
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('profiles'), ('symptom_checks'), ('user_roles'),
      ('ngo_applications'), ('admin_audit_log')
    ) AS expected(name)
    WHERE to_regclass(format('public.%I', expected.name)) IS NOT NULL
  ) OR to_regprocedure('public.handle_new_user()') IS NOT NULL
    OR to_regprocedure('public.prevent_profile_role_escalation()') IS NOT NULL
    OR to_regprocedure('public.get_ngo_dashboard_stats()') IS NOT NULL
    OR to_regprocedure('public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)') IS NOT NULL
    OR to_regprocedure('public.review_ngo_application(uuid,uuid,text,text)') IS NOT NULL
    OR to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Application/workflow objects already exist; refusing to apply the selected chain';
  END IF;
  IF to_regprocedure('public.prevent_untrusted_profile_insert()') IS NOT NULL
     OR to_regprocedure('public.anonymize_account_audit_records()') IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected pre-existing profile/account security function in fresh fixture';
  END IF;
  IF to_regclass('supabase_migrations.schema_migrations') IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected repository migration ledger exists in the fresh fixture';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname IN ('pgtap','dblink')) THEN
    RAISE EXCEPTION 'Test extensions were installed before the clean baseline gate';
  END IF;
END;
$fresh_fixture_preflight$;
ROLLBACK;
SQL
}

apply_one() {
  local host="$1" dbuser="$2" file="$3" label="$4"
  say "Applying $file to $label using session user $dbuser."
  if [[ "$file" == '20261019090000_admin_ngo_verification.sql' ]]; then
    { printf '%s\n' 'SELECT session_user, current_user;' 'SET ROLE postgres;' 'SELECT session_user, current_user;'; printf '\\i /inputs/migrations/%s\n' "$file"; } | db_psql "$host" supabase_admin postgres
  else
    printf '\\i /inputs/migrations/%s\n' "$file" | db_psql "$host" "$dbuser" postgres
  fi
}

make_container_set() {
  local pg_id authc_id authn_id rest_id kong_id pg_runner_id node_runner_id
  docker volume create --label "$LABEL_KEY=$RUN_ID" "$VOL_CLEAN" >/dev/null
  VOLUMES_CREATED+=("$VOL_CLEAN"); VOLUMES_CREATED_COUNT=$((VOLUMES_CREATED_COUNT + 1))
  docker volume create --label "$LABEL_KEY=$RUN_ID" "$VOL_NEG" >/dev/null
  VOLUMES_CREATED+=("$VOL_NEG"); VOLUMES_CREATED_COUNT=$((VOLUMES_CREATED_COUNT + 1))
  verify_created_volumes
  docker network create --internal --driver bridge --ipv6=false --label "$LABEL_KEY=$RUN_ID" "$NETWORK" >/dev/null
  NETWORK_CREATED=1
  docker network inspect "$NETWORK" > "$RUN_DIR/network-inspect.json"
  python3 - "$NETWORK" "$LABEL_KEY" "$RUN_ID" "$RUN_DIR/network-inspect.json" <<'PY'
import json, pathlib, sys
n=json.loads(pathlib.Path(sys.argv[4]).read_text())[0]
if n.get('Name')!=sys.argv[1] or n.get('Driver')!='bridge' or n.get('Internal') is not True or n.get('EnableIPv6') is not False or (n.get('Labels') or {}).get(sys.argv[2])!=sys.argv[3]: raise SystemExit('FAIL: new network identity/isolation check')
print('network_inspection='+json.dumps({'name':n.get('Name'),'driver':n.get('Driver'),'internal':n.get('Internal'),'ipv6':n.get('EnableIPv6'),'run_label':(n.get('Labels') or {}).get(sys.argv[2]),'attached_containers':sorted(x.get('Name','').lstrip('/') for x in (n.get('Containers') or {}).values())},sort_keys=True))
print('PASS: newly created bridge network is internal with IPv6 disabled')
PY
  create_resource "$DB_CLEAN" --network "$NETWORK" --network-alias db-clean --mount "type=volume,src=$VOL_CLEAN,dst=/var/lib/postgresql/data" --env-file "$RUN_DIR/postgres.env" "$PG_IMAGE"; pg_id="$CREATED_ID"
  create_resource "$DB_NEG" --network "$NETWORK" --network-alias db-negative --mount "type=volume,src=$VOL_NEG,dst=/var/lib/postgresql/data" --env-file "$RUN_DIR/postgres.env" "$PG_IMAGE"; pg_id="$CREATED_ID"
  create_resource "$AUTH_CLEAN" --network "$NETWORK" --network-alias auth-clean --env-file "$RUN_DIR/gotrue-clean.env" "$AUTH_IMAGE"; authc_id="$CREATED_ID"
  create_resource "$AUTH_NEG" --network "$NETWORK" --network-alias auth-negative --env-file "$RUN_DIR/gotrue-negative.env" "$AUTH_IMAGE"; authn_id="$CREATED_ID"
  create_resource "$REST" --network "$NETWORK" --network-alias postgrest --env-file "$RUN_DIR/postgrest.env" "$REST_IMAGE"; rest_id="$CREATED_ID"
  create_resource "$KONG" --network "$NETWORK" --network-alias kong --mount "type=bind,src=$RUN_DIR/kong.yml,dst=/home/kong/kong.yml,readonly" -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/home/kong/kong.yml -e KONG_PROXY_LISTEN=0.0.0.0:8000 -e KONG_ADMIN_LISTEN=off -e KONG_PLUGINS=bundled "$KONG_IMAGE"; kong_id="$CREATED_ID"
  create_resource "$PG_RUNNER" --network "$NETWORK" --mount "type=bind,src=$RUN_DIR/inputs,dst=/inputs,readonly" --entrypoint /bin/sh "$PROVE_IMAGE" -c 'while :; do sleep 3600; done'; pg_runner_id="$CREATED_ID"
  create_resource "$NODE_RUNNER" --network "container:$kong_id" --mount "type=bind,src=$RUN_DIR/app-source,dst=/app" --mount "type=bind,src=$RUN_DIR/node-deps/node_modules,dst=/app/node_modules,readonly" --workdir /app --env-file "$RUN_DIR/node.env" --entrypoint node "$NODE_IMAGE_ID" -e 'setInterval(() => {}, 3600000)'; node_runner_id="$CREATED_ID"
  printf '%s\n' "$pg_id" "$authc_id" "$authn_id" "$rest_id" "$kong_id" "$pg_runner_id" "$node_runner_id" >/dev/null
  docker cp "$RUN_DIR/pgpass" "$PG_RUNNER:/run/pgpass" >/dev/null
  NODE_CONTAINER_ID="$node_runner_id"; KONG_CONTAINER_ID="$kong_id"
}

main() {
  local status f i expected_error
  local migrations=(
    20260328173528_aa29a1fc-f82d-48f7-87ac-2c172ea6b335.sql
    20260329060841_0d1febd4-8a8b-4e5d-bf8b-642971433cc6.sql
    20260709051821_f5b004d5-8cda-4625-a3a2-55ad72b3a0aa.sql
    20260710044655_8832d8b6-11fe-4347-a84c-dda4cda668aa.sql
    20260710044723_94ee13bb-e711-42c5-9477-4dad9523dfa6.sql
    20260710044743_4a976141-cf64-43f1-8b29-3f35f7d6d6ef.sql
    20261018213000_secure_profile_roles.sql
    20261018214500_profile_role_signup_hardening.sql
    20261018220000_privacy_preserving_ngo_analytics.sql
    20261019090000_admin_ngo_verification.sql
    20261019095000_allow_reviewer_profile_deletion.sql
    20261019100000_atomic_account_deletion.sql
    20261019120000_harden_profile_insert_privileges.sql
    20261027180000_least_privilege_profile_symptom_grants.sql
    20261028100000_assert_profile_symptom_security_contract.sql
    20261030151837_revoke_service_role_maintain_privilege.sql
    20261101120000_prevent_admin_ngo_self_review.sql
    20261107120000_admin_ngo_reinstatement.sql
  )
  local sql_tests=(admin_ngo_reinstatement.sql admin_ngo_privilege_contract.sql admin_ngo_self_review.sql profile_symptom_maintain_upgrade.sql reviewer_account_deletion.sql)

  trap cleanup EXIT
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM
  RUN_DIR="$(mktemp -d /private/tmp/aihb-reinstate-validation.XXXXXX)"
  say "Temporary RUN_DIR created: $RUN_DIR"
  chmod 700 "$RUN_DIR"
  say "Run ID: $RUN_ID"
  say "Worktree: $ROOT"
  say "Complete timestamped log: $LOG_FILE"

  [[ "$(git -C "$ROOT" rev-parse --show-toplevel)" == "$ROOT" ]] || die 'script must be run from the expected worktree root'
  [[ "$(git -C "$ROOT" branch --show-current)" == "$EXPECTED_BRANCH" ]] || die "wrong branch; expected $EXPECTED_BRANCH"
  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$EXPECTED_HEAD" ]] || die "unexpected HEAD; expected $EXPECTED_HEAD"
  git -C "$ROOT" status --short --branch
  context="$(command docker context show)" || die 'Could not determine the active Docker context'
  say "Active Docker context: $context"
  [[ "$context" == "$EXPECTED_DOCKER_CONTEXT" ]] || die "refusing to use unexpected Docker context: $context (expected $EXPECTED_DOCKER_CONTEXT)"
  context_endpoints="$(docker context inspect --format '{{json .Endpoints}}' "$EXPECTED_DOCKER_CONTEXT")" || die "Could not inspect Docker context $EXPECTED_DOCKER_CONTEXT"
  context_endpoint="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("docker",{}).get("Host", ""))' "$context_endpoints")" || die 'Could not parse the Docker context endpoint'
  say "Pinned Docker endpoint: $context_endpoint"
  [[ "$context_endpoint" == "$EXPECTED_DOCKER_ENDPOINT" ]] || die "Docker endpoint mismatch (expected $EXPECTED_DOCKER_ENDPOINT)"
  server_identity="$(docker info --format '{{.Name}}|{{.ID}}|{{.OSType}}')" || die 'Docker daemon is not accessible; no fixture resources created'
  IFS='|' read -r server_name server_id server_ostype <<< "$server_identity"
  say "Docker server identity: name=$server_name id=$server_id os=$server_ostype"
  [[ "$server_name" == "$EXPECTED_DOCKER_SERVER_NAME" ]] || die "Docker server name mismatch (expected $EXPECTED_DOCKER_SERVER_NAME)"
  [[ "$server_id" == "$EXPECTED_DOCKER_SERVER_ID" ]] || die "Docker server ID mismatch (expected $EXPECTED_DOCKER_SERVER_ID)"
  [[ "$server_ostype" == "$EXPECTED_DOCKER_OSTYPE" ]] || die "Docker server OS type mismatch (expected $EXPECTED_DOCKER_OSTYPE)"
  snapshot_inventory before
  check_container_names

  stage_sources

  say 'Pulling only digest-pinned Supabase fixture images before network creation.'
  docker pull "$PG_IMAGE"
  PG_REPODIGESTS="$(docker image inspect -f '{{json .RepoDigests}}' "$PG_IMAGE")" || die 'Could not inspect PostgreSQL image RepoDigests'
  python3 - "$PG_REPODIGESTS" "$PG_IMAGE_DIGEST" <<'PGDIGEST'
import json,sys
refs=json.loads(sys.argv[1] or 'null') or []
expected=sys.argv[2]
if not any(ref.endswith('@'+expected) for ref in refs): raise SystemExit('FAIL PostgreSQL image RepoDigests do not contain the exact approved immutable digest')
print('PASS: PostgreSQL image RepoDigest matches the approved immutable digest')
PGDIGEST
  PG_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$PG_IMAGE")" || die 'Could not inspect PostgreSQL local image configuration ID'
  [[ "$PG_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || die "PostgreSQL local image configuration ID is empty or malformed: $PG_IMAGE_ID"
  docker pull "$PROVE_IMAGE"
  docker pull "$AUTH_IMAGE"
  docker pull "$REST_IMAGE"
  docker pull "$KONG_IMAGE"
  say "Pulling or confirming the immutable Node image $NODE_IMAGE before network creation."
  docker pull "$NODE_IMAGE"
  NODE_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$NODE_IMAGE")"
  NODE_IMAGE_PLATFORM="$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$NODE_IMAGE")"
  [[ "$NODE_IMAGE_PLATFORM" == 'linux/arm64' ]] || die "Expected Linux ARM64 Node runner image; got $NODE_IMAGE_PLATFORM"
  NODE_REPODIGESTS="$(docker image inspect -f '{{json .RepoDigests}}' "$NODE_IMAGE")"
  python3 - "$NODE_REPODIGESTS" "${NODE_IMAGE#*@}" <<'PYDIGEST'
import json,sys
refs=json.loads(sys.argv[1] or 'null') or []
expected=sys.argv[2]
if not any(ref.endswith('@'+expected) for ref in refs): raise SystemExit('FAIL Node image RepoDigests do not contain the exact approved immutable digest')
print('PASS: Node image RepoDigest matches the approved immutable digest')
PYDIGEST
  [[ "$(docker image inspect -f '{{.Id}}' "$PG_IMAGE")" == "$PG_IMAGE_ID" ]] || die 'PostgreSQL local image configuration ID changed after digest verification'
  PROVE_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$PROVE_IMAGE")"
  AUTH_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$AUTH_IMAGE")"
  REST_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$REST_IMAGE")"
  KONG_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$KONG_IMAGE")"
  say "PostgreSQL image ID verified: $PG_IMAGE_ID; Node image resolved to $NODE_IMAGE_ID for this run."

  mkdir -p "$RUN_DIR/node-deps"
  cp "$ROOT/package.json" "$ROOT/package-lock.json" "$RUN_DIR/node-deps/"
  say 'Host Node version command: node --version'
  node --version
  say 'Host npm version command: npm --version'
  npm --version
  say "Temporary Node dependency directory: $RUN_DIR/node-deps"
  say 'Temporary lock reconciliation command: npm install --package-lock-only --ignore-scripts --no-audit --no-fund --os=linux --cpu=arm64'
  (cd "$RUN_DIR/node-deps" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund --os=linux --cpu=arm64)
  [[ -s "$RUN_DIR/node-deps/package-lock.json" ]] || die 'Temporary lock reconciliation did not produce a package-lock.json'
  TEMP_LOCK_SHA256="$(shasum -a 256 "$RUN_DIR/node-deps/package-lock.json" | awk '{print $1}')"
  [[ "$TEMP_LOCK_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'Temporary package-lock.json SHA-256 is missing or malformed'
  say "Temporary package-lock.json SHA-256: $TEMP_LOCK_SHA256"
  say 'Temporary dependency installation command: npm ci --ignore-scripts --no-audit --no-fund --os=linux --cpu=arm64'
  (cd "$RUN_DIR/node-deps" && npm ci --ignore-scripts --no-audit --no-fund --os=linux --cpu=arm64)
  [[ -x "$RUN_DIR/node-deps/node_modules/.bin/vitest" ]] || die 'Linux ARM64 Vitest executable is missing after temporary npm ci'
  stage_application_snapshot
  REVIEWER_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  export AIHB_REVIEWER_UUID="$REVIEWER_UUID"
  write_helpers
  make_container_set

  say 'Inspecting every fixture container and the internal network before the first PostgreSQL connection.'
  docker network inspect "$NETWORK" > "$RUN_DIR/network-inspect.json"
  docker inspect "${CONTAINERS_CREATED[@]}" > "$RUN_DIR/containers-inspect.json"
  python3 - "$RUN_ID" "$LABEL_KEY" "$NETWORK" "$VOL_CLEAN" "$VOL_NEG" "$DB_CLEAN" "$DB_NEG" "$AUTH_CLEAN" "$AUTH_NEG" "$REST" "$KONG" "$PG_RUNNER" "$NODE_RUNNER" "$PG_IMAGE_ID" "$PROVE_IMAGE_ID" "$AUTH_IMAGE_ID" "$REST_IMAGE_ID" "$KONG_IMAGE_ID" "$NODE_IMAGE_ID" "$RUN_DIR/containers-inspect.json" "$RUN_DIR/network-inspect.json" "$RUN_DIR/app-source" "$RUN_DIR/node-deps/node_modules" <<'PY'
import json,pathlib,sys
run,key,net,vc,vn,db_clean,db_neg,auth_clean,auth_neg,rest,kong,pg_runner,node_runner,pgid,proveid,authid,restid,kongid,nodeid,path,npath,source_snapshot,node_modules=sys.argv[1:]
names=[db_clean,db_neg,auth_clean,auth_neg,rest,kong,pg_runner,node_runner]
expected_images={db_clean:pgid,db_neg:pgid,auth_clean:authid,auth_neg:authid,rest:restid,kong:kongid,pg_runner:proveid,node_runner:nodeid}
aliases={db_clean:'db-clean',db_neg:'db-negative',auth_clean:'auth-clean',auth_neg:'auth-negative',rest:'postgrest',kong:'kong'}
rows=json.loads(pathlib.Path(path).read_text()); found={r['Name'].lstrip('/'):r for r in rows}
if set(found)!=set(names): raise SystemExit(f'FAIL exact container set: {sorted(found)}')
network=json.loads(pathlib.Path(npath).read_text())[0]
if network.get('Name')!=net or network.get('Internal') is not True or network.get('EnableIPv6') is not False: raise SystemExit('FAIL pre-connection network identity/isolation')
attached={x.get('Name','').lstrip('/') for x in (network.get('Containers') or {}).values()}
if not attached.issubset(set(names)): raise SystemExit(f'FAIL unexpected container attached to fixture network before first database connection: {sorted(attached-set(names))}')
for n,c in found.items():
 if (c.get('Config',{}).get('Labels') or {}).get(key)!=run: raise SystemExit(f'FAIL label: {n}')
 if c.get('Image')!=expected_images[n]: raise SystemExit(f'FAIL image identity for {n}')
 if c.get('HostConfig',{}).get('PortBindings') not in (None,{}): raise SystemExit(f'FAIL published port binding: {n}')
 for arr in (c.get('NetworkSettings',{}).get('Ports') or {}).values():
  if any(x.get('HostPort') for x in arr or []): raise SystemExit(f'FAIL host port: {n}')
 mode=c.get('HostConfig',{}).get('NetworkMode')
 if n==node_runner:
  if mode!='container:'+found[kong]['Id']: raise SystemExit('FAIL Node runner is not isolated in Kong namespace')
 elif mode!=net: raise SystemExit(f'FAIL unexpected network for {n}: {mode}')
 configured_networks=set((c.get('NetworkSettings',{}).get('Networks') or {}).keys())
 if configured_networks and configured_networks!={net}: raise SystemExit(f'FAIL unexpected network attachment for {n}: {sorted(configured_networks)}')
 if n in aliases:
  nw=(c.get('NetworkSettings',{}).get('Networks') or {}).get(net)
  if nw is None or aliases[n] not in (nw.get('Aliases') or []): raise SystemExit(f'FAIL network alias for {n}')
 if n in (db_clean,db_neg):
  vol=vc if n==db_clean else vn
  mounts=[m for m in c.get('Mounts',[]) if m.get('Destination')=='/var/lib/postgresql/data']
  if len(mounts)!=1 or mounts[0].get('Name')!=vol or mounts[0].get('Type')!='volume': raise SystemExit(f'FAIL data volume: {n}')
  if len(c.get('Mounts',[]))!=1: raise SystemExit(f'FAIL unexpected extra mount: {n}')
  if c.get('Image')!=pgid: raise SystemExit(f'FAIL immutable PG image: {n}')
 if n==pg_runner:
  ms=c.get('Mounts',[])
  if len(ms)!=1 or ms[0].get('Destination')!='/inputs' or ms[0].get('RW') is not False: raise SystemExit('FAIL SQL input mount must be the sole read-only mount')
 if n==node_runner:
  ms=c.get('Mounts',[])
  by_destination={m.get('Destination'):m for m in ms}
  if len(ms)!=2 or set(by_destination)!={'/app','/app/node_modules'}: raise SystemExit('FAIL Node runner must have exactly source snapshot and dependency mounts')
  if by_destination['/app'].get('Source')!=source_snapshot or by_destination['/app'].get('RW') is not True: raise SystemExit('FAIL Node runner /app must be the exact writable disposable source snapshot')
  if by_destination['/app/node_modules'].get('Source')!=node_modules or by_destination['/app/node_modules'].get('RW') is not False: raise SystemExit('FAIL Node runner dependencies must be the exact read-only Linux dependency mount')
 if n==kong:
  ms=c.get('Mounts',[])
  if len(ms)!=1 or ms[0].get('Destination')!='/home/kong/kong.yml' or ms[0].get('RW') is not False: raise SystemExit('FAIL Kong config mount is not read-only')
 safe={'name':n,'id':c.get('Id'),'image_id':c.get('Image'),'network_mode':mode,'networks':sorted(configured_networks),'port_bindings':c.get('HostConfig',{}).get('PortBindings') or {},'host_published_ports':[],'mount_destinations':[m.get('Destination') for m in c.get('Mounts',[])],'run_label':(c.get('Config',{}).get('Labels') or {}).get(key)}
 print('container_inspection='+json.dumps(safe,sort_keys=True))
print('PASS: all created containers have exact run labels, no host port mappings, only the internal network; PostgreSQL image, volumes, and disposable Node source/dependency mounts match')
PY
  docker volume inspect "$VOL_CLEAN" "$VOL_NEG" > "$RUN_DIR/volumes-inspect.json"
  python3 - "$RUN_ID" "$LABEL_KEY" "$VOL_CLEAN" "$VOL_NEG" "$RUN_DIR/volumes-inspect.json" <<'PY'
import json,pathlib,sys
run,key,v1,v2,path=sys.argv[1:]; rows=json.loads(pathlib.Path(path).read_text())
found={r.get('Name'):r for r in rows}
if set(found)!={v1,v2}: raise SystemExit('FAIL: exact dedicated volume set mismatch')
for name,v in found.items():
 if (v.get('Labels') or {}).get(key)!=run: raise SystemExit(f'FAIL: volume label mismatch for {name}')
 if v.get('Driver')!='local': raise SystemExit(f'FAIL: unexpected volume driver for {name}')
 print('volume_inspection='+json.dumps({'name':name,'driver':v.get('Driver'),'run_label':(v.get('Labels') or {}).get(key)},sort_keys=True))
print('PASS: exact fresh dedicated volumes and run labels verified')
PY
python3 - "$RUN_DIR/network-inspect.json" "$RUN_ID" "$LABEL_KEY" "$NETWORK" <<'PY'
import json,pathlib,sys
p,run,key,name=sys.argv[1:]; n=json.loads(pathlib.Path(p).read_text())[0]
if n.get('Name')!=name or n.get('Driver')!='bridge' or n.get('Internal') is not True or n.get('EnableIPv6') is not False or (n.get('Labels') or {}).get(key)!=run: raise SystemExit('FAIL internal network configuration')
print('PASS: internal network configuration verified before database access')
PY

  say 'Starting PostgreSQL only after the no-published-port and isolated-network gate passed.'
  docker start "$DB_CLEAN" "$DB_NEG" >/dev/null
  docker start "$PG_RUNNER" >/dev/null
  docker exec "$PG_RUNNER" chmod 600 /run/pgpass
  docker exec "$PG_RUNNER" sh -c 'command -v psql >/dev/null && command -v pg_prove >/dev/null && command -v pg_isready >/dev/null'
  say 'Verifying live database and SQL-runner attachments and port bindings before the first PostgreSQL connection.'
  docker network inspect "$NETWORK" > "$RUN_DIR/network-live-inspect.json"
  docker inspect "$DB_CLEAN" "$DB_NEG" "$PG_RUNNER" > "$RUN_DIR/containers-live-inspect.json"
  python3 - "$RUN_ID" "$LABEL_KEY" "$NETWORK" "$DB_CLEAN" "$DB_NEG" "$PG_RUNNER" "$RUN_DIR/network-live-inspect.json" "$RUN_DIR/containers-live-inspect.json" <<'PY'
import json,pathlib,sys
run,key,network,dbc,dbn,runner,npath,cpath=sys.argv[1:]
n=json.loads(pathlib.Path(npath).read_text())[0]
if n.get('Name')!=network or n.get('Internal') is not True or n.get('EnableIPv6') is not False or (n.get('Labels') or {}).get(key)!=run: raise SystemExit('FAIL live internal network identity')
attached={x['Name'].lstrip('/') for x in (n.get('Containers') or {}).values()}
if attached!={dbc,dbn,runner}: raise SystemExit(f'FAIL live network attachments: {sorted(attached)}')
rows=json.loads(pathlib.Path(cpath).read_text()); expected={dbc,dbn,runner}
found={x['Name'].lstrip('/'):x for x in rows}
if set(found)!=expected: raise SystemExit('FAIL live container set')
for name,c in found.items():
 if (c.get('Config',{}).get('Labels') or {}).get(key)!=run: raise SystemExit(f'FAIL live fixture label: {name}')
 if c.get('HostConfig',{}).get('PortBindings') not in (None,{}): raise SystemExit(f'FAIL live host port binding: {name}')
 for entries in (c.get('NetworkSettings',{}).get('Ports') or {}).values():
  if any(x.get('HostPort') for x in entries or []): raise SystemExit(f'FAIL live host port: {name}')
 if c.get('HostConfig',{}).get('NetworkMode')!=network: raise SystemExit(f'FAIL live network mode: {name}')
print('PASS: live PostgreSQL and runner containers have no host ports and are the only internal-network endpoints')
PY
  for attempt in $(seq 1 60); do
    if docker exec "$PG_RUNNER" env PGPASSFILE=/run/pgpass pg_isready -h db-clean -p 5432 -U supabase_admin >/dev/null 2>&1 \
      && docker exec "$PG_RUNNER" env PGPASSFILE=/run/pgpass pg_isready -h db-negative -p 5432 -U supabase_admin >/dev/null 2>&1; then break; fi
    [[ "$attempt" -lt 60 ]] || die 'PostgreSQL readiness timed out'
    sleep 2
  done
  db_psql db-clean supabase_admin postgres < "$RUN_DIR/role-passwords.psql"
  db_psql db-negative supabase_admin postgres < "$RUN_DIR/role-passwords.psql"
  for host in db-clean db-negative; do
    version="$(db_psql "$host" supabase_admin postgres -Atc 'SELECT version();')"
    printf '%s\n' "$version"
    [[ "$version" == *'PostgreSQL 17.11'* ]] || die "Expected PostgreSQL 17.11 at $host"
  done

  say 'Starting both synthetic Auth services; GoTrue applies its own platform Auth migrations only to the two disposable databases.'
  if ! docker start "$AUTH_CLEAN" "$AUTH_NEG" >/dev/null; then
    say 'One or both GoTrue containers failed to start; collecting diagnostics before cleanup.'
    show_auth_readiness_diagnostics
    die 'GoTrue Auth containers did not start'
  fi
  for attempt in $(seq 1 90); do
    if auth_schema_ready db-clean && auth_schema_ready db-negative; then break; fi
    if [[ "$attempt" -eq 90 ]]; then
      say 'GoTrue Auth schema readiness did not complete within 180 seconds; collecting diagnostics before cleanup.'
      show_auth_readiness_diagnostics
      die 'GoTrue Auth migration readiness timed out or email_confirmed_at is absent'
    fi
    sleep 2
  done
  say 'Auth schema readiness verified in both disposable databases.'

  verify_fresh_baseline db-clean
  verify_fresh_baseline db-negative

  # Apply the 17 prerequisites in exact order to both independent databases.
  for ((i=0; i<17; i++)); do
    f="${migrations[$i]}"
    apply_one db-clean postgres "$f" clean
    apply_one db-negative postgres "$f" negative
  done

  say 'Creating the unsafe intermediate-role graph in the negative database before applying the real reinstatement migration.'
  # PostgreSQL folds unquoted identifiers to lowercase. Normalize the full
  # deterministic name before interpolating it into CREATE/GRANT and string
  # literals so every SQL use refers to the same catalog identifier on Bash 3.2.
  BRIDGE="$(printf '%s' "${PREFIX//-/_}_bridge" | tr '[:upper:]' '[:lower:]')"
  [[ "$BRIDGE" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die 'Generated unsafe bridge role identifier'
  say "Synthetic intermediate role identifier: $BRIDGE"
  db_psql db-negative supabase_admin postgres <<SQL
CREATE ROLE $BRIDGE NOLOGIN;
GRANT service_role TO $BRIDGE WITH INHERIT TRUE, SET FALSE;
GRANT $BRIDGE TO authenticated WITH INHERIT FALSE, SET TRUE;
SQL
  db_psql db-negative supabase_admin postgres <<SQL
DO \$check\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$BRIDGE') THEN
    RAISE EXCEPTION 'synthetic bridge role was not created: %', '$BRIDGE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticated')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
    RAISE EXCEPTION 'required API or service role is missing before membership verification';
  END IF;
  IF NOT pg_catalog.has_function_privilege('$BRIDGE', 'public.review_ngo_application(uuid,uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'synthetic bridge does not inherit service_role review RPC EXECUTE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members WHERE member='authenticated'::regrole AND roleid='$BRIDGE'::regrole AND set_option AND NOT inherit_option)
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members WHERE member='$BRIDGE'::regrole AND roleid='service_role'::regrole AND inherit_option AND NOT set_option) THEN
    RAISE EXCEPTION 'unsafe membership graph options do not match the intended test';
  END IF;
END;
\$check\$;
SQL
  expected_error='An API role can SET ROLE to a role that executes the reinstatement RPC'
  if apply_one db-negative postgres 20261107120000_admin_ngo_reinstatement.sql negative > "$RUN_DIR/negative-migration.log" 2>&1; then
    cat "$RUN_DIR/negative-migration.log"
    die 'Unsafe-graph migration unexpectedly succeeded'
  else
    status=$?
    cat "$RUN_DIR/negative-migration.log"
    [[ "$status" -ne 0 ]] || die 'Expected unsafe-graph migration failure exit code was zero'
    grep -Fq "$expected_error" "$RUN_DIR/negative-migration.log" || die 'Migration failure did not match the expected API SET ROLE guard'
    say "PASS negative application test: actual migration rejected unsafe role graph with expected message; psql exit=$status."
  fi
  db_psql db-negative supabase_admin postgres <<'SQL'
DO $rollback_check$
DECLARE
  d text;
  a smallint;
  expected_definition text :=
    'CHECK ((action = ANY (ARRAY[' ||
    '''ngo_application_submitted''::text, ' ||
    '''ngo_application_approved''::text, ' ||
    '''ngo_application_rejected''::text, ' ||
    '''ngo_application_suspended''::text])))';
BEGIN
  IF to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'failed migration left reinstatement RPC behind';
  END IF;
  SELECT attnum INTO a FROM pg_catalog.pg_attribute
  WHERE attrelid='public.admin_audit_log'::regclass AND attname='action'
    AND attnum > 0 AND NOT attisdropped;
  SELECT pg_catalog.pg_get_constraintdef(c.oid) INTO d
  FROM pg_catalog.pg_constraint AS c
  WHERE c.conrelid='public.admin_audit_log'::regclass
    AND c.conname='admin_audit_log_action_check'
    AND c.contype='c' AND c.convalidated
    AND c.conkey=ARRAY[a]::smallint[];
  IF a IS NULL OR d IS DISTINCT FROM expected_definition THEN
    RAISE EXCEPTION 'failed migration did not restore the exact original four-action constraint';
  END IF;
END;
$rollback_check$;
SQL
  say 'PASS negative migration rollback verified: RPC absent and original four-action constraint remains.'

  apply_one db-clean postgres 20261107120000_admin_ngo_reinstatement.sql clean

  say 'Testing actual migration postcondition independently against a post-migration unsafe graph.'
  db_psql db-clean supabase_admin postgres <<SQL
CREATE ROLE $BRIDGE NOLOGIN;
GRANT service_role TO $BRIDGE WITH INHERIT TRUE, SET FALSE;
GRANT $BRIDGE TO authenticated WITH INHERIT FALSE, SET TRUE;
SQL
  db_psql db-clean postgres postgres <<SQL
DO \$check\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$BRIDGE') THEN
    RAISE EXCEPTION 'synthetic bridge role was not created: %', '$BRIDGE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticated')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
    RAISE EXCEPTION 'required API or service role is missing before membership verification';
  END IF;
END;
\$check\$;
SQL
  db_psql db-clean postgres postgres <<SQL
DO \$assert_effective\$
BEGIN
  IF NOT pg_catalog.has_function_privilege('$BRIDGE', 'public.reinstate_ngo_application(uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'post-migration bridge lacks effective reinstatement RPC EXECUTE';
  END IF;
END;
\$assert_effective\$;
SQL
  db_psql db-clean postgres postgres <<SQL
DO \$isolate_postcondition\$
DECLARE
  function_oid oid := 'public.reinstate_ngo_application(uuid,uuid,text)'::regprocedure;
  service_role_oid oid := 'service_role'::regrole::oid;
  bridge_oid oid := '$BRIDGE'::regrole::oid;
  function_owner oid;
BEGIN
  SELECT proowner INTO function_owner FROM pg_catalog.pg_proc WHERE oid=function_oid;
  IF function_owner <> 'postgres'::regrole::oid OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_language AS l ON l.oid=p.prolang
    WHERE p.oid=function_oid AND p.prorettype='pg_catalog.void'::regtype
      AND l.lanname='plpgsql' AND p.prosecdef
      AND p.proconfig=ARRAY['search_path=""']::text[]
  ) THEN RAISE EXCEPTION 'postcondition isolation failed: function owner/security preconditions are not satisfied'; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) AS acl
    WHERE p.oid=function_oid AND acl.grantee<>p.proowner AND acl.grantee<>service_role_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) AS acl
    WHERE p.oid=function_oid AND acl.grantee=service_role_oid
      AND (acl.privilege_type<>'EXECUTE' OR acl.grantor<>p.proowner OR acl.is_grantable)
  ) OR (
    SELECT count(*) FROM pg_catalog.pg_proc AS p
    CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) AS acl
    WHERE p.oid=function_oid AND acl.grantee=service_role_oid
      AND acl.privilege_type='EXECUTE' AND acl.grantor=p.proowner AND NOT acl.is_grantable
  )<>1 THEN RAISE EXCEPTION 'postcondition isolation failed: direct function ACL assertions fail'; END IF;
  IF pg_catalog.has_function_privilege('anon',function_oid,'EXECUTE')
     OR pg_catalog.has_function_privilege('authenticated',function_oid,'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role',function_oid,'EXECUTE') THEN
    RAISE EXCEPTION 'postcondition isolation failed: anon/authenticated/service_role effective EXECUTE assertions fail';
  END IF;
  IF NOT pg_catalog.has_function_privilege(bridge_oid,function_oid,'EXECUTE') THEN
    RAISE EXCEPTION 'postcondition isolation failed: intermediate role lacks effective EXECUTE';
  END IF;
  IF NOT EXISTS (
    WITH RECURSIVE settable_roles(root_oid,role_oid,role_path) AS (
      SELECT 'authenticated'::regrole::oid,'authenticated'::regrole::oid,ARRAY['authenticated'::regrole::oid]::oid[]
      UNION ALL
      SELECT s.root_oid,m.roleid,s.role_path||m.roleid
      FROM settable_roles AS s JOIN pg_catalog.pg_auth_members AS m ON m.member=s.role_oid
      WHERE m.set_option AND NOT (m.roleid=ANY(s.role_path))
    )
    SELECT 1 FROM settable_roles WHERE role_oid=bridge_oid AND role_oid<>root_oid
  ) THEN RAISE EXCEPTION 'postcondition isolation failed: intermediate role is not API SET ROLE reachable'; END IF;
END;
\$isolate_postcondition\$;
SQL
  if db_psql db-clean postgres postgres -f /inputs/postcondition.sql > "$RUN_DIR/postcondition-negative.log" 2>&1; then
    cat "$RUN_DIR/postcondition-negative.log"
    die 'Independent actual postcondition unexpectedly passed with unsafe graph'
  else
    status=$?
    cat "$RUN_DIR/postcondition-negative.log"
    grep -Fq 'Reinstatement RPC EXECUTE privileges do not match the exact service_role-only contract' "$RUN_DIR/postcondition-negative.log" || die 'Independent postcondition failed for an unexpected reason'
    say "PASS independent postcondition regression: direct ACL, owner/security, and seed-role assertions were checked separately; bridge effective EXECUTE and API SET ROLE reachability were confirmed; the exact migration postcondition then rejected the graph through the remaining recursive reachable-role predicate (exit $status)."
  fi
  db_psql db-clean supabase_admin postgres <<SQL
REVOKE $BRIDGE FROM authenticated;
REVOKE service_role FROM $BRIDGE;
DROP ROLE $BRIDGE;
SQL

  # Clean up the negative role graph after the migration rollback.
  db_psql db-negative supabase_admin postgres <<SQL
REVOKE $BRIDGE FROM authenticated;
REVOKE service_role FROM $BRIDGE;
DROP ROLE $BRIDGE;
SQL

  say 'Checking required pgTAP/dblink extensions are available, then installing them only in the migrated clean test database.'
  availability="$(db_psql db-clean supabase_admin postgres -AtF ' ' -c "SELECT name, default_version FROM pg_catalog.pg_available_extensions WHERE name IN ('pgtap','dblink') ORDER BY name")"
  printf '%s\n' "$availability"
  [[ "$availability" == *pgtap* && "$availability" == *dblink* ]] || die 'Required pgTAP and dblink extension packages are unavailable in the pinned image'
  db_psql db-clean supabase_admin postgres <<'SQL'
CREATE EXTENSION pgtap WITH SCHEMA extensions;
CREATE EXTENSION dblink WITH SCHEMA extensions;
SQL

  # Establish that the reviewer-deletion suite passes against the newly
  # migrated database before any integration test can leave retained audit
  # events behind.
  run_sql_suite reviewer_account_deletion.sql 'standalone freshly migrated baseline'

  say 'Starting PostgREST before Kong; Auth services were started and schema-verified earlier.'
  docker start "$REST" >/dev/null
  for service in "$AUTH_CLEAN" "$AUTH_NEG" "$REST"; do
    service_running="$(docker inspect -f '{{.State.Running}}' "$service")"
    [[ "$service_running" == 'true' ]] || die "Required Auth/PostgREST service is not running before Kong startup: $service"
  done
  docker start "$KONG" >/dev/null
  say 'Starting the Node runner only after Kong is running (it shares Kong network namespace).'
  docker start "$NODE_RUNNER" >/dev/null
  docker exec "$NODE_RUNNER" node --version
  docker exec "$NODE_RUNNER" node -e "require('/app/node_modules/vitest/package.json'); console.log('PASS isolated Linux Node/Vitest dependency smoke test')"
  docker exec "$NODE_RUNNER" /app/node_modules/.bin/vitest --version
  for attempt in $(seq 1 90); do
    if docker exec "$NODE_RUNNER" node -e "Promise.all(['http://auth-clean:9999/health','http://auth-negative:9999/health','http://postgrest:3000/'].map(async u=>{const r=await fetch(u);if(!r.ok)throw new Error(u+' returned '+r.status)})).catch(()=>{process.exitCode=1})" >/dev/null 2>&1; then break; fi
    [[ "$attempt" -lt 90 ]] || die 'Auth/PostgREST internal readiness checks did not become ready'
    sleep 2
  done
  for service in "$AUTH_CLEAN" "$AUTH_NEG" "$REST" "$KONG"; do
    service_running="$(docker inspect -f '{{.State.Running}}' "$service")"
    [[ "$service_running" == 'true' ]] || die "Required Auth/PostgREST/Kong service is not running before Kong health check: $service"
  done
  for attempt in $(seq 1 90); do
    if docker exec "$NODE_RUNNER" node -e "fetch('http://127.0.0.1:8000/auth/v1/health').then(r=>{if(!r.ok)process.exitCode=1}).catch(()=>process.exitCode=1)" >/dev/null 2>&1; then break; fi
    [[ "$attempt" -lt 90 ]] || die 'Kong/Auth internal health route did not become ready'
    sleep 2
  done
  db_psql db-clean supabase_admin postgres -v reviewer="$REVIEWER_UUID" <<'SQL'
INSERT INTO auth.users (id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
VALUES (:'reviewer','authenticated','authenticated',:'reviewer' || '@example.invalid','',now(),'{}'::jsonb,'{"full_name":"Synthetic reinstatement reviewer"}'::jsonb,now(),now());
INSERT INTO public.user_roles (user_id,role) VALUES (:'reviewer','admin');
SQL
  # Verify only the synthetic reviewer UUID; never print the service JWT.
  grep -Fxq "HEALTHBOT_REINSTATEMENT_LOCAL_ADMIN_USER_ID=$REVIEWER_UUID" "$RUN_DIR/node.env" || die 'Node runner reviewer UUID environment was not configured correctly'
  docker exec "$NODE_RUNNER" /app/node_modules/.bin/vitest run src/test/adminReinstatementConcurrency.integration.test.ts --config vitest.config.ts --silent=false

  say 'Running deterministic two-order submission/reinstatement concurrency barriers through internal PostgreSQL sessions.'
  if docker exec "$PG_RUNNER" env PGPASSFILE=/run/pgpass REVIEWER_UUID="$REVIEWER_UUID" HEALTHBOT_REINSTATEMENT_DISPOSABLE_FIXTURE=aihealthbot-admin-ngo-reinstatement-pg17 sh /inputs/tests/admin_ngo_submission_reinstatement_concurrency.sh; then
    say 'PASS deterministic submission/reinstatement serialization in both orderings.'
  else
    status=$?
    die "Deterministic submission/reinstatement concurrency test FAILED exit=$status"
  fi

  say 'Reading only synthetic NGO audit metadata left by the concurrency integration after its applicant cleanup.'
  db_psql db-clean supabase_admin postgres -P format=unaligned -Atc "SELECT COALESCE(jsonb_agg(jsonb_build_object('audit_id',id,'action',action,'actor_id',actor_id,'application_id',application_id,'target_user_id',target_user_id,'anonymized',anonymized_at IS NOT NULL) ORDER BY created_at,id),'[]'::jsonb) FROM public.admin_audit_log WHERE action IN ('ngo_application_suspended','ngo_application_reinstated')"

  say 'Reproducing reviewer_account_deletion after every preceding SQL suite while retaining the same database state.'
  run_sql_suite reviewer_account_deletion.sql 'after concurrency integration'
  for ((i=0; i<4; i++)); do
    f="${sql_tests[$i]}"
    run_sql_suite "$f" 'suite-order contamination check'
    run_sql_suite reviewer_account_deletion.sql "after $f"
  done

  say 'Running all five SQL regression suites through pg_prove on the clean disposable database.'
  for f in "${sql_tests[@]}"; do
    run_sql_suite "$f" 'complete SQL regression run'
  done

  say 'Running read-only final migration postconditions and database identity checks.'
  db_psql db-clean supabase_admin postgres <<'SQL'
BEGIN READ ONLY;
SELECT version();
SELECT session_user, current_user;
SELECT p.proowner::regrole, p.prosecdef, p.proconfig, l.lanname,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_language l ON l.oid=p.prolang
WHERE p.oid=to_regprocedure('public.reinstate_ngo_application(uuid,uuid,text)');
SELECT pg_catalog.pg_get_constraintdef(c.oid)
FROM pg_catalog.pg_constraint c
WHERE c.conrelid='public.admin_audit_log'::regclass AND c.conname='admin_audit_log_action_check';
ROLLBACK;
SQL

  say 'Running host application validation with synthetic loopback Vite settings. All opt-in integration variables are unset; the disposable concurrency test ran separately.'
  if (cd "$ROOT" && env -u HEALTHBOT_REINSTATEMENT_LOCAL_SUPABASE_URL -u HEALTHBOT_REINSTATEMENT_LOCAL_SERVICE_ROLE_KEY -u HEALTHBOT_REINSTATEMENT_LOCAL_ADMIN_USER_ID -u HEALTHBOT_REINSTATEMENT_DISPOSABLE_FIXTURE -u HEALTHBOT_DISPOSABLE_LOCAL_SUPABASE_URL -u HEALTHBOT_DISPOSABLE_LOCAL_SUPABASE_ANON_KEY VITE_SUPABASE_URL=http://127.0.0.1:8000 VITE_SUPABASE_PUBLISHABLE_KEY=synthetic-test-key npm test); then say 'npm test exit 0 (report skipped tests separately; skipped tests are not counted as passes).'; else status=$?; die "npm test FAILED exit=$status"; fi
  if (cd "$ROOT" && env VITE_SUPABASE_URL=http://127.0.0.1:8000 VITE_SUPABASE_PUBLISHABLE_KEY=synthetic-test-key npx tsc --noEmit); then say 'npx tsc --noEmit PASS'; else status=$?; die "TypeScript FAILED exit=$status"; fi
  if (cd "$ROOT" && env VITE_SUPABASE_URL=http://127.0.0.1:8000 VITE_SUPABASE_PUBLISHABLE_KEY=synthetic-test-key npm run lint); then say 'npm run lint PASS'; else status=$?; die "lint FAILED exit=$status"; fi
  if (cd "$ROOT" && env VITE_SUPABASE_URL=http://127.0.0.1:8000 VITE_SUPABASE_PUBLISHABLE_KEY=synthetic-test-key npm run build -- --outDir "$RUN_DIR/dist"); then say 'npm run build PASS (output isolated in temporary directory).'; else status=$?; die "build FAILED exit=$status"; fi
  if (cd "$ROOT" && git diff --check); then say 'git diff --check PASS (tracked changes; untracked files are not included by Git diff).'; else status=$?; die "git diff --check FAILED exit=$status"; fi
  if python3 - "$ROOT" <<'PYWHITESPACE'
import os,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
def names(args):
    raw=subprocess.check_output(args,cwd=root)
    return {os.fsdecode(x) for x in raw.split(b'\0') if x}
paths=names(['git','diff','--name-only','--diff-filter=ACDMRTUXB','-z','HEAD']) | names(['git','ls-files','--others','--exclude-standard','-z'])
errors=[]
for rel in sorted(paths):
    path=root/rel
    if not path.is_file():
        continue
    try: lines=path.read_bytes().splitlines(keepends=True)
    except OSError as e:
        errors.append(f'cannot read changed file {rel}: {e}')
        continue
    for number,line in enumerate(lines,1):
        body=line.rstrip(b'\r\n')
        if body.endswith((b' ',b'\t')): errors.append(f'trailing whitespace: {rel}:{number}')
if errors:
    print('\n'.join(errors)); raise SystemExit(1)
print(f'PASS: trailing-whitespace scan covered {len(paths)} changed/staged/untracked paths')
PYWHITESPACE
  then
    say 'Static whitespace check PASS for all modified, staged, and untracked files.'
  else status=$?; die "modified/untracked whitespace check FAILED exit=$status"; fi
  VALIDATION_COMPLETE=1
}

run_cleanup_failure_case() {
  local case_name="$1" resource_kind="$2" test_root="$3" trigger_mode="${4:-fatal}" output status calls run_dir expected_call test_prefix
  calls="$test_root/$case_name.calls"
  run_dir="$test_root/$case_name-run"
  test_prefix="aihb-cleanup-selftest-$case_name"
  if output="$(
    (
      RUN_DIR="$run_dir"
      RUN_ID="cleanup-selftest-$case_name"
      PREFIX="aihb-cleanup-selftest-$case_name"
      NETWORK="$PREFIX-network"
      VOL_CLEAN="$PREFIX-volume-clean"
      VOL_NEG="$PREFIX-volume-negative"
      LOG_FILE="$AIHB_VALIDATION_LOG_FILE"
      LABEL_KEY='org.aihealthbot.synthetic-validation.run'
      NETWORK_CREATED=0
      VOLUMES_CREATED=()
      VOLUMES_CREATED_COUNT=0
      CONTAINERS_CREATED=()
      CONTAINERS_CREATED_COUNT=0
      VALIDATION_COMPLETE=0
      SELFTEST_CALLS="$calls"
      SELFTEST_FAIL_RM_ID=''
      mkdir -p "$RUN_DIR/inventory-before"
      printf 'preexisting-container stopped\n' > "$RUN_DIR/inventory-before/containers.txt"
      printf 'preexisting-image node:old sha256:unchanged\n' > "$RUN_DIR/inventory-before/images.txt"
      printf 'preexisting-network bridge\n' > "$RUN_DIR/inventory-before/networks.txt"
      printf 'preexisting-volume\n' > "$RUN_DIR/inventory-before/volumes.txt"
      : > "$SELFTEST_CALLS"
      snapshot_inventory() {
        local tag="$1"
        printf 'snapshot:%s\n' "$tag" >> "$SELFTEST_CALLS"
        if [[ "$tag" == 'after' ]]; then
          mkdir -p "$RUN_DIR/inventory-after"
          cp "$RUN_DIR/inventory-before/containers.txt" "$RUN_DIR/inventory-after/containers.txt"
          cp "$RUN_DIR/inventory-before/images.txt" "$RUN_DIR/inventory-after/images.txt"
          cp "$RUN_DIR/inventory-before/networks.txt" "$RUN_DIR/inventory-after/networks.txt"
          cp "$RUN_DIR/inventory-before/volumes.txt" "$RUN_DIR/inventory-after/volumes.txt"
        fi
      }
      docker() {
        printf 'docker' >> "$SELFTEST_CALLS"
        printf ' %s' "$@" >> "$SELFTEST_CALLS"
        printf '\n' >> "$SELFTEST_CALLS"
        if [[ "$1" == 'inspect' && "$2" == '-f' ]]; then
          if [[ "$3" == '{{.Name}}' ]]; then printf '/%s-synthetic-container\n' "$PREFIX"; return 0; fi
          if [[ "$3" == *'.Config.Labels'* ]]; then printf '%s\n' "$RUN_ID"; return 0; fi
        fi
        if [[ "$1" == 'volume' && "$2" == 'inspect' ]]; then printf '%s\n' "$RUN_ID"; return 0; fi
        if [[ "$1" == 'rm' && "$2" == '-f' ]]; then
          [[ -z "$SELFTEST_FAIL_RM_ID" || "$3" != "$SELFTEST_FAIL_RM_ID" ]] || return 77
          return 0
        fi
        if [[ "$1" == 'volume' && "$2" == 'rm' ]]; then return 0; fi
        printf 'unexpected mocked Docker operation\n' >&2
        return 90
      }
      if [[ "$resource_kind" == 'volume' ]]; then
        VOLUMES_CREATED[0]="$PREFIX-volume-first"
        VOLUMES_CREATED_COUNT=1
      elif [[ "$resource_kind" == 'container' ]]; then
        CONTAINERS_CREATED[0]='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        CONTAINERS_CREATED_COUNT=1
      elif [[ "$resource_kind" == 'container_pair_fail' ]]; then
        CONTAINERS_CREATED[0]='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        CONTAINERS_CREATED[1]='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        CONTAINERS_CREATED_COUNT=2
        SELFTEST_FAIL_RM_ID='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      elif [[ "$resource_kind" != 'none' ]]; then
        printf 'unknown cleanup self-test resource kind\n' >&2
        exit 91
      fi
      trap cleanup EXIT
      if [[ "$trigger_mode" == 'cleanup-failure-on-success' ]]; then
        VALIDATION_COMPLETE=1
        exit 0
      fi
      die "failure-injection-$case_name"
    ) 2>&1
  )"; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq 1 ]] || die "cleanup self-test $case_name did not preserve nonzero exit status 1 (got $status)"
  if [[ "$trigger_mode" == 'cleanup-failure-on-success' ]]; then
    [[ "$output" == *'Cleanup failed to remove owned container'* ]] || die 'cleanup self-test D did not report the injected removal failure'
    [[ "$output" != *'SUCCESS:'* ]] || die 'cleanup self-test D incorrectly printed success after cleanup failure'
  else
    [[ "$output" == *"FATAL: failure-injection-$case_name"* ]] || die "cleanup self-test $case_name lost the fatal diagnostic"
  fi
  [[ "$output" == *'Cleanup begins'* ]] || die "cleanup self-test $case_name did not enter cleanup"
  [[ "$output" == *'PASS: pre-existing containers/networks/volumes unchanged'* ]] || die "cleanup self-test $case_name did not complete mocked inventory comparison"
  [[ ! -d "$run_dir" ]] || die "cleanup self-test $case_name left its temporary run directory"
  grep -Fxq 'snapshot:after' "$calls" || die "cleanup self-test $case_name did not take its after-run inventory snapshot"
  case "$resource_kind" in
    none)
      if grep -E 'docker (rm|volume rm)' "$calls" >/dev/null; then die 'cleanup self-test A attempted an untracked resource removal'; fi
      ;;
    volume)
      expected_call="docker volume inspect -f {{ index .Labels \"$LABEL_KEY\" }} $test_prefix-volume-first"
      grep -Fxq "$expected_call" "$calls" || die 'cleanup self-test B did not inspect the tracked volume label'
      grep -Fxq "docker volume rm $test_prefix-volume-first" "$calls" || die 'cleanup self-test B did not remove exactly the tracked volume'
      if grep 'docker rm -f ' "$calls" >/dev/null; then die 'cleanup self-test B attempted container removal'; fi
      ;;
    container)
      grep -Fq 'docker rm -f 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' "$calls" || die 'cleanup self-test C did not remove exactly the tracked container ID'
      if grep 'docker volume rm ' "$calls" >/dev/null; then die 'cleanup self-test C attempted volume removal'; fi
      ;;
    container_pair_fail)
      grep -Fq 'docker rm -f bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$calls" || die 'cleanup self-test D did not attempt the first failing tracked container'
      grep -Fq 'docker rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$calls" || die 'cleanup self-test D stopped before attempting the remaining tracked container'
      ;;
  esac
  printf 'PASS: cleanup failure-injection case %s (%s resource): nonzero exit, after-inventory, only tracked cleanup targets\n' "$case_name" "$resource_kind"
}

failure_exit_self_test() {
  local output status selftest_root
  if output="$(
    (
      trap 'printf "EXIT_CLEANUP_MARKER\\n"' EXIT
      die 'failure-injection guard must exit nonzero'
    ) 2>&1
  )"; then
    die 'failure-injection defect: fatal guard returned success'
  else
    status=$?
  fi
  [[ "$status" -ne 0 ]] || die 'failure-injection defect: fatal guard exit status was zero'
  [[ "$output" == *'FATAL: failure-injection guard must exit nonzero'* ]] || die 'failure-injection defect: fatal diagnostic was not captured'
  [[ "$output" == *'EXIT_CLEANUP_MARKER'* ]] || die 'failure-injection defect: EXIT cleanup trap did not run'
  printf 'PASS: injected fatal guard exited %s and invoked EXIT cleanup trap\n' "$status"

  selftest_root="$(mktemp -d /private/tmp/aihb-cleanup-selftest.XXXXXX)"
  chmod 700 "$selftest_root"
  trap 'rm -rf "$selftest_root"' EXIT
  run_cleanup_failure_case A none "$selftest_root"
  run_cleanup_failure_case B volume "$selftest_root"
  run_cleanup_failure_case C container "$selftest_root"
  run_cleanup_failure_case D container_pair_fail "$selftest_root" cleanup-failure-on-success
  rm -rf "$selftest_root"
  trap - EXIT
}

# Docker-free proof of fatal guard behavior; it bypasses main() entirely.
if [[ "${AIHB_VALIDATION_FATAL_SELF_TEST:-0}" == '1' ]]; then
  auth_readiness_redaction_self_test
  failure_exit_self_test
  exit 0
fi

# The log wrapper needs a unique per-run temporary workdir before installing
# the EXIT trap. The child records all commands in the wrapper-owned log.
main "$@"
