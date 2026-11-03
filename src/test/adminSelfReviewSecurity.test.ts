import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = process.cwd();
const migration = readFileSync(
  join(root, "supabase/migrations/20261101120000_prevent_admin_ngo_self_review.sql"),
  "utf8",
);
const endpoint = readFileSync(
  join(root, "supabase/functions/admin-ngo-management/index.ts"),
  "utf8",
);

describe("Admin NGO self-review safeguard contract", () => {
  it("checks the persisted administrator role before resolving applicant identity", () => {
    const authCheck = migration.indexOf("IF NOT is_admin THEN");
    const applicationLock = migration.indexOf("FOR UPDATE;");
    const selfReviewCheck = migration.indexOf("IF applicant_id = p_reviewer_id THEN");
    const statusUpdate = migration.indexOf("UPDATE public.ngo_applications AS app");

    expect(authCheck).toBeGreaterThan(-1);
    expect(applicationLock).toBeGreaterThan(authCheck);
    expect(selfReviewCheck).toBeGreaterThan(applicationLock);
    expect(statusUpdate).toBeGreaterThan(selfReviewCheck);
    expect(migration).toContain("USING ERRCODE = '42501'");
  });

  it("preserves allowed transitions, rejection/suspension reasons, profile updates, and audit logging", () => {
    expect(migration).toContain("app.status = 'pending'");
    expect(migration).toContain("p_status IN ('approved', 'rejected')");
    expect(migration).toContain("app.status = 'approved'");
    expect(migration).toContain("p_status = 'suspended'");
    expect(migration).toContain("A reason is required for rejection or suspension");
    expect(migration).toContain("INSERT INTO public.admin_audit_log");
    expect(migration).toContain("UPDATE public.profiles AS p");
  });

  it("returns a safe conflict-of-interest response while preserving authorization errors", () => {
    expect(endpoint).toContain(
      'error.message === "Administrators cannot review their own NGO application"',
    );
    expect(endpoint).toContain(
      'return response({ error: "Administrators cannot review their own applications" }, 403);',
    );
    expect(endpoint).toContain('if (error.code === "42501") return response({ error: "Administrator access required" }, 403);');
  });
});
