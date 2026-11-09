# Admin/NGO Reinstatement Migration Validation

**Branch:** `feat/admin-ngo-reinstatement`
**Result:** Synthetic PostgreSQL 17 validation passed. No production database, Lovable project, deployment, or migration ledger was accessed or changed.

## Isolation evidence (recorded before database test results)

Docker Desktop was accessible (Engine `29.9.2`, aarch64). The PostgreSQL image was pinned by digest:

- `public.ecr.aws/supabase/postgres@sha256:b15d862126dd2dac02da524696ccfde2dcce2ceaee0a58973b2727befe492706`
- Image ID matched that digest; PostgreSQL reported `17.11` on aarch64.

The initial attempt used network `aihb-reinstate-internal-20261107-6d3ab9`; its `Internal=true`, IPv6 disabled, and only the disposable database and psql test runner were attached. A fresh retry used network `aihb-reinstate-internal-r2-20261107-e28f0c`; inspection reported `Internal=true`, `EnableIPv6=false`, bridge driver, and exactly five attached services: database, psql runner, GoTrue, PostgREST, and Kong.

For every fixture container, `HostConfig.PortBindings` was `{}`. PostgreSQL/PostgREST/Kong exposed container ports only; their `NetworkSettings.Ports` entries had no `HostPort`. The Node/Vitest test runner shared Kong’s network namespace, itself attached only to the internal network; it had no port bindings. No host port was used for any database or API connection. The full pre-cleanup inspection is preserved at `/private/tmp/aihb-reinstate-r2-20261107-e28f0c/evidence/final-docker-isolation-audit.txt`.

The first no-port fixture used:

- Network: `aihb-reinstate-internal-20261107-6d3ab9`
- Database container: `aihb-reinstate-db-20261107-6d3ab9`
- Runner: `aihb-reinstate-test-runner-20261107-6d3ab9`

The fresh retry used:

- Network: `aihb-reinstate-internal-r2-20261107-e28f0c`
- Database container: `aihb-reinstate-db-r2-20261107-e28f0c`
- Dedicated database volume: `aihb-reinstate-pgdata-r2-20261107-e28f0c`
- psql/pgTAP runner: `aihb-reinstate-test-runner-r2-20261107-e28f0c`
- GoTrue: `aihb-reinstate-auth-r2-20261107-e28f0c`
- PostgREST: `aihb-reinstate-rest-r2-20261107-e28f0c`
- Kong: `aihb-reinstate-kong-r2-20261107-e28f0c`
- Temporary work/evidence directory: `/private/tmp/aihb-reinstate-r2-20261107-e28f0c`

Before cleanup, Docker listed 74 containers (53 running), including 13 task-created containers. After removing only the exact task-created containers, three fixture volumes, and two fixture networks, inventory returned to **61 containers (46 running)**. Unrelated Docker resources were preserved. The downloaded Node image remains in the local image cache; no image was removed.

## Fresh fixture setup and baseline

The first isolated database attempt exposed an Auth-bootstrap mismatch: the PostgreSQL image alone supplied `auth.users.confirmed_at` but not the `email_confirmed_at` column used by the reviewed SQL suites. That suite stopped before any TAP assertions (`0 tests`); it did not identify a migration defect. A second, fresh disposable database was initialized, passed the no-published-port gate, and then ran the pinned GoTrue image on the same internal network. GoTrue applied 75 Auth migrations; read-only verification confirmed both `confirmed_at` and `email_confirmed_at`, with zero Auth users before the application baseline.

The image-created `supabase_auth_admin` and `authenticator` roles had no usable shared password for the local services. In the disposable database only, their passwords were set to the fixture’s random local database password so GoTrue and PostgREST could connect. This changed no role attributes, memberships, grants, or production settings. The temporary password/JWT files were removed after fixture cleanup.

The initial read-only baseline gate verified PostgreSQL 17.11, database `postgres`, platform roles/schemas, and absence of application tables, reinstatement RPC, pgTAP, and dblink before migration execution. The fixture was synthetic; its local July-to-October migration chain does not prove that production has the same complete state.

## Migration execution

Only the explicit reviewed set below was staged. Each source and staged copy matched the recorded SHA-256 manifest immediately before execution. Each file was run separately through `psql` with `ON_ERROR_STOP`; no Supabase CLI, broad migration-directory apply, `--single-transaction`, or migration-ledger edit was used. Native transaction boundaries were preserved. The six historical baseline files do not contain explicit `BEGIN`/`COMMIT`; the remaining transactional files retained their own statements.

1. `20260328173528_aa29a1fc-f82d-48f7-87ac-2c172ea6b335.sql`
2. `20260329060841_0d1febd4-8a8b-4e5d-bf8b-642971433cc6.sql`
3. `20260709051821_f5b004d5-8cda-4625-a3a2-55ad72b3a0aa.sql`
4. `20260710044655_8832d8b6-11fe-4347-a84c-dda4cda668aa.sql`
5. `20260710044723_94ee13bb-e711-42c5-9477-4dad9523dfa6.sql`
6. `20260710044743_4a976141-cf64-43f1-8b29-3f35f7d6d6ef.sql`
7. `20261018213000_secure_profile_roles.sql`
8. `20261018214500_profile_role_signup_hardening.sql`
9. `20261018220000_privacy_preserving_ngo_analytics.sql`
10. `20261019090000_admin_ngo_verification.sql`
11. `20261019095000_allow_reviewer_profile_deletion.sql`
12. `20261019100000_atomic_account_deletion.sql`
13. `20261019120000_harden_profile_insert_privileges.sql`
14. `20261027180000_least_privilege_profile_symptom_grants.sql`
15. `20261028100000_assert_profile_symptom_security_contract.sql`
16. `20261030151837_revoke_service_role_maintain_privilege.sql`
17. `20261101120000_prevent_admin_ngo_self_review.sql`
18. `20261107120000_admin_ngo_reinstatement.sql`

