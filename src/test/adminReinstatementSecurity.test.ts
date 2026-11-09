import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = process.cwd();
const migration = readFileSync(join(root, "supabase/migrations/20261107120000_admin_ngo_reinstatement.sql"), "utf8");
const endpoint = readFileSync(join(root, "supabase/functions/admin-ngo-management/index.ts"), "utf8");
const dashboard = readFileSync(join(root, "src/pages/AdminDashboard.tsx"), "utf8");
const testSql = readFileSync(join(root, "supabase/tests/admin_ngo_reinstatement.sql"), "utf8");

describe("Admin NGO reinstatement security contract", () => {
  it("defines an atomic PL/pgSQL SECURITY DEFINER RPC with an empty search_path", () => {
    expect(migration).toContain("CREATE FUNCTION public.reinstate_ngo_application(");
    expect(migration).toContain("LANGUAGE plpgsql");
    expect(migration).toContain("SECURITY DEFINER");
    expect(migration).toContain("SET search_path = ''");
    expect(migration.indexOf("BEGIN;")).toBeLessThan(migration.indexOf("$reinstatement_preflight$"));
    expect(migration.trimEnd().endsWith("COMMIT;")).toBe(true);
  });

  it("requires a persisted administrator, valid reason, suspended latest application, non-self applicant and user profile", () => {
    const functionStart = migration.indexOf("CREATE FUNCTION public.reinstate_ngo_application(");
    const functionEnd = migration.indexOf("$function$;", functionStart);
    const functionBody = migration.slice(functionStart, functionEnd);
    const adminCheck = functionBody.indexOf("IF NOT reviewer_is_admin THEN");
    const profileRowLock = functionBody.indexOf("FOR UPDATE;", adminCheck);
    const profileRoleCheck = functionBody.indexOf("IF NOT FOUND OR applicant_profile_role IS DISTINCT FROM 'user' THEN", profileRowLock);
    const applicationRowLock = functionBody.indexOf("FOR UPDATE;", profileRoleCheck + 1);
    const latestOrder = functionBody.indexOf("ORDER BY app.created_at DESC, app.id DESC", applicationRowLock);
    const selfCheck = functionBody.indexOf("IF applicant_id = p_reviewer_id THEN", latestOrder);
    const applicationWrite = functionBody.indexOf("SET status = 'approved'", selfCheck);
    expect(functionStart).toBeGreaterThan(-1);
    expect(functionEnd).toBeGreaterThan(functionStart);
    expect(adminCheck).toBeGreaterThan(-1);
    expect(profileRowLock).toBeGreaterThan(adminCheck);
    expect(profileRoleCheck).toBeGreaterThan(profileRowLock);
    expect(applicationRowLock).toBeGreaterThan(profileRoleCheck);
    expect(selfCheck).toBeGreaterThan(latestOrder);
    expect(latestOrder).toBeGreaterThan(applicationRowLock);
    expect(applicationWrite).toBeGreaterThan(selfCheck);
    expect(functionBody).toContain("current_setting('transaction_isolation') <> 'read committed'");
    expect(migration).toContain("char_length(p_reason) > 2000");
    expect(migration).toContain("review_reason = NULL");
    expect(migration).toContain("SET role = 'ngo'");
    expect(migration).toContain("'ngo_application_reinstated'");
    expect(migration).toContain("'from_status', 'suspended'");
    expect(migration).toContain("'to_status', 'approved'");
  });

  it("preserves prior audit actions and enforces the service_role-only function ACL", () => {
    for (const action of ["ngo_application_submitted", "ngo_application_approved", "ngo_application_rejected", "ngo_application_suspended", "ngo_application_reinstated"]) {
      expect(migration).toContain(action);
    }
    expect(migration).toContain("acl.grantee <> service_role_oid");
    expect(migration).toContain("acl.grantor = p.proowner");
    expect(migration).toContain("NOT acl.is_grantable");
    expect(migration).toContain("has_function_privilege('anon', function_oid, 'EXECUTE')");
    expect(migration).toContain("has_function_privilege('authenticated', function_oid, 'EXECUTE')");
    expect(migration).toContain("has_function_privilege('service_role', function_oid, 'EXECUTE')");
    expect(migration).toContain("acl.grantor <> p.proowner OR acl.is_grantable");
    expect(migration).toContain("m.set_option AND NOT (m.roleid = ANY(s.role_path))");
    expect(migration).toContain("TO service_role");

    const rpcPreflight = migration.slice(
      migration.indexOf("DO $api_execution_preflight$"),
      migration.indexOf("$api_execution_preflight$;"),
    );
    const postconditions = migration.slice(
      migration.indexOf("DO $reinstatement_postconditions$"),
      migration.indexOf("$reinstatement_postconditions$;"),
    );
    for (const guard of [rpcPreflight, postconditions]) {
      expect(guard).toContain("WITH RECURSIVE api_roots(root_oid)");
      expect(guard).toContain("JOIN pg_catalog.pg_auth_members AS m ON m.member = s.role_oid");
      expect(guard).toContain("WHERE m.set_option AND NOT (m.roleid = ANY(s.role_path))");
      expect(guard).toContain("s.role_oid <> s.root_oid");
      expect(guard).toContain("has_function_privilege(");
      expect(guard).toContain("s.role_oid, function_oid, 'EXECUTE'");
    }
  });

  it("regresses an intermediate SET ROLE path inheriting service_role EXECUTE", () => {
    expect(testSql).toContain("CREATE ROLE aihb_reinstate_rpc_bridge_test NOLOGIN INHERIT");
    expect(testSql).toContain("GRANT service_role TO aihb_reinstate_rpc_bridge_test");
    expect(testSql).toContain("WITH INHERIT FALSE, SET TRUE");
    expect(testSql).toContain("has_function_privilege(");
    expect(testSql).toContain("the effective-privilege preflight predicate rejects the intermediate inherited EXECUTE path");
    expect(testSql).toContain("the postcondition predicate detects the same unsafe path introduced after migration");
    expect(testSql).toContain("DROP ROLE aihb_reinstate_rpc_bridge_test");
  });

  it("keeps the admin check before reinstate and derives reviewer identity from verified Auth", () => {
    const roleCheck = endpoint.indexOf("if (!hasAdministratorRole(adminRole?.role))");
    const reinstateAction = endpoint.indexOf('body?.action === "reinstate"');
    expect(roleCheck).toBeGreaterThan(-1);
    expect(reinstateAction).toBeGreaterThan(roleCheck);
    expect(endpoint).toContain("p_reviewer_id: auth.user.id");
    expect(endpoint).not.toMatch(/p_reviewer_id\s*:\s*body\./);
    expect(endpoint).toContain("Array.from(reason).length > 2000");
    expect(endpoint).toContain('error.code === "P0002"');
    expect(endpoint).toContain('}, 409);');
    expect(endpoint).toContain('error.code === "42501"');
    expect(endpoint).toContain('}, 403);');
  });

  it("only exposes the required-reason reinstatement action for suspended applications and refreshes on success", () => {
    expect(dashboard).toContain('actions.includes("reinstate")');
    expect(dashboard).toContain('Reinstatement reason (required)');
    expect(dashboard).toContain('Reinstate NGO access');
    expect(dashboard).toContain('await request({ action: "reinstate"');
    expect(dashboard).toContain("await load();");
  });

  it("includes database regression assertions for success, rejection, audit, ACL, and latest-application behavior", () => {
    for (const assertion of [
      "an administrator may reinstate a suspended applicant",
      "a missing reason is rejected",
      "a reason longer than 2,000 characters is rejected",
      "a non-administrator cannot reinstate an application",
      "an administrator cannot reinstate their own application",
      "a non-suspended application cannot be reinstated",
      "an older suspended application cannot be reinstated",
      "preserves the original suspension audit event",
      "exact service_role-only EXECUTE ACL",
    ]) expect(testSql).toContain(assertion);
  });
});
