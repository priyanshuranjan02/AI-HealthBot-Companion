# Administrator provisioning and signup-trigger operations

Public administrator registration is disabled. Public signup must never
assign an administrator role, and `profiles.role` must never be used to grant
administrator privileges. Profile roles are separate from the `admin` role
stored in `public.user_roles`.

## Initial administrator provisioning — project-owner operation

The approved initial provisioning process is out of band and may be performed
only by the project owner in Lovable Cloud → View Backend → SQL Editor:

1. The intended administrator creates a standard account through the existing
   authentication workflow. Do not use a special signup mode or accept a
   client-supplied role as authorization.
2. The project owner independently verifies the account holder's identity
   using the approved identity-verification process and locates that account
   in the trusted Auth user list. Copy its Auth user UUID directly from that
   trusted interface; do not take the UUID from the applicant or a browser
   request.
3. Before granting access, confirm the UUID identifies the verified Auth
   account and that the corresponding `public.profiles.id` exists. The Auth
   UUID and profile ID must match exactly. If either check fails or the
   identity is uncertain, stop without assigning the role.

   As project owner, this read-only check confirms both records exist for the
   UUID copied from the trusted Auth interface; it does not replace identity
   verification:

   ```sql
   SELECT
     EXISTS (SELECT 1 FROM auth.users WHERE id = '<AUTH_USER_UUID>'::uuid) AS auth_user_exists,
     EXISTS (SELECT 1 FROM public.profiles WHERE id = '<AUTH_USER_UUID>'::uuid) AS profile_exists;
   ```

   Proceed only when both results are `true` and the Auth UUID independently
   matches the verified account.

4. As the project owner, open **Lovable Cloud → View Backend → SQL Editor** and
   execute the approved statement below, substituting only the independently
   verified Auth UUID:

```sql
INSERT INTO public.user_roles (user_id, role)
VALUES ('<AUTH_USER_UUID>', 'admin')
ON CONFLICT (user_id, role) DO NOTHING;
```

5. Verify the exact `user_roles` row for that UUID in the SQL Editor. Lovable
   Cloud backend engine query logs are the audit evidence for this out-of-band
   operation. Do not represent it as an `admin_audit_log` NGO event.
6. The provisioned administrator signs in through `/admin/login`. Confirm the
   admin workflow is available to that account and remains unavailable to an
   ordinary account.

The `ON CONFLICT (user_id, role) DO NOTHING` clause makes a repeated execution
of the approved insert idempotent. The SQL Editor operation is project-owner
only; it is not available to public users or ordinary authenticated accounts.

This is initial, out-of-band provisioning. No in-app administrator delegation
or role-management workflow exists. Any future in-app delegation must be
separately approved and must define its own backend authorization and audit
contract. Do not add a public bootstrap endpoint or promote an account
automatically.

## Signup-trigger checks

Run the following read-only catalog queries through an authorized platform
operator session. Do not enable or alter the trigger as part of these checks.

```sql
SELECT
  t.tgname,
  t.tgenabled,
  pg_get_triggerdef(t.oid) AS trigger_definition
FROM pg_trigger AS t
WHERE t.tgrelid = 'auth.users'::regclass
  AND t.tgname = 'on_auth_user_created'
  AND NOT t.tgisinternal;
```

Expected: exactly one row; `tgenabled = 'O'` for normal operation; the
definition calls `public.handle_new_user()`.

```sql
SELECT
  p.oid::regprocedure AS function_name,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  p.proconfig AS function_settings,
  pg_get_functiondef(p.oid) AS definition
FROM pg_proc AS p
WHERE p.oid = 'public.handle_new_user()'::regprocedure;

SELECT
  has_function_privilege('anon', 'public.handle_new_user()', 'EXECUTE')
    AS anon_can_execute,
  has_function_privilege('authenticated', 'public.handle_new_user()', 'EXECUTE')
    AS authenticated_can_execute;
```

Expected: a trusted database/platform owner (not an API role),
`security_definer = true`, a safe empty search path (`search_path=""`), and
both API-role EXECUTE checks false. The function body should insert only the
Auth UUID and full name into `public.profiles`; it must not use role metadata.

A read-only check can detect existing Auth rows without profiles, but cannot
prove that a future signup fires the trigger. Prove behavior only in a fresh,
disposable local Supabase database: create test accounts with `admin` and
`ngo` signup metadata, then verify the trigger created profiles with role
`user`. Do not create test accounts in the live project for this purpose.

The local history creates the trigger in migration
`20260329060841_0d1febd4-8a8b-4e5d-bf8b-642971433cc6.sql`; later migrations
revoke API-role EXECUTE permission and replace the function with an empty
search path. Those changes do not enable a trigger that has separately been
disabled. If the remote trigger is disabled, only an authorized owner of
`auth.users` may restore it after reviewing the function and ownership.

The October 18 worktree path separates profile/signup hardening from the
analytics RPC. `20261018214500_profile_role_signup_hardening.sql` performs the
signup and profile-role preflight, removes the own-profile INSERT policy and
authenticated table INSERT grant, validates existing role data, and installs
the `user`/`ngo` constraint and hardened signup function. It precedes
`20261018220000_privacy_preserving_ngo_analytics.sql`, which now creates only
the fail-closed analytics RPC and its execution ACL. The split avoids applying
profile/signup changes as a side effect of installing analytics. The later
`20261019120000_harden_profile_insert_privileges.sql` is additional defense in
depth: it checks the same trusted signup dependency, removes remaining PUBLIC
and anon table/column INSERT paths, installs its guard trigger, and fails if a
`FOR ALL` policy needs explicit reconciliation. Do not apply this path together
with a separate production-baseline migration that installs a different guard
trigger or expects the original INSERT policy to still exist.

## Security migration release checks

