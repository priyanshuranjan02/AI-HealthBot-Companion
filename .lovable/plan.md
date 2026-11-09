# Reinstate diagnosis and safe deployment plan

## Verified findings (read-only, this turn)
1. **Backend link:** `supabase/config.toml` says `project_id = "nbqphskrnstcmudvhzie"`, and the read query ran against that backend. It is Lovable Cloud-managed, not an external project you own.
2. **The reinstate handler is NOT in this project's function source.** A search for "reinstate" in `supabase/functions/` finds nothing. The admin page (`src/pages/AdminDashboard.tsx` lines 68–92) sends `action: "reinstate"`, but `admin-ngo-management/index.ts` has no branch for it. That explains the 200 response with `{ counts, applications }`: an action the function doesn't recognise falls through to the normal list response. The 2026-11-09 commit you describe does not appear to be in the Lovable checkout. It may live on a branch or remote that Lovable hasn't synced.
3. **The database function is missing in production.** `pg_proc` contains only `review_ngo_application` and `submit_ngo_application`; there is no `reinstate_ngo_application`. The migration file `supabase/migrations/20261107120000_admin_ngo_reinstatement.sql` exists locally but has not been applied.
4. **Deployed version:** Lovable can deploy functions and read their logs. It cannot fetch the exact source that is currently deployed, so the only evidence of what is live is how it behaves. The 2026-11-06 "Deployed 2 Edge Functions" event means those two functions (admin-ngo-management, ngo-application) were deployed from the source as it was then. It says nothing about later changes.
5. **Permissions:** Deploying functions and running migrations both go through agent tools in build mode, and both worked earlier in this project. You don't need a separate backend account or owner. The only gate is your approval of each action.

## Unknown
- Where the 2026-11-09 commit lives: a GitHub branch Lovable doesn't track, or a sync that hasn't happened yet.
- Whether `20261107120000` runs unchanged under the managed migration runner (preflight and ownership expectations). It needs a review before it is applied.

## Next steps (after approval, each confirmed separately)
1. Bring the reinstatement commit into this Lovable project: sync GitHub, or upload the exact `admin-ngo-management` files plus their SHA-256 values. Then confirm the hashes match and that a `reinstate` handler calling `reinstate_ngo_application` is present.
2. Review `20261107120000_admin_ngo_reinstatement.sql` against the live state: prerequisites, the postgres runner, ACLs including sandbox_exec, and whether it depends on CASCADE or the audit log.
3. Apply only that migration through the migration tool. The database function must exist before the function code that calls it.
4. Deploy only `admin-ngo-management`.
5. Verify:
   - The function exists and its permissions allow only the owner and service_role.
   - Signed out → 401; non-admin → 403.
   - An admin reinstating a suspended test application returns `{ success: true }`, the status changes to approved, the profile role becomes ngo, and an audit row is written.
   - Reinstating the admin's own application is rejected.
   - Reinstating an application that isn't suspended returns 409.
   - The function logs show no errors.

No changes have been made.