All 18 migrations completed successfully on the fresh retry. The admin/NGO migration’s runner evidence showed `session_user=supabase_admin`, direct superuser true; after `SET ROLE postgres`, `current_user=postgres` while the session login remained superuser. This satisfied its direct-session-superuser plus postgres-object-owner contract. The reinstatement migration ran as `session_user=current_user=postgres`, with `rolsuper=false`, `rolbypassrls=true`; its embedded preflight, transactional DDL, ACL checks, and postconditions all completed through `COMMIT`.

Only explicitly selected platform, baseline, and workflow migrations were used. Stage 3B, the alternative profile-role candidate, November 5 candidates, and unrelated repository migrations were excluded. The migration ledger was not created or modified.

## pgTAP and behavioral results

pgTAP `1.3.3` and dblink `1.2` were available in the image and installed only in the disposable database under `extensions`. The test session search path was `"$user", public, auth, extensions`.

| SQL suite | Assertions | Result |
|---|---:|---|
| `admin_ngo_reinstatement.sql` | 17 | PASS |
| `admin_ngo_privilege_contract.sql` | 9 | PASS |
| `admin_ngo_self_review.sql` | 8 | PASS |
| `profile_symptom_maintain_upgrade.sql` | 24 | PASS |
| `reviewer_account_deletion.sql` | 57 | PASS |
| **Total** | **115** | **PASS** |

Coverage included suspended-to-approved reinstatement, role restoration, mandatory reason validation and length, non-admin and self-review rejection, invalid status and stale-application rejection, audit preservation, exact function owner/SECURITY DEFINER/empty search path/EXECUTE ACL, account deletion, audit anonymization, symptom cascades, least-privilege API ACLs, PostgreSQL 17 `MAINTAIN`, RLS behavior, hostile `admin`/`ngo` signup metadata, and fail-closed analytics.

The actual `adminReinstatementConcurrency.integration.test.ts` passed in Vitest against internal Kong/PostgREST/GoTrue. It made two parallel RPC requests: exactly one succeeded and one received `P0002`; the final application was approved, the profile role was restored to `ngo`, and both the suspension and reinstatement audit events were observed before applicant cleanup. The runner used `http://127.0.0.1:8000` inside Kong’s shared internal network namespace; no host port was published.

Final read-only postconditions confirmed:

- All protected tables were owned by `postgres`; RLS remained enabled and `FORCE RLS` false.
- `reinstate_ngo_application(uuid,uuid,text)` was owned by `postgres`, PL/pgSQL, SECURITY DEFINER, with `search_path=""`.
- Effective and direct EXECUTE was restricted to the owner and `service_role`; no grant option or API-role EXECUTE remained.
- The validated audit action constraint included `ngo_application_reinstated` while preserving earlier actions.
- The aggregate fixture state after the integration cleanup was 1 synthetic reviewer Auth user/profile, 0 applications, and 2 retained synthetic audit rows. The entire database volume was then removed.

## Application validation

| Check | Result |
|---|---|
| `npm test` | PASS — 161 passed, 3 skipped (the two disposable Auth-signup cases and the opt-in reinstatement concurrency case; the concurrency case was separately run and passed above) |
| `npx tsc --noEmit` | PASS |
| `npm run lint` | PASS — 0 errors, 7 existing Fast Refresh warnings |
| `npm run build` | PASS — Browserslist/caniuse-lite freshness warning |
| `git diff --check` | PASS |

## Candidate hashes

| File | SHA-256 | Expected hash matched |
|---|---|---|
| `supabase/migrations/20261107120000_admin_ngo_reinstatement.sql` | `0feabe3030e30b08748a11538d130353ae1b9f72d15f868736a69cdf55ae1561` | Yes |
| `supabase/tests/admin_ngo_reinstatement.sql` | `ad1a8fc87f9b5eb5a0ff36cd75e0cc1fc86e5375412c41cdf6387999c641703e` | Yes |

The complete migration/test source manifest and command logs remain in `/private/tmp/aihb-reinstate-r2-20261107-e28f0c/evidence/`. The disposable fixture’s secret files were removed after Docker cleanup.

## Remaining risks and scope

- This validates the candidate against a synthetic PostgreSQL 17.11 Supabase-compatible baseline, not a copy of production. The observed production target must still pass the migration’s own live preflight under an authorized operator before application.
- The standard `npm test` run skips the separate disposable Auth-signup integration tests; they were not part of this task. The reinstatement concurrency integration test was run separately and passed.
- The suspension/reapplication policy was left unchanged: rejected applications may resubmit; suspended accounts require administrator reinstatement. This remains a product policy to confirm.
- No source migration or application file was changed during validation. This report was updated only; no commit, push, merge, deploy, or production operation occurred.