Run these checks read-only, as an authorized owner, against the independently
verified project. Do not treat an empty result or permission error as proof an
object is absent. Do not query profile rows, health records, evidence contents,
or user identifiers as part of this catalog review.

### Migration ledger

First check whether the ledger exists and what columns it has:

```sql
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_name = 'schema_migrations';

SELECT table_schema, table_name, column_name, data_type
FROM information_schema.columns
WHERE table_name = 'schema_migrations'
ORDER BY table_schema, ordinal_position;
```

Only if `supabase_migrations.schema_migrations` is present with `version` and
`name` columns, inspect these versions:

```sql
SELECT version, name
FROM supabase_migrations.schema_migrations
WHERE version IN (
  '20261018213000', '20261018214500', '20261018220000',
  '20261019090000', '20261019095000', '20261019100000',
  '20261019120000', '20261027180000', '20261028100000',
  '20261029120000', '20261030151837', '20261031120000',
  '20261031130000', '20261101120000', '20261101130000'
)
ORDER BY version;
```

Compare the ledger with object definitions and provenance. A missing record
does not establish that its SQL did not run; do not manually add a record.
`20261018213000_secure_profile_roles.sql` is part of the selected migration
history. The remaining selected security migrations form this feature branch's
full-feature migration layer. The sequence starts from the six selected
March/July baseline files, in order:
`20260328173528_aa29a1fc-f82d-48f7-87ac-2c172ea6b335.sql`,
`20260329060841_0d1febd4-8a8b-4e5d-bf8b-642971433cc6.sql`,
`20260709051821_f5b004d5-8cda-4625-a3a2-55ad72b3a0aa.sql`,
`20260710044655_8832d8b6-11fe-4347-a84c-dda4cda668aa.sql`,
`20260710044723_94ee13bb-e711-42c5-9477-4dad9523dfa6.sql`, and
`20260710044743_4a976141-cf64-43f1-8b8b-642971433cc6.sql`. The October
feature layer then runs in this order:
`20261018213000_secure_profile_roles.sql`,
`20261018214500_profile_role_signup_hardening.sql`,
`20261018220000_privacy_preserving_ngo_analytics.sql`,
`20261019090000_admin_ngo_verification.sql`,
`20261019095000_allow_reviewer_profile_deletion.sql`,
`20261019100000_atomic_account_deletion.sql`, then
`20261019120000_harden_profile_insert_privileges.sql`,
`20261027180000_least_privilege_profile_symptom_grants.sql`,
`20261028100000_assert_profile_symptom_security_contract.sql`, and then
`20261030151837_revoke_service_role_maintain_privilege.sql`. The final selected
migration is `20261101120000_prevent_admin_ngo_self_review.sql`, a forward-only
replacement of the review RPC that depends on the admin workflow objects from
`20261019090000`; it follows the MAINTAIN migration, subject to its preflight.

The October 29
`20261029120000_lovable_profile_privilege_hardening.sql` is an incompatible
alternative broad-ACL baseline and is excluded from this selected narrow-ACL
path. The October 30 MAINTAIN migration is not part of that alternative: it is
a validated forward step from the post-October 28 state. The October 31
profile-only and profile/signup candidates, and the November 1 Lovable profile
role candidate, target separately inspected alternative production baselines
and are excluded from this feature branch's selected migration sequence. The
`20261101130000_lovable_profile_role_insert_hardening.sql` is another
production-baseline candidate that overlaps profile INSERT hardening and is not
to be combined automatically with the October 19 insert-guard migration.

This history has an explicit source-level split: the worktree file
`20261018214500_profile_role_signup_hardening.sql` contains the profile/signup
portion formerly coupled to analytics, and `20261018220000` contains analytics
only. For a target that has already applied the unsplit 18:22:00 source, do not
run both the split migration and the old unsplit migration. Compare exact
source, live objects, and migration ledger with an authorized operator before
choosing a path. No production-ledger state is inferred from filenames.

The application-schema migration owner contract is
`session_user=<direct superuser login>` and `current_user=postgres`. In a local
Supabase fixture, connect using the verified direct-superuser `supabase_admin`
login and issue `SET ROLE postgres` in the same PostgreSQL session before each
application-schema migration. PostgreSQL leaves `session_user` as
`supabase_admin`, changes `current_user` to `postgres`, and performs subsequent
permission checks as `postgres`. This is intentional: tables and
SECURITY DEFINER functions, plus their default-ACL context, must belong to
`postgres`; creating them with `current_user=supabase_admin` would give them a
different owner. A direct `postgres` superuser login in a hosted environment
also satisfies the identity contract when it owns the required objects. Before
release, verify the actual runner, public schema CREATE/USAGE, table ownership,
and every referenced Auth privilege. Role membership or non-owner table
privileges alone do not satisfy this contract.

The direct-superuser session requirement remains in force. `SET ROLE postgres`
does not change `session_user` or make `postgres` a superuser; it changes the
effective identity, and PostgreSQL checks SQL permissions as the target role.
The trusted superuser session permits selecting the role, while `postgres` must
independently have the ownership and schema privileges needed by each statement.

The six baseline application migrations and October application migrations
that create or replace protected objects must run with effective
`current_user=postgres`. The three July GraphQL-only revocation/extension steps
(`20260710044655`, `20260710044723`, and `20260710044743`) create no protected
application objects and should run as the verified direct `supabase_admin`
superuser for platform-schema or extension authority. Confirm GraphQL schema
and extension identity/dependencies before those steps. In particular,
`20260710044743` contains `DROP EXTENSION pg_graphql CASCADE`; inspect its
fixture effects before a separately approved run. Do not split a migration's
explicit transaction or change its source during execution.

