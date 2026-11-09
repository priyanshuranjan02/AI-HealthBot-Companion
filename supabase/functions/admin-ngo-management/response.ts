export const hasAdministratorRole = (role: unknown): boolean => role === "admin";

export const availableReviewActions = (status: unknown): Array<"approved" | "rejected" | "suspended" | "reinstate"> => {
  if (status === "pending") return ["approved", "rejected"];
  if (status === "approved") return ["suspended"];
  if (status === "suspended") return ["reinstate"];
  return [];
};

export const minimizeNgoApplication = (application: {
  id: string;
  organization_name: string;
  registration_identifier: string;
  official_contact_email: string;
  official_contact_phone: string;
  website: string | null;
  status: string;
  created_at: string;
  decided_at?: string | null;
  review_reason?: string | null;
  evidence_references?: unknown;
  [key: string]: unknown;
}) => {
  return {
    id: application.id,
    organization_name: application.organization_name,
    registration_identifier: application.registration_identifier,
    official_contact_email: application.official_contact_email,
    official_contact_phone: application.official_contact_phone,
    website: application.website,
    status: application.status,
    created_at: application.created_at,
    decided_at: application.decided_at ?? null,
    review_reason: application.review_reason ?? null,
    evidenceCount: Array.isArray(application.evidence_references)
      ? application.evidence_references.length
      : 0,
  };
};
