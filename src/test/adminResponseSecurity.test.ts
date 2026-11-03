import { describe, expect, it } from "vitest";
import { availableReviewActions, hasAdministratorRole, minimizeNgoApplication } from "../../supabase/functions/admin-ngo-management/response";

describe("admin authorization and response minimization", () => {
  it("accepts only the persisted admin role", () => {
    expect(hasAdministratorRole("admin")).toBe(true);
    expect(hasAdministratorRole("user")).toBe(false);
    expect(hasAdministratorRole("ngo")).toBe(false);
    expect(hasAdministratorRole(undefined)).toBe(false);
  });

  it("exposes only database-supported review transitions for each application state", () => {
    expect(availableReviewActions("pending")).toEqual(["approved", "rejected"]);
    expect(availableReviewActions("approved")).toEqual(["suspended"]);
    expect(availableReviewActions("rejected")).toEqual([]);
    expect(availableReviewActions("suspended")).toEqual([]);
  });

  it("omits applicant identifiers and evidence references from the browser response", () => {
    const result = minimizeNgoApplication({
      id: "application-id",
      applicant_user_id: "private-user-id",
      organization_name: "Example NGO",
      registration_identifier: "REG-1",
      official_contact_email: "contact@example.invalid",
      official_contact_phone: "0000000000",
      website: null,
      status: "pending",
      created_at: "2026-10-26T00:00:00Z",
      evidence_references: ["private://reference-a", "private://reference-b"],
      reviewer_id: "reviewer-id",
      review_reason: "internal reason",
    });
    expect(result).toEqual({
      id: "application-id",
      organization_name: "Example NGO",
      registration_identifier: "REG-1",
      official_contact_email: "contact@example.invalid",
      official_contact_phone: "0000000000",
      website: null,
      status: "pending",
      created_at: "2026-10-26T00:00:00Z",
      decided_at: null,
      review_reason: "internal reason",
      evidenceCount: 2,
    });
    expect(result).not.toHaveProperty("applicant_user_id");
    expect(result).not.toHaveProperty("reviewer_id");
    expect(result.review_reason).toBe("internal reason");
    expect(result).not.toHaveProperty("evidence_references");
  });
});