Confirm the platform migration runner's transaction behavior: the analytics,
Admin/NGO, and hardening migrations use explicit `BEGIN`/`COMMIT`; the
role-trigger migration does not.
Before release, confirm the platform runner accepts transaction statements
per migration and cannot split the signup preflight from its security changes.

### Local migration applicability and release boundaries

The six March/July files listed in the Stage 3C fixture procedure are the
selected July baseline inputs; timestamps alone do not prove that their source
matches a hosted project's history. For a clean local checkout, the October
feature path is layered after those six files in the order above. The
profile/signup and analytics concerns are separated in this worktree so
replaying analytics does not repeat profile DDL. If a target already applied
an earlier unsplit version of the analytics file, reconcile the exact applied
source and catalog objects first; do not replay the split profile/signup
migration blindly.

`20261029120000_lovable_profile_privilege_hardening.sql` expects a broad direct
ACL baseline and a profile INSERT-guard trigger. It is not a continuation of
the narrower `20261027180000` / `20261028100000` path and must be excluded from
this selected migration sequence.

`20261030151837_revoke_service_role_maintain_privilege.sql` follows the
post-`20261028100000` state and is part of the selected narrow-ACL path. It is
not an October 29 continuation. Apply it only after the October 28 contract
migration and before `20261101120000`, after its preflight succeeds.

The October 31
`20261031120000` and `20261031130000` candidates, and
`20261101130000_lovable_profile_role_insert_hardening.sql`, target separately
inspected alternative production baselines and are excluded from this selected
feature path. Keep alternative candidates isolated from this release's
automated migration batch. Do not use a generic chronological migration push
from a worktree containing incompatible candidates. Do not manually edit
migration history to skip or record any candidate.

The Admin/NGO tables use table-specific revokes before narrower grants.
Expected effective service-role rights are `user_roles: SELECT`,
`admin_audit_log: SELECT, INSERT`, and
`ngo_applications: SELECT, INSERT, UPDATE, DELETE`; API roles receive none.
The migration's PostgreSQL 17 postconditions check `MAINTAIN`, structural
privileges, column ACLs, and reachable `SET ROLE` paths. The dedicated pgTAP
contract test checks effective rights and direct ACL state. Review the live
grantors, membership graph, table ownership, and migration ledger before any
release; local tests do not authorize a production migration run.

### Edge Function CORS deployment note

The Admin/NGO and account-deletion Edge Functions currently return wildcard
`Access-Control-Allow-Origin: *`. These endpoints do not use cookie-based
ambient authentication: they require a bearer token, validate it through
Supabase Auth, then enforce `user_roles` or NGO application state server-side.
Keep the current CORS behavior for supported Lovable preview and local
development origins until the deployed origin inventory and hosting contract
are confirmed. CORS is not an authorization boundary. If hosting changes to a
fixed-origin production site, review an explicit allowlist separately; do not
tighten it in a way that breaks supported preview flows or treat it as a
replacement for bearer-token verification.

### Profile INSERT privileges, policies, and signup dependency

```sql
SELECT
  n.nspname,
  c.relname,
  c.relkind,
  c.relrowsecurity,
  c.relforcerowsecurity
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE (n.nspname, c.relname) IN (
  ('public', 'profiles'), ('public', 'symptom_checks'),
  ('public', 'user_roles'), ('public', 'ngo_applications'),
  ('public', 'admin_audit_log')
)
ORDER BY n.nspname, c.relname;

SELECT
  c.relname AS table_name,
  r.rolname,
  has_table_privilege(r.oid, c.oid, 'INSERT') AS can_insert
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
CROSS JOIN pg_roles AS r
WHERE n.nspname = 'public'
  AND c.relname = 'profiles'
  AND r.rolname IN ('anon', 'authenticated', 'service_role')
  AND c.relkind IN ('r', 'p');

SELECT polname, polcmd, polpermissive, polroles
FROM pg_policy
WHERE polrelid = to_regclass('public.profiles')
ORDER BY polname;

SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'profiles', 'symptom_checks', 'user_roles',
    'ngo_applications', 'admin_audit_log'
  )
ORDER BY tablename, policyname;

SELECT
  c.relname AS table_name,
  r.rolname,
  has_table_privilege(r.oid, c.oid, 'SELECT') AS can_select,
  has_table_privilege(r.oid, c.oid, 'INSERT') AS can_insert,
  has_table_privilege(r.oid, c.oid, 'UPDATE') AS can_update,
  has_table_privilege(r.oid, c.oid, 'DELETE') AS can_delete
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
CROSS JOIN pg_roles AS r
WHERE n.nspname = 'public'
  AND c.relname IN (
    'profiles', 'symptom_checks', 'user_roles',
    'ngo_applications', 'admin_audit_log'
  )
  AND c.relkind IN ('r', 'p')
  AND r.rolname IN ('anon', 'authenticated', 'service_role')
ORDER BY c.relname, r.rolname;

-- Direct column INSERT ACLs and effective table/column INSERT access.
SELECT
  a.attname AS column_name,
  CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE r.rolname END AS grantee,
  acl.privilege_type,
  acl.is_grantable
FROM pg_attribute AS a
CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
LEFT JOIN pg_roles AS r ON r.oid = acl.grantee
WHERE a.attrelid = to_regclass('public.profiles')
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND acl.privilege_type = 'INSERT'
  AND (acl.grantee = 0 OR r.rolname IN ('anon', 'authenticated'))
ORDER BY a.attname, grantee;

SELECT role_name,
  has_table_privilege(role_name, 'public.profiles', 'INSERT') AS table_insert,
  has_any_column_privilege(role_name, 'public.profiles', 'INSERT') AS any_column_insert
FROM (VALUES ('anon'), ('authenticated')) AS roles(role_name);

SELECT
  t.tgname,
  t.tgenabled,
  pg_get_triggerdef(t.oid, true) AS trigger_definition,
  p.oid::regprocedure AS invoked_function,
  pg_get_userbyid(p.proowner) AS function_owner,
  p.prosecdef AS security_definer,
  p.proconfig AS function_settings,
  has_table_privilege(p.proowner, 'public.profiles', 'INSERT') AS owner_can_insert,
  pg_get_functiondef(p.oid) AS function_definition
FROM pg_trigger AS t
JOIN pg_proc AS p ON p.oid = t.tgfoid
WHERE t.tgrelid = to_regclass('auth.users')
  AND t.tgname = 'on_auth_user_created'
  AND NOT t.tgisinternal;
```

