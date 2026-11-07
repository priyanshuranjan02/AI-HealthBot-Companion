import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = process.cwd();
const endpoint = readFileSync(join(root, "supabase/functions/ngo-application/index.ts"), "utf8");
const workflow = readFileSync(join(root, "supabase/functions/ngo-application/workflow.ts"), "utf8");
const migration = readFileSync(join(root, "supabase/migrations/20261019090000_admin_ngo_verification.sql"), "utf8");
const appRoutes = readFileSync(join(root, "src/App.tsx"), "utf8");
const homePage = readFileSync(join(root, "src/pages/Index.tsx"), "utf8");
const authPage = readFileSync(join(root, "src/pages/Auth.tsx"), "utf8");
const vercelConfig = JSON.parse(readFileSync(join(root, "vercel.json"), "utf8")) as {
  rewrites: Array<{ source: string; destination: string }>;
};

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

  it("returns the own-application dashboard allowlist without evidence or identity fields", () => {
    expect(endpoint).toContain('select("role").eq("id", userId)');
    expect(endpoint).toContain('.select("id, organization_name, registration_identifier, official_contact_email, official_contact_phone, website, status, review_reason, decided_at, created_at")');
    expect(endpoint).toContain('.eq("applicant_user_id", userId)');
    expect(workflow).toContain("safeApplicationProjection(current.application)");
    expect(workflow).toContain('current.profileRole === "ngo" && application?.status === "approved"');
    expect(workflow).not.toContain("evidence_references:");
    expect(workflow).not.toContain("reviewer_id:");
    expect(workflow).not.toContain("applicant_user_id:");
  });

  it("keeps the organization dashboard away from raw symptom and audit tables", () => {
    const dashboard = readFileSync(join(root, "src/pages/Dashboard.tsx"), "utf8");
    expect(dashboard).toContain('invoke("ngo-application"');
    expect(dashboard).toContain('invoke("dashboard-stats"');
    expect(dashboard).not.toContain('.from("symptom_checks")');
    expect(dashboard).not.toContain('.from("admin_audit_log")');
    expect(dashboard).not.toContain("evidence_references");
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
    expect(appRoutes).toContain('path="/auth" element={<Auth />}');
    expect(authPage).toContain('"/admin/login?recovery=1"');
    expect(authPage).toContain('"/auth?recovery=1"');
    expect(appRoutes).toContain('path="/ngo/login" element={<Auth mode="ngo" />');
    expect(appRoutes).toContain('path="/admin/ngo-verification" element={<AdminDashboard />');
    expect(readFileSync(join(root, "src/pages/AdminDashboard.tsx"), "utf8")).toContain('invoke("admin-ngo-management"');
    expect(appRoutes).toContain('path="/ngo/dashboard" element={<RequireSession');
    expect(appRoutes).toContain('path="/dashboard" element={<RequireSession');
    expect(homePage).toContain('navigate(user ? "/ngo/dashboard" : "/ngo/login")');
    expect(homePage).toContain('navigate(user ? "/ngo/application" : "/ngo/login")');
    expect(authPage).toContain('const loginOnly = mode !== "standard"');
    expect(authPage).toContain("!loginOnly && !resetRequest && !passwordRecovery && <p");
  });

  it("rewrites direct SPA and password-recovery requests to the Vite entry point", () => {
    expect(vercelConfig.rewrites).toContainEqual({ source: "/(.*)", destination: "/index.html" });
    expect(appRoutes).toContain('path="/admin/login" element={<Auth mode="admin" />');
    expect(appRoutes).toContain('path="/auth" element={<Auth />}');
  });
});
