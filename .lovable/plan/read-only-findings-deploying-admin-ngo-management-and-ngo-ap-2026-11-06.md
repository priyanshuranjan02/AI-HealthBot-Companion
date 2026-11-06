# Read-only findings: deploying `admin-ngo-management` and `ngo-application`

No files, secrets, functions or settings were changed. Nothing was deployed.

## 1. Source present
- `supabase/functions/admin-ngo-management/`: `index.ts` (4,579 B), `response.ts` (1,338 B)
- `supabase/functions/ngo-application/`: `index.ts` (3,417 B), `workflow.ts` (4,666 B)
- Imports: `https://esm.sh/@supabase/supabase-js@2` plus each function's own local helper file. No `_shared/` code, no `deno.json`, no import map.
- `supabase/config.toml` has only `project_id`. Neither function has its own settings block, so both use the platform default `verify_jwt = false`. Both check the caller's token in code with `auth.getUser(token)`. `admin-ngo-management` also checks for the admin role in `user_roles` before it does anything.

## 2. Environment variables
Both functions read `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`. All three are already set as platform-provided project secrets. The owner does not need to configure anything. If any of them is missing at runtime, the functions return a safe 500 error.

## 3. Supported deployment method
- Lovable-managed functions are deployed by the platform. The supported way to deploy only these two is the agent's function deploy tool, called with exactly `["admin-ngo-management", "ngo-application"]`, in build mode after the owner approves. It deploys only the functions it names.
- Publishing the frontend is a separate step and is not needed to deploy these functions.
- The owner does not need a CLI, a dashboard or any credentials.

## 4. Tests
I ran 6 related test files: 53 of 53 tests passed. These are contract and workflow tests run against the source files. They do not call the live functions.

## 5. Changes needed before deployment
No code changes are blocking deployment. Advisory only:
- The functions use the floating `@supabase/supabase-js@2` import from esm.sh and their own CORS header list. Both work, but pinning a version would make deployments reproducible. This is optional.
- I have not checked the live behaviour of the endpoints yet. That needs a check after deployment.

## Proposed next stage (only if approved)
1. Deploy only the two functions with the deploy tool.
2. Run read-only checks: a request with no token returns 401, a request with a non-admin token returns 403, and the logs show no configuration errors.
3. Do not publish, change secrets or provision an admin.
