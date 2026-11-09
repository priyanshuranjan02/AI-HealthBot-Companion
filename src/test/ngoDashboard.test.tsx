import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter, Route, Routes } from "react-router-dom";

const mocks = vi.hoisted(() => ({
  getSession: vi.fn(),
  onAuthStateChange: vi.fn(),
  invoke: vi.fn(),
  unsubscribe: vi.fn(),
}));

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: { getSession: mocks.getSession, onAuthStateChange: mocks.onAuthStateChange },
    functions: { invoke: mocks.invoke },
  },
}));

vi.mock("recharts", () => {
  const Stub = () => null;
  return {
    Area: Stub,
    AreaChart: Stub,
    Bar: Stub,
    BarChart: Stub,
    CartesianGrid: Stub,
    Cell: Stub,
    Legend: Stub,
    Line: Stub,
    LineChart: Stub,
    Pie: Stub,
    PieChart: Stub,
    ResponsiveContainer: Stub,
    Tooltip: Stub,
    XAxis: Stub,
    YAxis: Stub,
  };
});

import Dashboard from "@/pages/Dashboard";
import RequireSession from "@/components/RequireSession";

const application = (status: "pending" | "approved" | "rejected" | "suspended") => ({
  id: "application-id",
  organization_name: "Example Community Health",
  registration_identifier: "REG-42",
  official_contact_email: "contact@example.invalid",
  official_contact_phone: "+10000000000",
  website: "https://example.invalid",
  status,
  review_reason: status === "rejected" || status === "suspended" ? "Please contact support." : null,
  decided_at: status === "approved" || status === "rejected" || status === "suspended" ? "2026-10-31T00:00:00Z" : null,
  created_at: "2026-10-01T00:00:00Z",
});

const statusResponse = (app: ReturnType<typeof application> | null, profileRole: string | null) => ({
  application: app,
  profileRole,
  canSubmit: profileRole === "user" && (!app || app.status === "rejected"),
  dashboardAvailable: profileRole === "ngo" && app?.status === "approved",
});

const releasedAnalytics = {
  privacySuppressed: false,
  totalChecks: 12,
  totalUsers: 10,
  severityCounts: { low: 6, moderate: 4, high: 2 },
  topDiagnoses: [{ name: "Example diagnosis", count: 4 }],
  dailyChecks: [{ date: "2026-10-31", count: 2 }],
  monthlyAssessments: [{ month: "2026-10", count: 12 }],
  predictionTrend: [{ date: "2026-10-31", low: 1, moderate: 1, high: 0 }],
  languageDistribution: { en: 12 },
  languageBreakdown: [{ name: "English", count: 12 }],
  topSymptoms: [{ name: "Example symptom", count: 3 }],
  avgConfidence: 82,
  highRiskCases: 2,
  minimumCohort: 10,
  suppressedBreakdowns: [],
};

const fullySuppressedProductionAnalytics = {
  privacySuppressed: true,
  totalChecks: null,
  totalUsers: null,
  severityCounts: { low: null, moderate: null, high: null },
  topDiagnoses: [],
  dailyChecks: [],
  monthlyAssessments: [],
  predictionTrend: [],
  languageDistribution: {},
  languageBreakdown: [],
  topSymptoms: [],
  avgConfidence: null,
  highRiskCases: null,
  minimumCohort: 10,
  suppressedBreakdowns: ["all"],
};

const mountDirectDashboardRoute = () => render(
  <MemoryRouter initialEntries={["/ngo/dashboard"]} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
    <Routes>
      <Route path="/ngo/dashboard" element={<RequireSession loginPath="/ngo/login"><Dashboard /></RequireSession>} />
      <Route path="/ngo/login" element={<h1>NGO login</h1>} />
    </Routes>
  </MemoryRouter>,
);

