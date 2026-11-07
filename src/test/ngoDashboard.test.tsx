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
    if (state === "suspended") expect(screen.getByText(/resubmission is not available from this state/i)).toBeInTheDocument();
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

  it("renders aggregate charts only for an explicitly released valid response", async () => {
    mocks.invoke.mockImplementation(async (name: string) => name === "ngo-application"
      ? { data: statusResponse(application("approved"), "ngo"), error: null }
      : { data: releasedAnalytics, error: null });
    mountDirectDashboardRoute();
    expect(await screen.findByText("Total Assessments")).toBeInTheDocument();
    expect(screen.getByText("Most Common Diagnoses")).toBeInTheDocument();
    expect(screen.getByText("Most Common Symptoms")).toBeInTheDocument();
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