**Previous validation verdict (superseded by the follow-up below): READY FOR OWNER-APPROVED PRODUCTION APPLICATION, subject to the project owner’s separate target preflight and explicit approval.** It reflected synthetic validation of the previous migration/test versions only and did not claim production parity or production execution.

## Final pre-PR role-path correction — 2026-11-07

The earlier validation above applies to the prior migration/test hashes and does **not** validate the correction below. A static review found that the old membership guard rejected only an API `SET ROLE` path ending directly at `service_role`. That could miss an API-reachable intermediate role inheriting `service_role` EXECUTE.

This follow-up supersedes the earlier readiness verdict: the revised migration is not validated until the database checks below can be rerun.

The reinstatement migration now evaluates every acyclic `SET ROLE`-reachable role with `has_function_privilege(..., 'EXECUTE')` in both a pre-COMMIT effective-privilege gate and the independent postcondition. The gate runs after the RPC's final ACL is staged inside the migration's explicit transaction; any unsafe path raises before COMMIT and rolls back all migration changes. The early baseline preflight no longer treats the direct `service_role` path check as sufficient. This reuses the recursive traversal pattern already used by the Admin/NGO migration.

The pgTAP source now creates a rollback-scoped synthetic graph in which `authenticated` has SET-only membership in an intermediate NOLOGIN role, and that intermediate role inherits `service_role`. It asserts the bridge's effective RPC EXECUTE, that the authenticated root lacks direct effective EXECUTE, and that both the migration preflight predicate and postcondition predicate reject the graph. A source-level Vitest assertion checks the migration guards contain the recursive traversal and the SQL test covers this graph. These new database assertions have **not** been run.

### Follow-up validation status

- The current Codex shell's `docker info` failed with `permission denied` for `/Users/priyanshuranjan02/.docker/run/docker.sock`. The macOS Terminal app was visible but computer-use access was explicitly denied. No Docker inventory could be rechecked and no fixture/resource was created or changed during this follow-up.
- No SQL, migration, pgTAP, or concurrency test was executed for the revised migration. The earlier 115 TAP assertions and earlier concurrency result apply only to the previous migration/test versions; they are not evidence for this correction.
- The new pgTAP regression contains a test-only copy of the effective-privilege predicate and asserts its expected preflight/postcondition errors. It does not execute the migration's anonymous `DO` blocks. A true negative migration-application test still requires a separate fresh database with the unsafe membership graph installed before applying the migration; that test was not run.
- `npm test`: PASS — 162 passed, 3 skipped. The skipped tests include the opt-in concurrency integration test, which was not rerun for this revision.
- `npx tsc --noEmit`: PASS.
- `npm run lint`: PASS — 0 errors, 7 existing Fast Refresh warnings.
- `npm run build`: PASS — stale Browserslist/caniuse-lite data warning.
- `git diff --check`: PASS for tracked changes; a separate trailing-whitespace scan also passed for the new/untracked migration, SQL test, Vitest file, and report.

The SQL test now contains a disposable role-creation/membership setup and rollback cleanup. Until that test and the complete selected migration sequence run on a newly identity-verified internal-only PostgreSQL 17.11 fixture, the revised database behavior remains unvalidated and this branch must not be treated as ready for production application.

**Status at that point: NOT READY (historical; superseded by the successful 2026-11-09 validation recorded below).** The revised database migration, SQL regression suite, and concurrency behavior still require execution on a fresh isolated fixture.

## Submission/reinstatement serialization follow-up — 2026-11-08

This section records the current race-condition correction separately from the historical validation above. The historical PostgreSQL/pgTAP and application results apply to the source hashes listed in that earlier run; they do **not** validate the serialization changes or the new deterministic two-order test described here.

The candidate migration now uses the applicant profile row as the shared serialization lock for submission, review, and reinstatement. Each workflow acquires that row before locking or inserting application rows. Submission re-reads the profile role after obtaining the lock. Reinstatement obtains the same profile lock before locking/revalidating the suspended application and checking which application is latest. Those checks require READ COMMITTED so a statement after a lock wait gets a fresh snapshot. The new shell integration test installs synthetic database barriers and observes PostgreSQL lock-wait states to force both orderings; it does not rely on arbitrary sleeps to establish ordering. The test asserts final profile/application states, audit events, and absence of partial submissions/reinstatements, then removes only its own synthetic fixtures.

### Static validation and source identity

- `/bin/bash` used for syntax checking is Bash 3.2.57; the host validation script passed `bash -n`.
- `sh -n supabase/tests/admin_ngo_submission_reinstatement_concurrency.sh`: PASS.
- `AIHB_VALIDATION_FATAL_SELF_TEST=1 /bin/bash ./validate-admin-ngo-reinstatement-host.sh`: PASS. This covered Auth diagnostic redaction, fatal-exit/EXIT-trap injection, and four scoped cleanup failure-injection cases. It did not invoke Docker or PostgreSQL.
- All 25 entries in the host script's exact source manifest matched their SHA-256 values.
- Trailing-whitespace scan across 15 changed/untracked files: PASS.
- `git diff --check`: PASS.

Current hashes:

