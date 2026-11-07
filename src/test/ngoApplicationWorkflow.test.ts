import { describe, expect, it, vi } from "vitest";
import { ngoApplicationWorkflow, type NgoApplicationServices } from "../../supabase/functions/ngo-application/workflow";

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

describe("NGO application server workflow", () => {
  it("requires a verified session before loading status", async () => {
    const deps = services({ getUserId: vi.fn(async () => null) });
    expect(await ngoApplicationWorkflow("invalid", "status", {}, deps)).toEqual({
      status: 401,
      body: { error: "Invalid or expired session" },
    });
    expect(deps.getStatus).not.toHaveBeenCalled();
  });

  it("derives the status lookup identity from the verified token", async () => {
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
    ["admin", null, false, false],
  ] as const)("reports application and dashboard eligibility for %s/%s", async (profileRole, state, canSubmit, dashboardAvailable) => {
    const application = state ? {
      id: "application-1",
      organization_name: "Example Health NGO",
      registration_identifier: "REG-1",
      official_contact_email: "ngo@example.org",
      official_contact_phone: "+910000000000",
      website: null,
      status: state,
      review_reason: null,
      decided_at: null,
      created_at: "2026-10-31T00:00:00Z",
    } : null;
    const result = await ngoApplicationWorkflow("valid-token", "status", {}, services({
      getStatus: vi.fn(async () => ({ profileRole, application })),
    }));
    expect(result.body).toMatchObject({ canSubmit, dashboardAvailable, application });
  });

  it("uses the token identity for submission and ignores caller identity fields", async () => {
    const deps = services();
    const result = await ngoApplicationWorkflow("valid-token", "submit", {
      ...validSubmission,
      userId: "attacker-chosen-id",
    }, deps);
    expect(result.status).toBe(201);
    expect(deps.submit).toHaveBeenCalledWith("verified-applicant", validSubmission);
  });

  it.each([
    ["pending", "user", 409],
    ["approved", "ngo", 403],
    ["suspended", "user", 403],
  ] as const)("does not allow a %s application to be resubmitted", async (state, profileRole, expectedStatus) => {
    const deps = services({
      getStatus: vi.fn(async () => ({
        profileRole,
        application: {
          id: "application-1",
          organization_name: "Example Health NGO",
          registration_identifier: "REG-1",
          official_contact_email: "ngo@example.org",
          official_contact_phone: "+910000000000",
          website: null,
          status: state,
          review_reason: null,
          decided_at: null,
          created_at: "2026-10-31T00:00:00Z",
        },
      })),
    });

    expect((await ngoApplicationWorkflow("valid-token", "submit", validSubmission, deps)).status).toBe(expectedStatus);
    expect(deps.submit).not.toHaveBeenCalled();
  });

  it("allows a rejected standard-user application to resubmit", async () => {
    const deps = services({
      getStatus: vi.fn(async () => ({
        profileRole: "user",
        application: {
          id: "application-1",
          organization_name: "Example Health NGO",
          registration_identifier: "REG-1",
          official_contact_email: "ngo@example.org",
          official_contact_phone: "+910000000000",
          website: null,
          status: "rejected" as const,
          review_reason: "Please provide updated details.",
          decided_at: "2026-10-31T00:00:00Z",
          created_at: "2026-10-30T00:00:00Z",
        },
      })),
    });
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
