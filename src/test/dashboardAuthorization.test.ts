import { describe, expect, it, vi } from "vitest";
import { dashboardStatsWorkflow } from "../../supabase/functions/dashboard-stats/workflow";

const services = (overrides: Partial<Parameters<typeof dashboardStatsWorkflow>[1]> = {}) => ({
  getUserId: vi.fn(async () => "ngo-user"),
  getProfileRole: vi.fn(async () => "ngo"),
  getLatestApplicationStatus: vi.fn(async () => "approved"),
  getStats: vi.fn(async () => ({ privacySuppressed: true, totalChecks: null })),
  ...overrides,
});

describe("server-side NGO analytics authorization", () => {
  it("rejects unauthenticated and invalid sessions before any database lookup", async () => {
    const missingTokenServices = services();
    expect((await dashboardStatsWorkflow(null, missingTokenServices)).status).toBe(401);
    expect(missingTokenServices.getUserId).not.toHaveBeenCalled();
    expect(missingTokenServices.getStats).not.toHaveBeenCalled();

    const invalidServices = services({ getUserId: vi.fn(async () => null) });
    expect((await dashboardStatsWorkflow("bad-token", invalidServices)).status).toBe(401);
    expect(invalidServices.getProfileRole).not.toHaveBeenCalled();
    expect(invalidServices.getStats).not.toHaveBeenCalled();
  });

  it.each(["pending", "rejected", "suspended", null])(
    "denies a %s latest application without invoking analytics",
    async (status) => {
      const deps = services({ getLatestApplicationStatus: vi.fn(async () => status) });
      const result = await dashboardStatsWorkflow("valid-token", deps);
      expect(result.status).toBe(403);
      expect(deps.getStats).not.toHaveBeenCalled();
    },
  );

  it("denies approved status when the persisted profile role is not NGO", async () => {
    const deps = services({ getProfileRole: vi.fn(async () => "user") });
    expect((await dashboardStatsWorkflow("valid-token", deps)).status).toBe(403);
    expect(deps.getLatestApplicationStatus).not.toHaveBeenCalled();
    expect(deps.getStats).not.toHaveBeenCalled();
  });

  it("rejects a standard user before checking an application or invoking analytics", async () => {
    const deps = services({ getProfileRole: vi.fn(async () => "user") });
    expect((await dashboardStatsWorkflow("valid-token", deps)).status).toBe(403);
    expect(deps.getLatestApplicationStatus).not.toHaveBeenCalled();
    expect(deps.getStats).not.toHaveBeenCalled();
  });

  it("invokes the aggregate RPC only after both persisted checks pass", async () => {
    const order: string[] = [];
    const deps = services();
    deps.getUserId = vi.fn(async () => { order.push("identity"); return "ngo-user"; });
    deps.getProfileRole = vi.fn(async () => { order.push("profile-role"); return "ngo"; });
    deps.getLatestApplicationStatus = vi.fn(async () => { order.push("latest-application"); return "approved"; });
    deps.getStats = vi.fn(async () => { order.push("analytics-rpc"); return { privacySuppressed: true, totalChecks: null }; });
    const result = await dashboardStatsWorkflow("valid-token", deps);
    expect(result).toEqual({ status: 200, body: { privacySuppressed: true, totalChecks: null } });
    expect(deps.getUserId).toHaveBeenCalledOnce();
    expect(deps.getProfileRole).toHaveBeenCalledWith("ngo-user");
    expect(deps.getLatestApplicationStatus).toHaveBeenCalledWith("ngo-user");
    expect(deps.getStats).toHaveBeenCalledOnce();
    expect(order).toEqual(["identity", "profile-role", "latest-application", "analytics-rpc"]);
  });

  it("fails closed on missing schema or verification lookup failures", async () => {
    const deps = services({ getLatestApplicationStatus: vi.fn(async () => { throw new Error("missing table"); }) });
    expect((await dashboardStatsWorkflow("valid-token", deps)).status).toBe(500);
    expect(deps.getStats).not.toHaveBeenCalled();
  });

  it.each([null, undefined])("fails closed when the analytics RPC returns %s", async (result) => {
    const deps = services({ getStats: vi.fn(async () => result) });
    expect((await dashboardStatsWorkflow("valid-token", deps)).status).toBe(500);
  });

  it("fails closed when the aggregate RPC rejects", async () => {
    const deps = services({ getStats: vi.fn(async () => { throw new Error("function missing"); }) });
    expect((await dashboardStatsWorkflow("valid-token", deps)).status).toBe(500);
  });
});