| File | SHA-256 |
|---|---|
| `supabase/migrations/20261107120000_admin_ngo_reinstatement.sql` | `1b2129ad9e93443f3d7caed40530a0cca7c1fca2bf6db66330b811249f91c1e4` |
| `supabase/tests/admin_ngo_reinstatement.sql` | `784c40ee7324c3d602557547fab8a2a916b6456d22e98bb312cc27e229894360` |
| `supabase/tests/admin_ngo_submission_reinstatement_concurrency.sh` | `948ea0eefe64f344d20773f33252d56143210abc975d28b739fcc72d5fccf0f5` |
| `validate-admin-ngo-reinstatement-host.sh` | `e3b1ed1c84da2ae5c3630f8e841451b8b18e6e68fc7ccf39d2598275f177a6b5` |

### Latest validation attempt and blocker

Before creating any resources, `docker --context desktop-linux info` was attempted from the Codex execution environment. Docker returned:

`permission denied while trying to connect to the docker API at unix:///Users/priyanshuranjan02/.docker/run/docker.sock`

The validation harness was not started. No Docker inventory was taken in this attempt, no containers/volumes/networks were created or changed, and no PostgreSQL connection, migration, pgTAP suite, concurrency integration, Vitest, TypeScript, lint, or build command was run for these revised sources. Consequently, neither deterministic race ordering is yet runtime-validated. The prior failed host attempt also does not validate this corrected race script.

The existing fail-closed host harness is the authorized next step and must be run from the user's normal macOS Terminal, where Docker Desktop access is available:

```bash
cd /private/tmp/ai-healthbot-admin-ngo-reinstatement
/bin/bash ./validate-admin-ngo-reinstatement-host.sh
```

Return the complete timestamped log path and its final success/failure section. Do not treat a partial run, a skipped test, or a cleanup failure as passing. On completion, append that run's actual resource inspection, both race outcomes, migration/SQL/application results, hashes, and before/after inventory evidence here without erasing the historical records above.

**Status at that point: NOT READY (historical; superseded by the successful 2026-11-09 validation recorded below).** The race correction has passed static checks only. Synthetic runtime validation, all SQL suites, the existing migration rollback/postcondition regressions, concurrency integration, application checks, and cleanup/inventory restoration must all pass on a fresh isolated fixture before final review. No production access, commit, push, merge, PR, or deployment occurred.

## Reviewer audit assertion and final full rerun — 2026-11-09

This addendum preserves the earlier failed-run history and records the corrected, successful full validation. It supersedes the prior follow-up status for synthetic validation only; it does not establish production parity.

### Root cause of reviewer assertion 39

`reviewer_account_deletion.sql` originally counted every anonymized `ngo_application_submitted` audit row with empty details. After the deterministic race test, the submission-wins scenario legitimately creates such an event; deletion of its synthetic applicant retains and anonymizes that audit row. The reviewer-deletion fixture then creates and anonymizes its own submission event. The broad query therefore saw two legitimate rows while the fixture-specific expectation was one. The extra event was not duplicate or orphaned data, and no audit event should be deleted.

The failed `20261108235350` run did not log the submitted-event UUIDs, so those identifiers cannot be recovered from that run. The fresh successful rerun records both rows precisely:

- **Concurrent submission event:** audit UUID `0a212201-b7c9-4b45-afe3-d2b79eeaf5e5`, action `ngo_application_submitted`. Before applicant cleanup: actor/target `a0015b45-fcb8-4ce0-8d95-032e18fa4d28`, application `0c5fb1c9-fb94-4d9b-ad90-d2db5b4e906c`, details `{"organization_name":"Synthetic concurrent submission"}`, not anonymized. After cleanup: same audit UUID/action; actor, target, and application references NULL; details `{}`; `anonymized_at` set. This is the retained concurrency event that made a global count equal two.
- **Applicant-deletion test event after concurrency:** audit UUID `773c5306-06cc-410e-a481-61dd20adf083`, action `ngo_application_submitted`. Before deletion: actor/target `52e5242c-1b5b-45ff-ae34-31f6127f58db`, application `bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1`, details `{"synthetic":true}`, not anonymized. After deletion: same audit UUID/action; all three references NULL; details `{}`; `anonymized_at` set.

The test now captures its fixture-generated audit UUID immediately after insertion and asserts retention/anonymization against that exact UUID and its expected pre-delete references. It snapshots pre-existing anonymized NGO submission/review events, emits before/after IDs and available references, and verifies those rows are unchanged. The six pre-existing anonymized events from the successful run were one submitted event (`0a212201-b7c9-4b45-afe3-d2b79eeaf5e5`), three suspended events (`319405d8-a7da-4819-a961-5dcb173735f7`, `359a07f0-f25b-44b1-a8dc-1e4a9d11be8c`, `443f5272-bd22-4ffa-90f1-467b07c652bb`), and two reinstated events (`1c2697ba-b826-463e-aaa7-e6b30fedcade`, `539c3519-6549-4907-9fc8-9f025533ed30`). The SQL suite verified their IDs, actions, NULL references, empty details, and anonymization timestamps remained unchanged.

### Intermediate failed validation attempts