Before profile INSERT is revoked, require exactly one enabled signup trigger
calling the intended `SECURITY DEFINER public.handle_new_user()` function. Its
owner must be able to insert under the table's RLS configuration. Inspect the
function body and verify it inserts only Auth ID/full name and ignores role
metadata. Confirm the API roles have no effective INSERT privilege and no
INSERT/ALL policy applies to them. The profile hardening migration deliberately
fails before applying its revocations if the signup trigger is disabled or its
function owner cannot insert. It drops INSERT-only policies, refuses any
`FOR ALL` policy for explicit reconciliation, revokes all direct client table
and column INSERT ACLs, then checks effective privileges. It preserves the
trusted signup owner's column privileges. Signup behavior still needs
hostile-metadata testing in a disposable local database.

### Constraints, role triggers, and privileged functions

```sql
SELECT
  n.nspname AS table_schema,
  c.relname AS table_name,
  con.conname,
  con.contype,
  con.convalidated,
  CASE con.confdeltype
    WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
    WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
    WHEN 'd' THEN 'SET DEFAULT' ELSE NULL
  END AS on_delete,
  pg_get_constraintdef(con.oid, true) AS definition
FROM pg_constraint AS con
JOIN pg_class AS c ON c.oid = con.conrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE (n.nspname = 'public' AND c.relname IN (
  'profiles', 'symptom_checks', 'user_roles',
  'ngo_applications', 'admin_audit_log'
))
   OR (con.contype = 'f' AND con.confrelid IN (
     to_regclass('public.profiles'), to_regclass('auth.users')
   ))
ORDER BY n.nspname, c.relname, con.conname;

SELECT
  t.tgrelid::regclass AS table_name,
  t.tgname,
  t.tgenabled,
  pg_get_triggerdef(t.oid, true) AS trigger_definition,
  p.oid::regprocedure AS invoked_function
FROM pg_trigger AS t
JOIN pg_proc AS p ON p.oid = t.tgfoid
WHERE t.tgrelid IN (
  to_regclass('public.profiles'), to_regclass('auth.users')
)
  AND NOT t.tgisinternal
ORDER BY table_name::text, t.tgname;

SELECT
  p.oid::regprocedure AS function_signature,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  p.proconfig AS function_settings,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
  pg_get_functiondef(p.oid) AS definition
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'prevent_profile_role_escalation', 'prevent_untrusted_profile_insert',
    'handle_new_user', 'get_ngo_dashboard_stats',
    'submit_ngo_application', 'review_ngo_application',
    'anonymize_account_audit_records'
  )
ORDER BY p.proname, p.oid::regprocedure::text;

-- Inventory all API-executable functions; inspect relevant definitions in the
-- protected console rather than exporting broad function source.
SELECT
  p.oid::regprocedure AS function_signature,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  p.proconfig AS function_settings,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prokind = 'f'
  AND (
    has_function_privilege('anon', p.oid, 'EXECUTE')
    OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
  )
ORDER BY p.oid::regprocedure::text;

SELECT
  c.relname,
  c.relkind,
  pg_get_viewdef(c.oid, true) AS definition,
  c.relacl
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('v', 'm')
ORDER BY c.relname;
```

The profile INSERT policy must be reconciled in full; the hardening migration
drops INSERT-only policies, refuses any `FOR ALL` policy for explicit review,
revokes table and column INSERT grants from `PUBLIC`, `anon`, and
`authenticated`, and adds an INSERT trigger as defense in depth. Confirm
role-protection triggers cover UPDATE separately. For
`ngo_applications`, compare the complete `ngo_applications_check` definition,
the nullable reviewer FK with `ON DELETE SET NULL`, and the replacement
`ngo_applications_review_state_check`; do not apply the reviewer migration if
the full old check differs from the local assumption. Inspect all FKs on
`symptom_checks` and admin tables, including differently named constraints,
before the account-deletion migration.

The analytics migration has a data precondition: `profiles.role` must contain
no NULL or unsupported values before its `NOT NULL` and role-domain constraint
are added. If an approved owner preflight is needed, return aggregate counts
only—never profile identifiers:

```sql
SELECT
  count(*) FILTER (WHERE role IS NULL) AS null_roles,
  count(*) FILTER (WHERE role IS NOT NULL AND role NOT IN ('user', 'ngo'))
    AS unsupported_roles
FROM public.profiles;
```

The account-deletion migration also validates/replaces FKs. If the owner
approves referential-integrity preflight, inspect only aggregate counts of
orphan references; do not return row identifiers or symptom fields. Catalog
checks alone cannot prove these data preconditions.

The function-definition query returns implementation source. Inspect it only
in an authorized console and do not export it without checking for sensitive
or hard-coded values. `has_function_privilege` reports effective execution
rights, not the source grant or the behavior of Edge Functions.

### Analytics and deployed Edge Functions

