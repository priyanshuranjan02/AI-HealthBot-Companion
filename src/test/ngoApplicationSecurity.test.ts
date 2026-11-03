import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = process.cwd();
const endpoint = readFileSync(join(root, "supabase/functions/ngo-application/index.ts"), "utf8");
const workflow = readFileSync(join(root, "supabase/functions/ngo-application/workflow.ts"), "utf8");
const migration = readFileSync(join(root, "supabase/migrations/20261019090000_admin_ngo_verification.sql"), "utf8");
const appRoutes = readFileSync(join(root, "src/App.tsx"), "utf8");
const authPage = readFileSync(join(root, "src/pages/Auth.tsx"), "utf8");

describe("NGO Edge Function and database contract", () => {
  it("authenticates the bearer token and scopes status reads to its verified user", () => {
    expect(endpoint).toContain("authClient.auth.getUser(accessToken)");
    expect(endpoint).toContain("x-supabase-client-runtime-version");
    expect(endpoint).toContain('.eq("id", userId)');
    expect(endpoint).toContain('.eq("applicant_user_id", userId)');
    expect(endpoint).not.toContain("body.userId");
    expect(workflow).toContain("services.getStatus(userId)");
  });

  it("allows only rejected or absent application state through the submit endpoint", () => {
    expect(workflow).toContain('current.profileRole !== "user"');
    expect(workflow).toContain('current.application?.status === "pending"');
    expect(workflow).toContain('current.application.status !== "rejected"');
    expect(workflow).toContain('if (result.errorCode === "42501")');
    expect(workflow).toContain('if (result.errorCode === "23505")');
  });

  it("passes the verified identity and exact parameters to the service-only submission RPC", () => {
    expect(endpoint).toContain('admin.rpc("submit_ngo_application"');
    expect(endpoint).toContain("p_applicant_user_id: userId");
    expect(endpoint).toContain("p_organization_name: input.organizationName");
    expect(endpoint).toContain("p_registration_identifier: input.registrationIdentifier");
    expect(endpoint).toContain("p_official_contact_email: input.officialContactEmail");
    expect(endpoint).toContain("p_official_contact_phone: input.officialContactPhone");
    expect(endpoint).toContain("p_website: input.website");
    expect(endpoint).toContain("p_evidence_references: input.evidenceReferences");
    expect(migration).toMatch(/submit_ngo_application\([\s\S]*?p_evidence_references jsonb\s*\)[\s\S]*?RETURNS uuid/i);
    expect(migration).toContain("RETURN application_id;");
    expect(migration).toMatch(/IS DISTINCT FROM 'user'/i);
    expect(migration).toMatch(/GRANT EXECUTE ON FUNCTION public\.submit_ngo_application[\s\S]*?TO service_role/i);
  });

  it("keeps admin login separate from public signup and protects workflow routes", () => {
    expect(appRoutes).toContain('path="/admin/login" element={<Auth mode="admin" />');
    expect(appRoutes).toContain('path="/ngo/login" element={<Auth mode="ngo" />');
    expect(appRoutes).toContain('path="/admin/ngo-verification" element={<AdminDashboard />');
    expect(readFileSync(join(root, "src/pages/AdminDashboard.tsx"), "utf8")).toContain('invoke("admin-ngo-management"');
    expect(appRoutes).toContain('path="/ngo/dashboard" element={<RequireSession');
    expect(authPage).toContain('const loginOnly = mode !== "standard"');
    expect(authPage).toContain("!loginOnly && <p");
  });
});
