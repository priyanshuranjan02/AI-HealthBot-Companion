export type DashboardStatsServices = {
  getUserId: (accessToken: string) => Promise<string | null>;
  getProfileRole: (userId: string) => Promise<string | null>;
  getLatestApplicationStatus: (userId: string) => Promise<string | null>;
  getStats: () => Promise<unknown | null>;
};

export type DashboardStatsResult = { status: number; body: unknown };

const failure = (status: number, error: string): DashboardStatsResult => ({
  status,
  body: { error },
});

/** Server-side gate: never call the aggregate RPC until identity, role, and
 * the applicant's latest persisted application status have all been checked. */
export const dashboardStatsWorkflow = async (
  accessToken: string | null,
  services: DashboardStatsServices,
): Promise<DashboardStatsResult> => {
  if (!accessToken) return failure(401, "Authentication required");

  let userId: string | null;
  try {
    userId = await services.getUserId(accessToken);
  } catch {
    return failure(503, "Unable to verify session");
  }
  if (!userId) return failure(401, "Invalid or expired session");

  try {
    const profileRole = await services.getProfileRole(userId);
    if (profileRole !== "ngo") {
      return failure(403, "Forbidden: NGO access required");
    }

    const latestApplicationStatus = await services.getLatestApplicationStatus(userId);
    if (latestApplicationStatus !== "approved") {
      return failure(403, "Forbidden: approved NGO verification required");
    }

    const stats = await services.getStats();
    if (stats === null || stats === undefined) {
      return failure(500, "Unable to load dashboard statistics");
    }
    return { status: 200, body: stats };
  } catch {
    // Missing tables/functions and lookup failures fail closed before stats.
    return failure(500, "Unable to verify or load dashboard data");
  }
};