- Log `validation-20261109T000510-0a0aca37f3.log` (run `20261109000510-6e506c9eb069`) verified the race orderings and reviewer audit correction, including reviewer suite 58/58 after concurrency. It then exposed a stale SQL test expectation for the deliberately generic `P0002` non-eligibility message. The SQLSTATE remained `P0002`; the test expectation was corrected to the migration's non-disclosing error text. Cleanup and baseline inventory restoration passed.
- Log `validation-20261109T000655-2714f6aee5.log` (run `20261109000655-bd3557a13404`) passed the SQL suites and audit-order checks, then exposed a Vitest source-order assertion that searched the migration preflight text rather than the actual RPC body. The test now slices the `reinstate_ngo_application` definition and checks profile lock, role check, application lock, latest-order check, self-review check, and update order there. Cleanup and baseline inventory restoration passed.

### Final successful isolated run

- Run ID: `20261109000854-7cc1cd52f11e`
- Complete log: `/private/tmp/aihb-admin-ngo-validation-logs/validation-20261109T000854-8920220ddd.log`
- PostgreSQL: 17.11, aarch64, on the pinned Supabase image digest.
- Pre-run and post-cleanup Docker inventories: 61 containers, 19 images, 19 networks, 40 volumes. The same inventory comparison passed; only this run's labeled fixture containers, two volumes, and internal network were removed. No pre-existing container, volume, or network was removed or modified.
- Internal Docker network was verified `Internal=true`, IPv6 disabled. All fixture containers had empty host port bindings and were attached only to the dedicated internal network before database connections.
- All 18 explicitly selected baseline/workflow migrations were applied to the clean synthetic database. The actual reinstatement migration rejected the unsafe intermediate-role graph with the expected preflight error and rolled back; the independent postcondition regression separately confirmed the postcondition rejects an unsafe reachable-role graph. The clean database migration committed and final read-only postconditions passed.
- Existing simultaneous reinstatement integration: 1/1 passed.
- Deterministic submission/reinstatement barrier test: both orderings passed. Submission-first committed the new pending application and caused stale reinstatement to reject with `P0002`; reinstatement-first approved the suspended application, restored profile role `ngo`, and caused later submission to reject with `42501`. Final state and audit assertions passed for both.
- Reviewer deletion suite: 58/58 standalone; 58/58 after the concurrency integration; 58/58 after each of the four preceding SQL suites; and 58/58 in the final ordered run. Its exact audit-ID retention/anonymization assertion and pre-existing audit preservation assertion passed each time.
- Final ordered pgTAP suites: `admin_ngo_reinstatement.sql` 21/21; `admin_ngo_privilege_contract.sql` 9/9; `admin_ngo_self_review.sql` 8/8; `profile_symptom_maintain_upgrade.sql` 24/24; `reviewer_account_deletion.sql` 58/58. **Final ordered total: 120/120.** Repeated reviewer contamination checks are additional executions, not included in that total.
- Vitest: 162 passed, 3 skipped. The disposable Auth-signup cases (2) and opt-in reinstatement concurrency case (1) were skipped by the ordinary `npm test` run; the concurrency case was separately run and passed 1/1. Skips are not counted as passes.
- `npx tsc --noEmit`: PASS.
- `npm run lint`: PASS, 0 errors and 7 warnings.
- `npm run build`: PASS (Browserslist/caniuse-lite freshness warning; build output isolated under the run directory).
- Source hash gate: all 26 manifest entries matched. Static Bash/sh syntax, failure-injection tests, source whitespace scan, and `git diff --check` passed.
- Harness final status: `SUCCESS: all required disposable validation, regression, application, and cleanup checks passed. Synthetic fixture evidence only; not production parity.`

### Current source hashes

| File | SHA-256 |
|---|---|
| `supabase/migrations/20261107120000_admin_ngo_reinstatement.sql` | `1b2129ad9e93443f3d7caed40530a0cca7c1fca2bf6db66330b811249f91c1e4` |
| `supabase/tests/admin_ngo_reinstatement.sql` | `e25377aaa0f40126c35e673387dcecb3c3eeb6f2808de15370a7b9a6f59fe678` |
| `supabase/tests/reviewer_account_deletion.sql` | `9f7f1daba447ab004856275ba70b7674eba72cf0eb80ddefe479d213e79a3855` |
| `supabase/tests/admin_ngo_submission_reinstatement_concurrency.sh` | `0c96037267e5932073ef7a1d5ee55c11eb0d8515236e6992fafccf9a70ec1ea0` |
| `src/test/adminReinstatementSecurity.test.ts` | `d0a16178703b3213d7f1d05c15126776450a973cd0f702942116bea16320aa7e` |
| `validate-admin-ngo-reinstatement-host.sh` | `bac01e982e29e5a2fecfa57fca6edbd3c1114677c6be7cac7805cd6d6e022a0e` |

**Current synthetic-validation verdict: PASS.** This result is confined to the disposable PostgreSQL 17.11 fixture. It does not establish production parity or authorize production migration application. No commit, push, merge, PR, or deployment occurred.


### Post-run harness log-label correction

