import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = process.cwd();

const migration = readFileSync(
  join(root, "supabase/migrations/20261019090000_admin_ngo_verification.sql"),
  "utf8",
);

const dashboardStats = readFileSync(
  join(root, "supabase/functions/dashboard-stats/index.ts"),
  "utf8",
);
const dashboardWorkflow = readFileSync(
  join(root, "supabase/functions/dashboard-stats/workflow.ts"),
  "utf8",
);

const adminFunction = readFileSync(
  join(root, "supabase/functions/admin-ngo-management/index.ts"),
  "utf8",
);
const adminResponse = readFileSync(
  join(root, "supabase/functions/admin-ngo-management/response.ts"),
  "utf8",
);

describe("administrator and NGO verification security contract", () => {
  it("keeps application writes and audit records out of client roles", () => {
    expect(migration).toMatch(
      /REVOKE\s+ALL(?:\s+PRIVILEGES)?\s+ON\s+TABLE\s+public\.ngo_applications\s+FROM\s+PUBLIC,\s*anon,\s*authenticated,\s*service_role/i,
    );

    expect(migration).toMatch(
      /REVOKE\s+ALL(?:\s+PRIVILEGES)?\s+ON\s+TABLE\s+public\.admin_audit_log\s+FROM\s+PUBLIC,\s*anon,\s*authenticated,\s*service_role/i,
    );

    expect(migration).toContain(
      "CHECK (status IN ('pending', 'approved', 'rejected', 'suspended'))",
    );

    expect(migration).toContain("CREATE TABLE public.user_roles");
    expect(migration).toContain(
      "role text NOT NULL CHECK (role = 'admin')",
    );
    expect(migration).toContain(
      "Administrator privileges are separate from profiles.role.",
    );
  });

  it("prevents a user from having multiple pending applications", () => {
    expect(migration).toMatch(
      /CREATE\s+UNIQUE\s+INDEX\s+ngo_applications_one_pending_per_user_idx/i,
    );

    expect(migration).toMatch(
      /ON\s+public\.ngo_applications\s*\(\s*applicant_user_id\s*\)\s*WHERE\s+status\s*=\s*'pending'/i,
    );
  });

  it("limits privileged procedures to the service role", () => {
    expect(migration).toContain(
      "GRANT EXECUTE ON FUNCTION public.submit_ngo_application",
    );

    expect(migration).toContain(
      "GRANT EXECUTE ON FUNCTION public.review_ngo_application",
    );

    expect(migration).toContain("TO service_role");

    expect(migration).toMatch(
      /REVOKE\s+ALL\s+ON\s+FUNCTION\s+public\.submit_ngo_application[\s\S]*?FROM\s+PUBLIC,\s*anon,\s*authenticated/i,
    );

    expect(migration).toMatch(
      /REVOKE\s+ALL\s+ON\s+FUNCTION\s+public\.review_ngo_application[\s\S]*?FROM\s+PUBLIC,\s*anon,\s*authenticated/i,
    );
  });

  it("requires both NGO role and approved verification before analytics RPC access", () => {
    expect(dashboardStats).toContain('.order("created_at", { ascending: false })');
    expect(dashboardWorkflow).toContain('latestApplicationStatus !== "approved"');
    expect(dashboardWorkflow.indexOf('latestApplicationStatus !== "approved"')).toBeLessThan(
      dashboardWorkflow.indexOf("services.getStats()"),
    );
  });

  it("checks administrator role before listing or reviewing applications", () => {
    expect(adminFunction).toContain('from("user_roles")');
    expect(adminFunction).toContain('.eq("user_id", auth.user.id)');
    expect(adminFunction).toContain('.eq("role", "admin")');
    expect(adminFunction).toContain("hasAdministratorRole(adminRole?.role)");

    expect(adminFunction).toContain('body?.action === "review"');

    expect(
      adminFunction.indexOf("hasAdministratorRole(adminRole?.role)"),
    ).toBeLessThan(
      adminFunction.indexOf('body?.action === "review"'),
    );

    expect(adminFunction).toContain("p_reviewer_id: auth.user.id");
    expect(adminFunction).toContain('admin.rpc("review_ngo_application"');
    expect(adminFunction).toContain("p_application_id: body.applicationId");
    expect(adminFunction).toContain("p_status: body.status");
    expect(adminFunction).toContain("p_reason: reason || null");
  });

  it("provides a minimal admin-access check without returning application data", () => {
    const checkAccess = adminFunction.indexOf('body?.action === "check-access"');
    const applicationQuery = adminFunction.indexOf('.from("ngo_applications")');
    expect(checkAccess).toBeGreaterThan(adminFunction.indexOf("hasAdministratorRole(adminRole?.role)"));
    expect(checkAccess).toBeGreaterThan(-1);
    expect(checkAccess).toBeLessThan(applicationQuery);
    expect(adminFunction.slice(checkAccess, applicationQuery)).toContain("authorized: true");
  });

  it("allows only the intended NGO review transitions", () => {
    expect(migration).toMatch(
      /status\s*=\s*'pending'[\s\S]*?p_status\s+IN\s*\(\s*'approved'\s*,\s*'rejected'\s*\)/i,
    );

    expect(migration).toMatch(
      /status\s*=\s*'approved'[\s\S]*?p_status\s*=\s*'suspended'/i,
    );

    expect(migration).toContain(
      "A reason is required for rejection or suspension",
    );
  });

  it("distinguishes application counts from unique organization counts", () => {
    expect(adminFunction).toContain("uniqueOrganizationCount");

    expect(adminFunction).toContain(
      'approvedNgos: uniqueOrganizationCount("approved")',
    );

    expect(adminFunction).toContain(
      'suspendedOrganizations: uniqueOrganizationCount("suspended")',
    );
  });

  it("uses an allowlisted review response rather than returning IDs or evidence references", () => {
    expect(adminFunction).toContain('select("id, organization_name, registration_identifier, official_contact_email, official_contact_phone, website, evidence_references, status, review_reason, decided_at, created_at")');
    expect(adminFunction).toContain(".map(minimizeNgoApplication)");
    expect(adminResponse).toContain("evidenceCount:");
    expect(adminResponse).not.toContain("applicant_user_id:");
    expect(adminResponse).not.toContain("evidence_references:");
  });
});
