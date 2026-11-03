import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = process.cwd();
const edgeFunction = readFileSync(
  join(root, "supabase/functions/dashboard-stats/index.ts"),
  "utf8",
);
const workflow = readFileSync(
  join(root, "supabase/functions/dashboard-stats/workflow.ts"),
  "utf8",
);
const migration = readFileSync(
  join(root, "supabase/migrations/20261018220000_privacy_preserving_ngo_analytics.sql"),
  "utf8",
);
const profileSignupMigration = readFileSync(
  join(root, "supabase/migrations/20261018214500_profile_role_signup_hardening.sql"),
  "utf8",
);
const profileInsertMigration = readFileSync(
  join(root, "supabase/migrations/20261019120000_harden_profile_insert_privileges.sql"),
  "utf8",
);
const functionSources = readdirSync(join(root, "supabase/functions"), { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .flatMap((directory) => readdirSync(join(root, "supabase/functions", directory.name))
    .filter((file) => file.endsWith(".ts"))
    .map((file) => ({
      path: `${directory.name}/${file}`,
      source: readFileSync(join(root, "supabase/functions", directory.name, file), "utf8"),
    })));

describe("health analytics security contract", () => {
  it("requires a validated session and an NGO role before querying analytics", () => {
    expect(edgeFunction).toContain("authClient.auth.getUser(token)");
    expect(edgeFunction).toContain('.from("profiles")');
    expect(edgeFunction).toContain('.from("ngo_applications")');
    expect(workflow).toContain('profileRole !== "ngo"');
    expect(workflow).toContain('latestApplicationStatus !== "approved"');
    expect(workflow.indexOf('latestApplicationStatus !== "approved"')).toBeLessThan(
      workflow.indexOf("services.getStats()"),
    );
  });

  it("uses the aggregate-only database interface instead of raw symptom records", () => {
    expect(edgeFunction).toContain('adminClient.rpc("get_ngo_dashboard_stats")');
    expect(edgeFunction).not.toContain('.from("symptom_checks")');
    expect(edgeFunction).not.toContain('.from("profiles").select("*")');
    expect(migration).not.toContain("FROM public.symptom_checks");
  });

  it("has no alternate Edge Function or request filter for analytics", () => {
    const callers = functionSources
      .filter(({ source }) => source.includes('"get_ngo_dashboard_stats"'))
      .map(({ path }) => path);
    expect(callers).toEqual(["dashboard-stats/index.ts"]);
  });

  it("fails closed while assessment rows are caller-controlled", () => {
    expect(migration).toContain("'totalChecks', NULL");
    expect(migration).toContain("'severityCounts', jsonb_build_object('low', NULL, 'moderate', NULL, 'high', NULL)");
    expect(migration).toContain("'privacySuppressed', true");
    expect(migration).toContain("jsonb_build_array('all')");
  });

  it("applies profile role and trusted signup hardening in its separate prerequisite migration", () => {
    expect(profileSignupMigration).toContain("profiles_role_allowed_values");
    expect(profileSignupMigration).toContain("CHECK (role IN ('user', 'ngo'))");
    expect(profileSignupMigration).toContain('DROP POLICY IF EXISTS "Users can insert own profile"');
    expect(profileSignupMigration).toContain("REVOKE INSERT ON TABLE public.profiles FROM authenticated");
    expect(profileSignupMigration).toContain("ALTER COLUMN role SET NOT NULL");
    expect(profileSignupMigration).toContain("SET search_path = ''");
  });

  it("revokes direct profile creation from all API roles and requires trusted signup first", () => {
    expect(profileInsertMigration).toMatch(
      /REVOKE\s+INSERT\s+ON\s+TABLE\s+public\.profiles\s+FROM\s+PUBLIC,\s*anon,\s*authenticated/i,
    );
    expect(profileInsertMigration).toContain("polcmd = '*'");
    expect(profileInsertMigration).toContain("polcmd = 'a'");
    expect(profileInsertMigration).toContain("aclexplode(a.attacl)");
    expect(profileInsertMigration).toContain("has_any_column_privilege('authenticated'");
    expect(profileInsertMigration).toContain("on_auth_user_created");
    expect(profileInsertMigration).toContain("handle_new_user owner cannot safely insert profiles");
    expect(profileInsertMigration).toContain("Direct profile creation is not permitted");
    expect(profileInsertMigration).toContain("must use an empty search_path");
    expect(profileInsertMigration).toContain("must default to user for trusted signup");
  });
});