A final static audit confirmed that the host harness staged and verified 26 manifest entries in the successful run. Its progress text still said “All 25” from the earlier manifest size; the displayed manifest and independent hash audit both covered all 26 entries. The message was changed to say “all manifest-listed source files,” without changing validation behavior. The current script hash above reflects that wording-only correction. Bash syntax, fatal/log-redaction/cleanup self-tests, all 26 manifest hashes, whitespace scan, and `git diff --check` were rerun afterward and passed. The completed full host run remains recorded at `/private/tmp/aihb-admin-ngo-validation-logs/validation-20261109T000854-8920220ddd.log`; its source/runtime behavior was identical apart from the corrected progress-text wording.

## Latest exact-script attempt — Docker access blocked (2026-11-09)

This is the current attempt for the evidence and consistency corrections above. It supersedes earlier readiness claims for the current worktree sources: the complete host validation did **not** reach Docker inventory or database validation in this execution environment.

- Branch: `feat/admin-ngo-reinstatement`; HEAD remains `a0f7782ec17661b6bc503e4786e2e2ed11a7d582`.
- Run ID: `20261109T115000-4419af909d22`.
- Log: `/private/tmp/aihb-admin-ngo-validation-logs/validation-20261109T115000-4419af909d22.log`.
- Preserved exact executed script: `/private/tmp/aihb-admin-ngo-validation-logs/validate-admin-ngo-reinstatement-host-20261109T115000-4419af909d22.sh`.
- Original and saved/executed script SHA-256: `59de0a0fc47bef4c74976e880125f3fd253032bc60dd3372507fc6c9d2be0055`; byte comparison passed (`cmp` exit 0).
- Log SHA-256: `79481f0cecf729f9b9abf51531f63353d12b201086ded817326ad059928dbd03`.
- Exact blocker: Docker API access to `unix:///Users/priyanshuranjan02/.docker/run/docker.sock` failed with `permission denied`. The harness exited nonzero before taking inventory or creating resources. Its scoped cleanup ran with no fixture resources recorded.
- Docker Desktop inspection from the computer-use interface was also denied by the environment's app-access policy. I did not attempt a permission change, elevated command, alternative Docker endpoint, or cleanup workaround.

### Corrections present in the current source

- The host harness preserves and hashes the exact executed script before validation, then refuses to proceed unless original and preserved bytes match.
- The source manifest now contains 27 approved inputs, including `src/test/ngoDashboard.test.tsx`; all manifest hashes matched in Docker-free verification.
- Suspended NGO dashboard copy directs applicants to contact an administrator for reinstatement review and does not imply self-service reinstatement.
- `reviewer_account_deletion.sql` snapshots all five relevant NGO audit actions, including approved and rejected, and retains exact fixture-owned audit UUID assertions. Its current SHA-256 is `5d480eeef15e57b7853ecb0041192eb2fa0d8c6bb8c9d0c1fa05491d62e8ef50`.

### Docker-free checks for the current sources

- Bash 3.2 syntax check (`/bin/bash -n`): PASS.
- Deterministic concurrency shell syntax (`sh -n`): PASS.
- Harness fatal/log-redaction and cleanup failure-injection self-tests: PASS, run `20261109T114951-a9a54a658979`; these tests do not start Docker or connect to PostgreSQL.
- Source manifest: all 27 hashes PASS.
- Temporary source snapshot simulation: 183 entries copied; all 17 modified/untracked deliverable paths, including the Dashboard test, were present and verified. The temporary snapshot was removed.
- Whitespace scan across the 17 modified/untracked paths: PASS; `git diff --check`: PASS.
- `npm test`: PASS, 162 passed and 3 skipped. The skipped tests are not counted as passes; the optional live Auth signup cases and reinstatement concurrency case were not run in this ordinary test invocation.
- `npx tsc --noEmit`: PASS.
- `npm run lint`: PASS, zero errors and seven warnings.
- `npm run build`: PASS; output was directed to and removed from a temporary path. Existing Browserslist freshness and out-of-tree-output notices were reported.

These application checks do not replace the missing database run. No PostgreSQL version, fixture identity, migration preflight/application, pgTAP totals, migration rollback/postcondition behavior, SQL suites, concurrency integration, or Docker before/after inventory can be claimed for the current source revision.

### Current relevant hashes

| File | SHA-256 |
|---|---|
| `validate-admin-ngo-reinstatement-host.sh` | `59de0a0fc47bef4c74976e880125f3fd253032bc60dd3372507fc6c9d2be0055` |
| `supabase/migrations/20261107120000_admin_ngo_reinstatement.sql` | `1b2129ad9e93443f3d7caed40530a0cca7c1fca2bf6db66330b811249f91c1e4` |
| `supabase/tests/admin_ngo_reinstatement.sql` | `e25377aaa0f40126c35e673387dcecb3c3eeb6f2808de15370a7b9a6f59fe678` |
| `supabase/tests/reviewer_account_deletion.sql` | `5d480eeef15e57b7853ecb0041192eb2fa0d8c6bb8c9d0c1fa05491d62e8ef50` |
| `src/pages/Dashboard.tsx` | `653ea6b1c00a18bedc3224d6bafb762605f5af150f169546d4a36eb23f828977` |
| `src/test/ngoDashboard.test.tsx` | `ce321cdd474f2022517bf7a62bab056b293bee432d622f4f5b362bf9914b4726` |

