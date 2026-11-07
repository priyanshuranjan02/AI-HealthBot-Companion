export type NgoApplicationStatus = {
  id: string;
  organization_name: string;
  registration_identifier: string;
  official_contact_email: string;
  official_contact_phone: string;
  website: string | null;
  status: "pending" | "approved" | "rejected" | "suspended";
  review_reason: string | null;
  decided_at: string | null;
  created_at: string;
};

export type NgoApplicationStatusResponse = {
  application: NgoApplicationStatus | null;
  profileRole: string | null;
  canSubmit: boolean;
  dashboardAvailable: boolean;
};

export type NgoApplicationInput = {
  organizationName: string;
  registrationIdentifier: string;
  officialContactEmail: string;
  officialContactPhone: string;
  website: string;
  evidenceReferences: string[];
};

export type NgoApplicationServices = {
  getUserId: (accessToken: string) => Promise<string | null>;
  getStatus: (userId: string) => Promise<{ profileRole: string | null; application: NgoApplicationStatus | null }>;
  submit: (userId: string, input: NgoApplicationInput) => Promise<{ applicationId: string | null; errorCode?: string }>;
};

export type NgoApplicationResult = { status: number; body: Record<string, unknown> };
const failure = (status: number, error: string): NgoApplicationResult => ({ status, body: { error } });
const isText = (value: unknown, max: number) => typeof value === "string" && value.trim().length > 0 && value.length <= max;
const applicationStatuses = new Set(["pending", "approved", "rejected", "suspended"]);

/** Rebuild the status object from the response allowlist so database or service
 * client fields added later cannot leak applicant IDs, evidence, or audit data. */
const safeApplicationProjection = (application: NgoApplicationStatus | null) => {
  if (!application) return null;
  if (!applicationStatuses.has(application.status)) {
    throw new Error("Unsupported NGO application status");
  }
  return {
    id: application.id,
    organization_name: application.organization_name,
    registration_identifier: application.registration_identifier,
    official_contact_email: application.official_contact_email,
    official_contact_phone: application.official_contact_phone,
    website: application.website,
    status: application.status,
    review_reason: application.review_reason,
    decided_at: application.decided_at,
    created_at: application.created_at,
  } satisfies NgoApplicationStatus;
};

/** The authenticated identity always comes from token validation, never from
 * a caller-supplied user ID. Application persistence remains in the audited RPC. */
export const ngoApplicationWorkflow = async (
  accessToken: string | null,
  action: unknown,
  payload: unknown,
  services: NgoApplicationServices,
): Promise<NgoApplicationResult> => {
  if (!accessToken) return failure(401, "Authentication required");

  let userId: string | null;
  try {
    userId = await services.getUserId(accessToken);
  } catch {
    return failure(503, "Unable to verify session");
  }
  if (!userId) return failure(401, "Invalid or expired session");

  try {
    if (action === "status") {
      const current = await services.getStatus(userId);
      const application = safeApplicationProjection(current.application);
      return {
        status: 200,
        body: {
          application,
          profileRole: current.profileRole,
          canSubmit: current.profileRole === "user" && (!application || application.status === "rejected"),
          dashboardAvailable: current.profileRole === "ngo" && application?.status === "approved",
        },
      };
    }

    if (action !== "submit") return failure(400, "Invalid application action");
    const current = await services.getStatus(userId);
    if (current.profileRole !== "user") {
      return failure(403, "Only standard user accounts may submit NGO applications");
    }
    if (current.application?.status === "pending") {
      return failure(409, "You already have a pending NGO application");
    }
    // Rejected applications may be resubmitted. Approved and suspended
    // applications cannot use this endpoint to bypass their workflow state.
    if (current.application && current.application.status !== "rejected") {
      return failure(403, "This application state does not permit resubmission");
    }

    const body = (payload && typeof payload === "object" ? payload : {}) as Record<string, unknown>;
    const { organizationName, registrationIdentifier, officialContactEmail, officialContactPhone } = body;
    const website = body.website == null ? "" : body.website;
    const evidenceReferences = body.evidenceReferences ?? [];
    if (
      !isText(organizationName, 200) || !isText(registrationIdentifier, 160) ||
      !isText(officialContactEmail, 320) || !isText(officialContactPhone, 64) ||
      (website !== "" && !isText(website, 2048)) || !Array.isArray(evidenceReferences) ||
      evidenceReferences.length > 10 || evidenceReferences.some((item) => !isText(item, 2048))
    ) return failure(400, "Invalid application details");

    const result = await services.submit(userId, {
      organizationName: (organizationName as string).trim(),
      registrationIdentifier: (registrationIdentifier as string).trim(),
      officialContactEmail: (officialContactEmail as string).trim(),
      officialContactPhone: (officialContactPhone as string).trim(),
      website: (website as string).trim(),
      evidenceReferences: evidenceReferences.map((item: string) => item.trim()),
    });
    if (result.errorCode === "42501") return failure(403, "Application is not permitted for this account");
    if (result.errorCode === "23505") return failure(409, "You already have a pending NGO application");
    if (result.errorCode || !result.applicationId) return failure(500, "Unable to submit application");
    return { status: 201, body: { applicationId: result.applicationId, status: "pending" } };
  } catch {
    return failure(500, action === "status" ? "Unable to load NGO application status" : "Unable to submit application");
  }
};