describe("NGO organization dashboard", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getSession.mockResolvedValue({ data: { session: { access_token: "verified-token" } } });
    mocks.onAuthStateChange.mockReturnValue({ data: { subscription: { unsubscribe: mocks.unsubscribe } } });
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("pending"), "user"), error: null }
      : { data: { privacySuppressed: true, totalChecks: null }, error: null });
  });

  afterEach(() => cleanup());

  it("verifies the latest approved application before requesting analytics", async () => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: { privacySuppressed: true, totalChecks: null }, error: null });

    mountDirectDashboardRoute();

    expect((await screen.findAllByText("Example Community Health")).length).toBe(2);
    expect(screen.getByText("Organization profile")).toBeInTheDocument();
    expect(screen.getByText("Verification timeline")).toBeInTheDocument();
    expect(screen.getByText("Health statistics are currently withheld")).toBeInTheDocument();
    expect(mocks.invoke.mock.calls.map(([name]) => name)).toEqual(["ngo-application", "dashboard-stats"]);
    expect(screen.queryByText(/reviewer|evidence references|audit details/i)).not.toBeInTheDocument();
  });

  it.each([
    ["pending", "user", "Application pending review", false],
    ["rejected", "user", "Application update available", true],
    ["suspended", "user", "Application suspended", false],
  ] as const)("shows the %s portal state without loading analytics", async (state, role, heading, canSubmit) => {
    mocks.invoke.mockResolvedValue({ data: statusResponse(application(state), role), error: null });
    mountDirectDashboardRoute();

    expect(await screen.findByRole("heading", { name: heading })).toBeInTheDocument();
    expect(mocks.invoke.mock.calls.map(([name]) => name)).toEqual(["ngo-application"]);
    if (canSubmit) expect(screen.getByRole("link", { name: /application/i })).toBeInTheDocument();
    else expect(screen.queryByRole("link", { name: /application/i })).not.toBeInTheDocument();
    if (state === "suspended") {
      expect(screen.getByText(/contact an administrator through support to request a review for reinstatement/i)).toBeInTheDocument();
      expect(screen.getByText(/only an administrator can restore access; you cannot reinstate your own account/i)).toBeInTheDocument();
      expect(screen.queryByText(/admin dashboard does not yet offer reinstatement/i)).not.toBeInTheDocument();
    }
  });

  it("shows the application portal for an eligible account with no application", async () => {
    mocks.invoke.mockResolvedValue({ data: statusResponse(null, "user"), error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByRole("link", { name: "Open NGO application portal" })).toHaveAttribute("href", "/ngo/application");
    expect(mocks.invoke.mock.calls.map(([name]) => name)).toEqual(["ngo-application"]);
  });

  it("withholds dashboard access when role and approved application disagree", async () => {
    mocks.invoke.mockResolvedValue({ data: statusResponse(application("approved"), "user"), error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByRole("heading", { name: "Organization access needs reconciliation" })).toBeInTheDocument();
    expect(mocks.invoke.mock.calls.map(([name]) => name)).toEqual(["ngo-application"]);
  });

  it("rejects an inconsistent server eligibility response", async () => {
    mocks.invoke.mockResolvedValue({ data: { ...statusResponse(application("pending"), "user"), dashboardAvailable: true }, error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByRole("heading", { name: "Organization access could not be verified" })).toBeInTheDocument();
    expect(mocks.invoke.mock.calls.map(([name]) => name)).toEqual(["ngo-application"]);
  });

  it("does not call NGO endpoints on a signed-out direct route", async () => {
    mocks.getSession.mockResolvedValue({ data: { session: null } });
    mountDirectDashboardRoute();
    expect(await screen.findByRole("heading", { name: "NGO login" })).toBeInTheDocument();
    expect(mocks.invoke).not.toHaveBeenCalled();
  });

  it("removes the approved workspace when the independent stats gate denies access", async () => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: null, error: { context: new Response(null, { status: 403 }) } });
    mountDirectDashboardRoute();
    expect(await screen.findByRole("heading", { name: "Organization access could not be verified" })).toBeInTheDocument();
    expect(screen.queryByText("Example Community Health")).not.toBeInTheDocument();
    expect(mocks.invoke.mock.calls.map(([name]) => name)).toEqual(["ngo-application", "dashboard-stats"]);
  });

  it("keeps malformed or suppressed analytics withheld for an approved organization", async () => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: { privacySuppressed: false, totalChecks: 0 }, error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByText("Health statistics are currently withheld")).toBeInTheDocument();
    expect(screen.queryByText(/assessment summary/i)).not.toBeInTheDocument();
  });

  it("keeps the existing fully suppressed production response withheld", async () => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: fullySuppressedProductionAnalytics, error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByText("Health statistics are currently withheld")).toBeInTheDocument();
    expect(screen.queryByText("Total Assessments")).not.toBeInTheDocument();
    expect(screen.queryByText("Example diagnosis")).not.toBeInTheDocument();
  });

  it("rejects a globally suppressed response even when privacySuppressed is false", async () => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: { ...releasedAnalytics, suppressedBreakdowns: ["all"] }, error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByText("Health statistics are currently withheld")).toBeInTheDocument();
    expect(screen.queryByText("Most Common Diagnoses")).not.toBeInTheDocument();
  });

  it.each([
    ["totalUsers", "totalUsers"],
    ["avgConfidence", "avgConfidence"],
    ["highRiskCases", "highRiskCases"],
  ])("rejects a non-null %s value when that metric is suppressed", async (breakdown, metric) => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: { ...releasedAnalytics, suppressedBreakdowns: [breakdown] }, error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByText("Health statistics are currently withheld")).toBeInTheDocument();
    const metricValues: Record<string, string> = {
      totalUsers: "10",
      avgConfidence: "82%",
      highRiskCases: "2",
    };
    expect(screen.queryByText(metricValues[metric])).not.toBeInTheDocument();
  });

  it("renders explicitly suppressed summary metrics only when their values are null", async () => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: {
          ...releasedAnalytics,
          totalUsers: null,
          avgConfidence: null,
          highRiskCases: null,
          suppressedBreakdowns: ["totalUsers", "avgConfidence", "highRiskCases"],
        }, error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByText("Total Assessments")).toBeInTheDocument();
    expect(screen.getByText("Registered Users").parentElement).toHaveTextContent("Suppressed");
    expect(screen.getByText("Avg Confidence").parentElement).toHaveTextContent("Suppressed");
    expect(screen.getByText("High Risk Cases").parentElement).toHaveTextContent("Suppressed");
    expect(screen.getByText("Most Common Diagnoses")).toBeInTheDocument();
  });

  it("renders aggregate charts only for an explicitly released valid response", async () => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: releasedAnalytics, error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByText("Total Assessments")).toBeInTheDocument();
    expect(screen.getByText("Most Common Diagnoses")).toBeInTheDocument();
    expect(screen.getByText("Most Common Symptoms")).toBeInTheDocument();
    expect(screen.getByText("Registered Users").parentElement).toHaveTextContent("10");
    expect(screen.getByText("Avg Confidence").parentElement).toHaveTextContent("82%");
    expect(screen.getByText("High Risk Cases").parentElement).toHaveTextContent("2");
  });

  it("retries a failed status verification", async () => {
    mocks.invoke.mockResolvedValueOnce({ data: null, error: new Error("unavailable") })
      .mockResolvedValueOnce({ data: statusResponse(application("pending"), "user"), error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByRole("heading", { name: "Organization access could not be verified" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry access check" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Application pending review" })).toBeInTheDocument());
  });
});