Confirm the local migration's RPC has the expected no-statistics,
fail-closed definition and is executable only by `service_role`. Inspect all
API-callable public RPCs and views for symptom/assessment reads or
filterable health aggregates. Separately inspect the deployed versions of
`dashboard-stats`, `admin-ngo-management`, and `ngo-application` in the platform
console. Verify each request authenticates server-side; analytics checks both
persisted `profiles.role = 'ngo'` and the latest application status `approved`
before the RPC; and no endpoint returns raw symptom rows or individual health
details. SQL catalogs cannot show deployed Edge Function source. The current
analytics RPC deliberately returns suppressed/null metrics; a threshold of 10
does not by itself authorize enabling aggregates.

### Admin provisioning and account-deletion policy gates

Initial administrator provisioning follows the project-owner-only Lovable
Cloud SQL Editor process documented above. Lovable Cloud backend engine query
logs provide the audit evidence for that out-of-band role assignment. The
application `admin_audit_log` remains dedicated to NGO application events and
must not be presented as the audit record for provisioning. No in-app
administrator delegation workflow is part of the current implementation.

The local account-deletion migrations currently propose deleting symptom
records and applicant-linked NGO applications by cascade, retaining audit rows
with actor/target/application references and details anonymized, and preserving
application status, decision timestamp, and free-text review reason when a
reviewer is deleted. These are proposed behaviors, not approved retention
policy. Product/privacy owners must approve health-history deletion, audit
retention and anonymization, and whether free-text review reasons can contain
personal or sensitive data and for how long. Do not resolve these choices in
migration code without approval.

### Disposable local signup and migration tests

SQL tests are not part of `npm test`. Use only the already approved,
identity-verified disposable Stage 3C fixture; do not create another fixture,
start or reset a stack, or reuse the October Stage 1/Stage 3D.8 fixtures for
this migration path. Before any test connection, verify the fixture's exact
container/project/workdir labels, database name/version, dedicated volume and
network, and loopback-only published ports in the operator's normal macOS
Terminal. If any check fails or Docker is unavailable, stop. A test must not
be used to migrate or normalize an unexpected fixture state.

After the fixture baseline and selected migration set have been independently
verified and separately approved, run each transaction-wrapped pgTAP file in
its own session using the fixture database container, for example:

```sh
{
  printf '%s\n' 'SET ROLE postgres;'
  cat supabase/tests/admin_ngo_privilege_contract.sql
} | docker exec -i "$FIXTURE_DB_CONTAINER" \
      psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -f -
```

The role switch and test file must run in this single `psql` connection. For
each application migration, use the same one-session stdin pattern, replacing
the test path with exactly one reviewed migration file; do not add
`--single-transaction` to files containing their own `BEGIN`/`COMMIT`. The
session-level role remains selected across the migration's commit. For a
source file without its own transaction control, including
`20261018213000_secure_profile_roles.sql`, use `--single-transaction` so
related statements roll back together if one fails. Execute the three July
GraphQL-only steps (`20260710044655`, `20260710044723`, `20260710044743`) in
separate direct `supabase_admin` superuser sessions without `SET ROLE
postgres`; independently review the `pg_graphql CASCADE` effects before that
step is separately approved.

Set `FIXTURE_DB_CONTAINER` only after checking the exact approved fixture
identity. Do not use `supabase db reset`, `supabase db push`, or a CLI command
that can apply pending migrations. Relevant October-path suites include
`admin_ngo_privilege_contract.sql`, `admin_ngo_self_review.sql`, and
`reviewer_account_deletion.sql`; production-baseline and October 29 upgrade
suites belong only to their matching alternative baseline. The account
deletion suite runs in a transaction and rolls synthetic rows and test grants
back. A direct INSERT into `auth.users` exercises its database trigger, not
GoTrue's HTTP signup flow.

For the separate Auth API test, obtain these environment variables from the
verified disposable fixture's local Auth endpoint without saving or pasting
the key:
`HEALTHBOT_DISPOSABLE_LOCAL_SUPABASE_URL` and
`HEALTHBOT_DISPOSABLE_LOCAL_SUPABASE_ANON_KEY`. The test rejects non-loopback
URLs and creates synthetic `@example.invalid` accounts, so run it only against
the disposable local stack:

```sh
npm test -- src/test/disposableLocalAuthSignup.integration.test.ts
```

That integration test requires local Auth to issue a session so its own
profile can be read under RLS. It verifies signup with both `role=admin` and
`role=ngo` metadata results in `profiles.role = 'user'`. It is skipped when
safe local environment variables are absent. The SQL trigger tests, Auth API
tests, and the frontend/unit suite prove different layers; do not treat one as
a substitute for another.

### Production-specific profile and symptom hardening

The production catalog report identified live objects that do not match the
later local October migration sequence. The proposed forward-only migration is
`20261029120000_lovable_profile_privilege_hardening.sql`; it is not permission
to apply the local historical October migrations or to deploy anything.

Before considering this migration, an authorized operator must verify the
linked migration ledger, exact table owners, complete policy definitions,
trigger definitions, effective role memberships/privileges, and the signup
function owner. The migration deliberately fails unless
`public.handle_new_user()` is owned by `postgres`, remains SECURITY DEFINER,
has the reported `search_path=public` before replacement, and has the reviewed
profile-insert body. It preserves that owner and changes only the search path
to empty while retaining the `id`/`full_name` behavior. Do not change ownership
to make the preflight pass.

The migration also fails unless both tables have the reported RLS state and
exact policies, profile role data has no NULL or unsupported values, and the
current broad table-level ACL/no-column-ACL baseline matches the read-only
report. It then removes the verified profile self-insert policy, installs an
invoker-mode profile insert guard, narrows table grants to the application
contract, and adds the `user`/`ngo` role constraint. It never rewrites or
promotes profile rows. `admin` remains a separate authorization role; it is
not a valid `profiles.role` value.