**Status at that point: NOT READY (historical; superseded by the successful 2026-11-09 validation recorded below).** The new exact-script mechanism and Docker-free checks passed, but full isolated PostgreSQL validation is blocked until the script can be run from a host Terminal with Docker socket access. No production or staging access, database operation, fixture creation, commit, push, merge, PR, or deployment occurred. All changes remain uncommitted.

## Negative-fixture role-name correction and retry — 2026-11-09

### Diagnosis

Run `20261109T120127-f5718bb86a5e` failed before the intended negative migration application. Its preserved script and the then-current script were byte-identical at SHA-256 `59de0a0fc47bef4c74976e880125f3fd253032bc60dd3372507fc6c9d2be0055`.

The shell derived `BRIDGE` with `${PREFIX//-/_}_bridge`, producing `aihb_reinstate_20261109T120127_f5718bb86a5e_bridge`. `CREATE ROLE` and both `GRANT` statements used that unquoted identifier, which PostgreSQL folds to lowercase (`...20261109t...`). The following DO block interpolated the original mixed-case spelling into a quoted text value cast to `regrole`; that lookup is case-sensitive and could not resolve the lowercased catalog role. The same spelling mismatch also affected the independent postcondition graph and cleanup SQL. The migration was not reached, so this was a fixture harness failure, not a migration rejection or defect.

### Harness correction

The harness now derives one deterministic bridge identifier by replacing separators and lowercasing the complete identifier using `tr`, compatible with macOS Bash 3.2. It validates the result against PostgreSQL's unquoted identifier character/length constraints, logs the safe synthetic identifier, and uses the same value in role creation, membership grants, catalog lookup, recursive postcondition checks, revokes, and role cleanup. The negative preflight check and independent postcondition check now explicitly confirm that the bridge, `authenticated`, and `service_role` exist before membership predicates run; a missing role fails with a specific diagnostic. The intermediate membership chain and both actual migration/postcondition regressions are retained unchanged in intent.

The failed run's expected role spelling now normalizes to `aihb_reinstate_20261109t120127_f5718bb86a5e_bridge`. Static comparison confirmed the source correction; the preserved failed-run script remains unchanged.

### Static checks and full-run attempt

- `/bin/bash` is GNU Bash `3.2.57` on macOS; `bash -n`: PASS.
- `sh -n supabase/tests/admin_ngo_submission_reinstatement_concurrency.sh`: PASS.
- Harness diagnostic-redaction, fatal-exit, and cleanup failure-injection checks: PASS (run `20261109T120802-ee7d6fbed1ef`; no Docker/database access).
- All 27 approved source-manifest hashes: PASS.
- Exact application source-snapshot routine: PASS, 183 entries; changed/untracked task files were represented; all 27 approved migration/test inputs matched. Snapshot was created under a temporary directory and removed.
- Whitespace scan and `git diff --check`: PASS.

The requested full harness run was attempted after the correction:

- Run ID: `20261109T120837-3412ccc400f2`.
- Log: `/private/tmp/aihb-admin-ngo-validation-logs/validation-20261109T120837-3412ccc400f2.log`.
- Preserved executed script: `/private/tmp/aihb-admin-ngo-validation-logs/validate-admin-ngo-reinstatement-host-20261109T120837-3412ccc400f2.sh`.
- Original and saved/executed script SHA-256: `d1d071da2d1f4b08c54eeb570b02154df660edf978e76385db2abde2402850a8`; byte-for-byte comparison passed.
- It stopped at the Docker daemon gate with `permission denied` for `unix:///Users/priyanshuranjan02/.docker/run/docker.sock`, before Docker inventory or fixture creation. The exit was nonzero and scoped cleanup ran with no fixture resources recorded.

Accordingly, the corrected negative migration test, independent recursive postcondition regression, concurrency orderings, SQL suites, and cleanup/inventory restoration have **not** been rerun on this correction. Earlier successful SQL/application results in this report refer to earlier revisions and are not evidence for the current full validation. The preceding separate application run had 162 tests pass and 3 skip, TypeScript/build pass, and lint pass with seven warnings; those checks predate this harness-only role-name correction.

### Current hashes and verdict

- `validate-admin-ngo-reinstatement-host.sh`: `d1d071da2d1f4b08c54eeb570b02154df660edf978e76385db2abde2402850a8`.
- `supabase/tests/reviewer_account_deletion.sql`: `5d480eeef15e57b7853ecb0041192eb2fa0d8c6bb8c9d0c1fa05491d62e8ef50`.
- `supabase/migrations/20261107120000_admin_ngo_reinstatement.sql`: `1b2129ad9e93443f3d7caed40530a0cca7c1fca2bf6db66330b811249f91c1e4`.
- `supabase/tests/admin_ngo_reinstatement.sql`: `e25377aaa0f40126c35e673387dcecb3c3eeb6f2808de15370a7b9a6f59fe678`.

**Status at that point: NOT READY (historical; superseded by the successful 2026-11-09 validation recorded below).** The role-name defect is corrected and static checks pass, but full synthetic PostgreSQL validation remains pending until the harness runs from an environment with authorized Docker Desktop socket access. No production/staging access, commit, push, merge, PR, or deployment occurred; all work remains uncommitted.

### Cleanup evidence for the role-name failure run

