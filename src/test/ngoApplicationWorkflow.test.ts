import { describe, expect, it, vi } from "vitest";
import {
  ngoApplicationWorkflow,
  type NgoApplicationServices,
  type NgoApplicationStatus,
} from "../../supabase/functions/ngo-application/workflow";

const services = (overrides: Partial<NgoApplicationServices> = {}): NgoApplicationServices => ({
  getUserId: vi.fn(async () => "verified-applicant"),
  getStatus: vi.fn(async () => ({ profileRole: "user", application: null })),
  submit: vi.fn(async () => ({ applicationId: "application-1" })),
  ...overrides,
});

const validSubmission = {
  organizationName: "Example Health NGO",
  registrationIdentifier: "REG-100",
  officialContactEmail: "contact@example.invalid",
  officialContactPhone: "+10000000000",
  website: "",
  evidenceReferences: [],
};

const application = (status: NgoApplicationStatus["status"] = "pending"): NgoApplicationStatus => ({
  id: "application-1",
  organization_name: "Example Health NGO",
  registration_identifier: "REG-100",
  official_contact_email: "contact@example.invalid",
  official_contact_phone: "+10000000000",
  website: "https://example.invalid",
  status,
  review_reason: null,
  decided_at: null,
  created_at: "2026-10-31T00:00:00Z",
});

describe("NGO application server workflow", () => {
  it("requires a verified session before loading status", async () => {
    const deps = services({ getUserId: vi.fn(async () => null) });
    expect(await ngoApplicationWorkflow("invalid", "status", {}, deps)).toEqual({ status: 401, body: { error: "Invalid or expired session" } });
    expect(deps.getStatus).not.toHaveBeenCalled();
  });

  it("derives the status lookup identity from the verified token and ignores caller user IDs", async () => {
    const deps = services();
    await ngoApplicationWorkflow("valid-token", "status", { userId: "attacker-chosen-id" }, deps);
    expect(deps.getStatus).toHaveBeenCalledWith("verified-applicant");
  });

  it.each([
    ["user", null, true, false],
    ["user", "pending", false, false],
    ["user", "rejected", true, false],
    ["user", "suspended", false, false],
    ["ngo", "approved", false, true],
    ["ngo", "pending", false, false],
    ["user", "approved", false, false],
    ["ngo", null, false, false],
    ["admin", null, false, false],
    [null, null, false, false],
  ] as const)("reports safe eligibility for profile/application state %s/%s", async (profileRole, state, canSubmit, dashboardAvailable) => {
    const currentApplication = state ? application(state) : null;
    const result = await ngoApplicationWorkflow("valid-token", "status", {}, services({
      getStatus: vi.fn(async () => ({ profileRole, application: currentApplication })),
    }));
    expect(result.body).toMatchObject({ canSubmit, dashboardAvailable, application: currentApplication, profileRole });
  });

  it("returns only the allowlisted own-application fields", async () => {
    const privateFields = {
      ...application("approved"),
      applicant_user_id: "private-applicant-id",
      reviewer_id: "private-reviewer-id",
      evidence_references: ["private-evidence"],
      audit_details: { private: true },
    } as unknown as NgoApplicationStatus;
    const result = await ngoApplicationWorkflow("valid-token", "status", {}, services({
      getStatus: vi.fn(async () => ({ profileRole: "ngo", application: privateFields })),
    }));
    expect(result.body).toEqual({
      application: application("approved"),
      profileRole: "ngo",
      canSubmit: false,
      dashboardAvailable: true,
    });
    expect(JSON.stringify(result.body)).not.toContain("private");
  });

  it("fails closed when the status lookup fails", async () => {
    const result = await ngoApplicationWorkflow("valid-token", "status", {}, services({
      getStatus: vi.fn(async () => { throw new Error("database unavailable"); }),
    }));
    expect(result.status).toBe(500);
    expect(result.body).toEqual({ error: "Unable to load NGO application status" });
  });

  it("uses the token identity for submission and ignores caller identity fields", async () => {
    const deps = services();
    const result = await ngoApplicationWorkflow("valid-token", "submit", { ...validSubmission, userId: "attacker-chosen-id" }, deps);
    expect(result.status).toBe(201);
    expect(deps.submit).toHaveBeenCalledWith("verified-applicant", validSubmission);
  });

  it.each([
    ["pending", "user", 409],
    ["approved", "ngo", 403],
    ["suspended", "user", 403],
  ] as const)("does not allow a %s application to be resubmitted", async (state, profileRole, expectedStatus) => {
    const deps = services({ getStatus: vi.fn(async () => ({ profileRole, application: application(state) })) });
    expect((await ngoApplicationWorkflow("valid-token", "submit", validSubmission, deps)).status).toBe(expectedStatus);
    expect(deps.submit).not.toHaveBeenCalled();
  });

  it("allows a rejected standard-user application to resubmit", async () => {
    const rejected = { ...application("rejected"), review_reason: "Please provide updated details.", decided_at: "2026-10-31T00:00:00Z" };
    const deps = services({ getStatus: vi.fn(async () => ({ profileRole: "user", application: rejected })) });
    expect((await ngoApplicationWorkflow("valid-token", "submit", validSubmission, deps)).status).toBe(201);
    expect(deps.submit).toHaveBeenCalledWith("verified-applicant", validSubmission);
  });

  it("rejects invalid payloads without calling the submission RPC", async () => {
    const deps = services();
    const result = await ngoApplicationWorkflow("valid-token", "submit", { ...validSubmission, evidenceReferences: [""] }, deps);
    expect(result.status).toBe(400);
    expect(deps.submit).not.toHaveBeenCalled();
  });
});