The newly created profile INSERT guard is owned by the effective
`current_user=postgres` under the selected runner contract. The migration and
SQL contract require that this owner is not `anon`, `authenticated`, or
`service_role`, and that none of those API roles can assume it. The hosted
migration executor and its role memberships remain an operator preflight
item. The Auth signup and role-protection function owners continue to be
required to match their separately reviewed `postgres` ownership contract.

This migration does not create `get_ngo_dashboard_stats()`. Production has
reported that RPC as absent, while the local `dashboard-stats` Edge Function
calls it. Keep that Edge Function unavailable in the target until the RPC's
necessity, original source, authorization, response contract, and privacy
behavior are independently approved and reconciled.

Do not use `supabase db push` from a checkout containing the untracked October
local migrations. The production ledger reportedly ends at `20260710044747`,
so the CLI would consider older October files pending as well. First reconcile
the Lovable-tracked checkout and migration history. Proceed only if the
platform provides an approved way to apply and record this reviewed migration
without applying unrelated pending migrations; if it cannot, stop for an
operator migration plan. Never insert ledger rows manually to bypass that
ordering.

After approval, run the migration and the focused SQL/Auth regression tests
only against a fresh, confirmed disposable local environment. The SQL suite
must cover RLS/policy/trigger/function catalog contracts, denied profile
INSERT and role UPDATE attempts, normal signup, profile edits, anonymous
symptom inserts, authenticated symptom history operations, and table/column
privileges including MAINTAIN where the PostgreSQL version supports it. The
separate Auth API test must verify hostile `admin` and `ngo` metadata still
creates a `user` profile. Local tests do not establish production parity.

### PostgreSQL 17 `service_role` MAINTAIN upgrade candidate

The forward-only migration
`20261030151837_revoke_service_role_maintain_privilege.sql` targets only the
verified post-`20261028100000` security state. Its transaction preflight
requires PostgreSQL 17+, the exact role/data/policy/function/trigger/ACL
contracts, and a runner that directly owns both protected tables or is a
superuser. It accepts only the reviewed CRUD privilege matrix, with at most
one owner-granted, non-grantable `MAINTAIN` ACL for `service_role` on either
protected table. It then revokes only that `MAINTAIN` privilege and checks the
effective privileges and direct ACL postconditions before committing. Any
preflight or postcondition exception aborts the transaction; this is
forward-only and has no automatic down migration. Do not restore `MAINTAIN`
as a rollback shortcut.

The migration and its separate upgrade suite were exercised on an isolated
synthetic PostgreSQL 17 Supabase fixture. The migration applied after the six
selected baseline migrations and the selected security migrations through
`20261028100000`. The dedicated
`profile_symptom_maintain_upgrade.sql` suite passed 24/24 assertions. Ten
negative preflight cases were run against isolated reset states; each migration
attempt raised its expected preflight error, left the migration version
unapplied, and matched its pre-attempt schema/data/membership snapshot.

The selected-path pgTAP verification subsequently passed:
- `admin_ngo_privilege_contract.sql`: 9/9 assertions.
- `admin_ngo_self_review.sql`: 8/8 assertions.
- `reviewer_account_deletion.sql`: 57/57 assertions.
- `profile_symptom_maintain_upgrade.sql`: 24/24 assertions.

These 98 assertions are synthetic local results only. They do not authorize a
production migration or establish production schema parity. The October 29
alternative remains excluded. Because this worktree also contains alternative
migration candidates, do not use a generic chronological `supabase db push`.
An operator must reconcile the target migration ledger and obtain an approved
selective release process without applying incompatible alternatives or
manually editing migration history.

## Stage 3B — Production-baseline hardening candidate

Candidate migration: `supabase/migrations/20261031120000_lovable_production_baseline_profile_hardening.sql`.
Dedicated suite: `supabase/tests/production_baseline_profile_security.sql`.
These files target the Lovable production baseline reported on 2026-10-31;
they are not part of the October 18-30 full-feature local migration path. The
migration and SQL suite have not been executed.

### Intended privilege matrix

The preflight accepts the reported broad, direct, non-grantable table grants
to `anon`, `authenticated`, and `service_role` on both protected tables:
SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, and PostgreSQL
17 MAINTAIN. It rejects PUBLIC grants, column grants, extra grantees and
grant options instead of normalizing unknown state. API-role grants must be
from each table owner. `sandbox_exec` must retain direct SELECT and INSERT on
both tables; its grantor is not assumed, and the migration does not alter its
grants, memberships, role attributes, ownership, or existing function ACLs.

After migration:

| Role | `profiles` | `symptom_checks` |
| --- | --- | --- |
| `anon` | No table or column rights | INSERT only; policy requires `user_id IS NULL` |
| `authenticated` | SELECT; UPDATE only on `full_name`, `phone`, `organization_name`, `region`, `contact_info`, `updated_at` | SELECT, INSERT, DELETE; no UPDATE |
| `service_role` | SELECT only | SELECT only for the existing server-side dashboard dependency |
| `sandbox_exec` | Existing SELECT/INSERT unchanged | Existing SELECT/INSERT unchanged |
| owner | Existing owner rights | Existing owner rights |

No API role has TRUNCATE, REFERENCES, TRIGGER, or MAINTAIN. The migration
removes only the reviewed authenticated profile INSERT policy, retains profile
SELECT/UPDATE and all five symptom policies, validates existing roles before
adding `role IN ('user','ngo')` and NOT NULL, and does not add an admin value
to `profiles.role`. Admin remains represented separately by `user_roles`.

### Signup, sandbox, and trusted role assignment

`handle_new_user()` retains its existing owner, ACL and body: it inserts only
the Auth UUID and full name, so role metadata remains ignored and the role
default stays `user`. The candidate replaces its `search_path=public` with an
empty path and uses qualified table references. Its existing enabled
`auth.users` trigger remains in place. Owner schema/column INSERT privileges
and the trigger/function contract are checked before the profile policy/grant
is removed.