The earlier fixture run `20261109T120127-f5718bb86a5e` had a Docker inventory snapshot before setup and after scoped cleanup. Both were identical: **61 containers, 19 images, 19 networks, 40 volumes**. Its log reports that only run-labeled fixture containers, the two run-specific volumes, and the run-specific internal network were removed; the inventory check passed. The later corrected-script attempt `20261109T120837-3412ccc400f2` stopped at Docker daemon access before inventory or resource creation, so it had no fixture resources to clean up and provides no new inventory comparison.


## Latest synthetic validation status — 2026-11-09

**Latest validation result: PASS for the isolated synthetic validation scope.** This run supersedes the earlier Docker-blocked and failed attempts recorded above. Those entries remain as historical records; their former “current” labels have been changed to identify them as status at that point in time. This result does not establish production parity, production testing, deployment, release approval, or production readiness.

### Run identity and integrity

- Run ID: `20261109T124743-2aa63d53e79f`
- Date: `2026-11-09`
- Validation log: `/private/tmp/aihb-admin-ngo-validation-logs/validation-20261109T124743-2aa63d53e79f.log`
- Preserved executed script: `/private/tmp/aihb-admin-ngo-validation-logs/validate-admin-ngo-reinstatement-host-20261109T124743-2aa63d53e79f.sh`
- Original, preserved, and current validation script SHA-256: `d1d071da2d1f4b08c54eeb570b02154df660edf978e76385db2abde2402850a8`
- Validation log SHA-256: `2879b10bf598d9982616d566a4b8b7922a136c42241481f1eeed8a131f4efe35`
- The log records the exact-script comparison, all 27 approved migration/test source inputs matched, and the final success marker.

### Database and security results

- PostgreSQL `17.11` on `aarch64-unknown-linux-gnu` was verified in both disposable databases.
- The unsafe API-reachable intermediate-role graph was rejected by the actual reinstatement migration with the expected `An API role can SET ROLE to a role that executes the reinstatement RPC` preflight error. The failed application rolled back; the reinstatement RPC remained absent and the original audit-action constraint remained unchanged in the negative fixture.
- The independent post-migration regression introduced the unsafe graph after a successful migration and confirmed that the recursive reachable-role postcondition rejected it. This is separate from the actual migration preflight test.
- The clean fixture migration committed, and migration postconditions passed. Final read-only evidence verified the RPC owner is `postgres`, it is PL/pgSQL `SECURITY DEFINER`, has an empty `search_path`, and EXECUTE is false for `anon` and `authenticated` and true for `service_role`. The reinstatement audit-action constraint includes the new action.
- Both deterministic submission/reinstatement serialization orderings passed. The existing simultaneous reinstatement integration test passed `1/1`.
- The five final SQL suites passed `120/120` assertions: reinstatement `21/21`, privilege contract `9/9`, self-review `8/8`, profile/symptom maintenance `24/24`, and reviewer account deletion `58/58`.
- Reviewer deletion additionally passed `58/58` standalone, after the concurrency integration, after each of the four preceding SQL suites, and in the final ordered suite. Its fixture-specific audit UUID `a296080c-b1f8-488e-904a-9b120cb020ac` remained after applicant deletion with actor, target, and application references cleared, details anonymized, and `anonymized_at` set. The assertion also confirmed that pre-existing anonymized concurrency events remained present and unchanged, including IDs `3aa41e2b-a40a-419b-98c1-8610d64d768f`, `65436c49-0865-4f2d-b266-7c07f8a6c225`, `86aeedab-33af-4f9f-b695-b8bf750bcb40`, `adaae366-d038-4eed-9a91-d794dd5e1e27`, `926b28f9-dea5-42b0-b0e1-4e941f1f4c9c`, and `cab0f773-8181-4495-b6da-274172137ec7`. The recorded concurrency audit output showed the appropriate anonymized references as NULL and details as `{}`.

### Application and cleanup results

- Vitest: `162 passed`, `3 skipped` (`165` total). Skipped tests are not counted as passing. The opt-in reinstatement concurrency integration separately passed `1/1`.
- `npx tsc --noEmit`: PASS.
- `npm run lint`: PASS, `0 errors` and `7 warnings`.
- `npm run build`: PASS.
- `git diff --check` and the harness whitespace scan: PASS.
- The fixture used an internal-only network and no host-published ports. Docker inventory was `61 containers, 19 images, 19 networks, 40 volumes` both before and after. The run-labeled containers, volumes, and network were removed; the log confirms pre-existing Docker resources were preserved.
- The log ends with: `SUCCESS: all required disposable validation, regression, application, and cleanup checks passed. Synthetic fixture evidence only; not production parity.`

### Non-blocking test-hardening follow-up

The final review noted that the `finally` block in `src/test/adminReinstatementConcurrency.integration.test.ts` does not explicitly fail if `client.auth.admin.deleteUser(applicantId)` returns an error. This is a low-priority, non-blocking test-hardening follow-up and was not changed in this documentation-only update. The recorded run's synthetic audit output showed the fixture applicant's retained audit event was anonymized successfully.

### Scope and release status

This evidence is limited to the named disposable synthetic PostgreSQL 17.11 fixtures and local application checks. It does not establish production schema parity, production database behavior, deployment, administrator provisioning, or release approval. No production or staging database was accessed, and no commit, push, merge, PR, or deployment is claimed.