The new unconditional BEFORE INSERT guard permits only `role='user'` when the
caller is or can inherit/SET ROLE to `sandbox_exec`; this branch precedes the
table-owner allowance because sandbox_exec intentionally has BYPASSRLS. It
allows the trusted profile owner path used by Auth signup and trusted role
workflows. The candidate rejects API-role outbound memberships and fails if
existing sandbox memberships could inherit/SET ROLE to a trusted/owner or
structurally privileged path; it inspects but never changes memberships.

The migration removes direct profile UPDATE from `service_role`, so it
requires `public.review_ngo_application(uuid, uuid, text, text)` to remain a
SECURITY DEFINER routine owned by the profile owner with an empty search path
and service-role-only EXECUTE. Its current preflight only checks for selected
object-name and error-message substrings; those checks do not prove that the
function independently authorizes an administrator, validates transitions,
assigns the correct role, or writes the required audit event. The local
October workflow migration contains a candidate implementation, but it is not
verified as the deployed or approved trusted definition for this production
baseline. Do not rely on those substring checks for release. Obtain the
explicitly reviewed trusted body and make the preflight compare its complete
normalized definition (and security attributes/ACLs), or keep this migration
blocked. The candidate does not alter NGO application tables, admin audit
tables, role assignment policy, reviewer assignment, or account-deletion
functions and triggers.

The reported production FK is `symptom_checks.user_id ON DELETE SET NULL`.
That preserves the existing behavior by unlinking health rows when Auth
deletion removes a profile, but it does not delete the health-derived row
contents. This candidate intentionally does not change that retention policy.
It therefore does not, by itself, implement the separately approved default
to delete account-linked health history; reconcile the installed deletion
workflow and retention/legal-exception decision in a separate reviewed change.

Application inspection found the profile editor updates only the six granted
metadata columns and never inserts or writes `role`. `avatar_url` is present in
the profile type/schema, but no current application call updates it; adding an
avatar editing feature would require a separately reviewed column grant and
RLS behavior. The chat client inserts
symptom assessments without requesting a returned ID. The profile page reads
own profile/history and deletes selected own symptom rows. The service-role
dashboard table SELECTs are retained because an approved replacement has not
been established. The existing server functions mediate NGO submit/review;
source and unit tests are not proof that matching routines are installed in
the production schema.

### Regression coverage and limitations

The new pgTAP suite checks RLS flags, exact remaining policy contracts,
profile-role data/constraint, direct ACL entries separately from effective
privileges, role memberships, trigger bindings, function owners/security
settings, direct profile INSERT/role UPDATE denial, authenticated profile
column operations, anonymous null-user symptom insertion, cross-user RLS
denial, service-role reads, and sandbox elevated-role denial despite BYPASSRLS.
The sandbox ordinary-role test expects a missing-Auth-user foreign-key error;
it proves the guard permits the `user` role to reach FK validation, not that a
complete preview-account seed workflow succeeds end to end.
Synthetic writes use collision-checked UUIDs and roll back. Test assertions
are evaluated after resetting to the trusted runner role. The suite avoids
reading or printing existing health/profile rows.

The sandbox behavior test uses `SET LOCAL ROLE sandbox_exec`. The inspected
membership has `set_option=false`, so that membership cannot satisfy the test
runner's role-switch requirement. Run the suite only in a disposable fixture
with a verified superuser test runner (or another already-authorized valid
SET path); do not alter the production or fixture membership just to make the
test pass. If the isolated runner cannot switch roles, report the test as
blocked rather than skipping or weakening this assertion.

Normal signup with hostile role metadata still requires the opt-in local Auth
API integration tests. The new SQL suite does not synthesize `auth.users`
rows because Auth's internal required columns vary by release. Existing admin
source/unit tests are separate from PostgreSQL workflow tests; the full NGO,
appeal/review, reviewer, and account-deletion behavior is not newly exercised
by this baseline-specific suite. A fresh disposable PostgreSQL 17 Supabase-
compatible fixture must be used; the full-feature Stage 5J fixture is not an
equivalent baseline.

### Selective execution and ledger handling

Lovable reports that individual reviewed SQL scripts can be applied in its
SQL Editor. Before any live application, the operator must verify the exact
target identity, `session_user`/`current_user`, transaction behavior,
ownership/DDL authority, and every migration precondition through an approved
read-only catalog preflight. Do not run `supabase db push` from this checkout:
it contains incompatible October candidates that are not part of this
production baseline.

SQL Editor execution must not be assumed to record a row in
`supabase_migrations.schema_migrations`. Never insert a migration ledger row
manually. Retain the approved SQL hash, change ticket, execution result, and
before/after catalog evidence. Before future CLI migration use, the platform
owner must identify an approved ledger reconciliation mechanism; absent that,
do not use `db push` or claim CLI migration history is consistent.

### Blockers before disposable validation or release

- Compare the full production schema, owners, RLS policies/predicates, direct
  and column ACLs, grantors, function definitions/ACLs, trigger settings,
  profile-role data, and role-membership graph to the preflight. A failed or
  incomplete read-only query is UNKNOWN, not evidence of absence.
- Verify the deployed NGO review routine matches the required trusted
  SECURITY DEFINER contract. The local October workflow migration is not
  evidence it is installed in production.
- In a new disposable local Supabase environment, test Auth signup with
  hostile `admin`/`ngo` metadata, sandbox ordinary seeding and elevated-role
  denial, API INSERT/role UPDATE denial, permitted profile edits, anonymous
  symptom inserts and authenticated ownership behavior.
- Run the candidate and this pgTAP suite only after the disposable catalog
  baseline matches the source preflight. No PostgreSQL/Auth runtime result is
  claimed here.
- Obtain a platform-approved selective release and migration-ledger
  reconciliation procedure. No production deployment is authorized by this
  local candidate.

## Stage 3C — production-baseline profile and signup hardening candidate

The standalone candidate is `supabase/migrations/20261031130000_lovable_production_baseline_profile_signup_hardening.sql`, with its baseline-only SQL suite at `supabase/tests/profile_signup_security_baseline.sql`. Its scope is profile-role protection, Auth signup, profile INSERT, and the existing symptom-check privilege/RLS contract. It does not depend on an NGO review RPC, application/audit tables, or `user_roles`.

### Ordering and release gate

The Stage 3B candidate `20261031120000_lovable_production_baseline_profile_hardening.sql` has an earlier timestamp but is a separate, incompatible candidate path. Stage 3C is not an implicit continuation of Stage 3B and must not be picked up by a batch migration run that also applies Stage 3B. Use only a separately authorized execution process for the exact reviewed Stage 3C script after the target, schema, migration ledger, runner authority, and every migration precondition have been reconciled. Do not use `supabase db push` from a checkout containing both candidates. Never edit the migration ledger manually; obtain an approved platform procedure for any ledger reconciliation before future CLI use.

### Intended access boundary

| Principal | `profiles` | `symptom_checks` |
| --- | --- | --- |
| `anon` | No table privileges | INSERT only, constrained by existing RLS to rows with `user_id IS NULL` |
| `authenticated` | SELECT plus UPDATE on `full_name`, `phone`, `organization_name`, `region`, `contact_info`, and `updated_at`; no INSERT, table UPDATE, or DELETE | SELECT, INSERT, DELETE subject to the existing ownership RLS policies; no UPDATE |
| `service_role` | SELECT and UPDATE; no INSERT or DELETE | SELECT only, preserving the current backend/dashboard read path |
| `sandbox_exec` | Preserve the pre-existing role attributes, memberships, ownership, function ACLs, and direct SELECT/INSERT grants exactly; the new trigger permits only role=`user` on its insert path | Preserve the pre-existing direct SELECT/INSERT grants and policy/trigger behavior |

The `service_role` profile UPDATE grant is deliberately preserved because the current production workflow has no verified replacement role-assignment path. It is a database privilege, not proof of administrator authorization. Any service-role caller that can reach this database credential remains within that trusted server boundary; do not describe this grant as admin-authorized.

The INSERT trigger distinguishes sandbox execution from the trusted Auth signup path. It detects execution or usable membership involving `sandbox_exec` before the owner/BYPASSRLS branch, and permits that context to insert only `role = 'user'`. The existing SECURITY DEFINER `handle_new_user()` continues to insert `(id, full_name)` so the column default supplies `user`; its reviewed owner path is allowed by the guard. The SQL behavior has not been runtime-validated in this candidate. Validate normal Auth signup (including hostile role metadata) and sandbox behavior on a fresh disposable PostgreSQL 17 Supabase-compatible fixture before any release consideration.

### Static scope and validation status

The candidate preserves the six authenticated profile-update columns above and existing symptom-check policies and required backend reads. No unrelated frontend call sites or application behavior are changed here. The current profile editor's reviewed update shape uses those six fields; if a later client operation needs `avatar_url` or another field, reconcile that need and approve a separate privilege change rather than broadening this grant preemptively.

The dedicated SQL suite excludes NGO/admin workflow assertions and covers the profile/signup and symptom baseline. It requires a trusted disposable test runner able to `SET LOCAL ROLE sandbox_exec`; the inspected sandbox membership has `set_option = false`, so ordinary membership does not itself authorize that role switch. Do not alter role membership to force the test to pass. The suite runs inside a transaction and rolls synthetic writes back. Its service-role profile UPDATE check verifies only the database privilege/trigger path and does not test administrator authorization. Auth API signup with hostile `admin`/`ngo` metadata remains a separate integration test. Neither the migration nor tests have been executed as part of this implementation pass.

Before considering staging, obtain an authorized read-only preflight of exact target identity, ledger state, owners, role/function definitions and ACLs, policy predicates, trigger state, column/table ACLs, role memberships, and profile-role data. Use a new disposable fixture for runtime validation. Keep the reviewed SQL hash, test output, approved change record, and pre/post catalog evidence. No deployment or production change is authorized by this local candidate.

## NGO organization dashboard

The `/ngo/dashboard` route (and legacy `/dashboard` alias) requires a session,
then calls the authenticated `ngo-application` status action. The Edge
Function verifies the bearer token, derives the user identity from that token,
and returns only the current user's allowlisted application fields and
eligibility flags. The browser treats the dashboard as available only when
the persisted profile role is `ngo`, the latest application is `approved`,
and the server response flags agree. Only then does it request
`dashboard-stats`; that function independently checks the verified identity,
profile role, and latest persisted application status before invoking its
aggregate RPC. The page never reads symptom rows, audit records, reviewer
identities, or evidence references directly.

The status projection is implemented by the `ngo-application` Edge Function.
The latest `origin/main` already contains this status projection; this feature
branch therefore does not duplicate those Edge Function changes. Deploy the
updated frontend and Edge Function together only through the normal reviewed
release process. No deployment is performed by this change.

Pending, rejected, suspended, absent, or inconsistent application states have
separate portal messaging. Rejected applications may resubmit through the
existing workflow. Suspended accounts cannot automatically reapply; they
require administrator reinstatement. Whether a reinstated account should then
be allowed to submit a new application remains a product decision. The
current backend rejects suspended-state submissions, and this feature keeps
that behavior unchanged. Community Health Insights remain withheld unless the
response explicitly reports `privacySuppressed: false` and a positive finite
assessment total; withheld or malformed results never render charts. This
frontend state is not a substitute for the Edge Function/database authorization
checks and does not establish that the current production backend has the
matching objects deployed.
