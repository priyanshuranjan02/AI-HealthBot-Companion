import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter, Route, Routes } from "react-router-dom";

const mocks = vi.hoisted(() => ({ getSession: vi.fn(), invoke: vi.fn() }));

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: { getSession: mocks.getSession },
    functions: { invoke: mocks.invoke },
  },
}));

import AdminDashboard from "@/pages/AdminDashboard";
import { availableReviewActions } from "../../supabase/functions/admin-ngo-management/response";

const application = (status: "pending" | "approved" | "rejected" | "suspended") => ({
  id: "application-0001",
  organization_name: "Example Community Health",
  registration_identifier: "REG-0001",
  official_contact_email: "contact@example.invalid",
  official_contact_phone: "+10000000000",
  website: null,
  evidenceCount: 0,
  status,
  created_at: "2026-10-01T00:00:00Z",
  decided_at: status === "suspended" ? "2026-10-02T00:00:00Z" : null,
  review_reason: status === "suspended" ? "Prior suspension reason" : null,
});

const listResponse = (status: "pending" | "approved" | "rejected" | "suspended") => ({
  counts: { totalApplications: 1 },
  applications: [application(status)],
});

const mountAdmin = () => render(
  <MemoryRouter initialEntries={["/admin/dashboard"]} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
    <Routes><Route path="/admin/dashboard" element={<AdminDashboard />} /></Routes>
  </MemoryRouter>,
);

describe("Admin NGO reinstatement dashboard", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getSession.mockResolvedValue({ data: { session: { access_token: "verified-token" } } });
    mocks.invoke.mockResolvedValue({ data: listResponse("suspended"), error: null });
  });

  afterEach(() => cleanup());

  it("offers reinstatement only for suspended applications", () => {
    expect(availableReviewActions("suspended")).toEqual(["reinstate"]);
    expect(availableReviewActions("pending")).not.toContain("reinstate");
    expect(availableReviewActions("rejected")).not.toContain("reinstate");
    expect(availableReviewActions("approved")).not.toContain("reinstate");
  });

  it("requires a reason, submits the distinct action and refreshes after success", async () => {
    let reinstated = false;
    mocks.invoke.mockImplementation(async (_name: string, options?: { body?: { action?: string } }) => {
      if (options?.body?.action === "reinstate") {
        reinstated = true;
        return { data: { success: true }, error: null };
      }
      return { data: listResponse(reinstated ? "approved" : "suspended"), error: null };
    });

    mountAdmin();
    const button = await screen.findByRole("button", { name: "Reinstate NGO access" });
    expect(screen.getByRole("textbox", { name: "Reinstatement reason" })).toBeRequired();
    fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent("A reinstatement reason is required");
    expect(mocks.invoke).toHaveBeenCalledTimes(1);

    fireEvent.change(screen.getByRole("textbox", { name: "Reinstatement reason" }), {
      target: { value: "Eligibility evidence was reviewed" },
    });
    fireEvent.click(button);

    await waitFor(() => expect(mocks.invoke).toHaveBeenCalledTimes(3));
    expect(mocks.invoke.mock.calls[1][1]).toMatchObject({
      body: {
        action: "reinstate",
        applicationId: "application-0001",
        reason: "Eligibility evidence was reviewed",
      },
    });
    expect(mocks.invoke.mock.calls[2][1]).toMatchObject({ body: {} });
    await waitFor(() => expect(screen.queryByRole("button", { name: "Reinstate NGO access" })).not.toBeInTheDocument());
  });

  it.each(["pending", "rejected", "approved"] as const)(
    "does not show reinstatement for %s applications",
    async (status) => {
      mocks.invoke.mockResolvedValue({ data: listResponse(status), error: null });
      mountAdmin();
      await screen.findByText("Example Community Health");
      expect(screen.queryByRole("button", { name: "Reinstate NGO access" })).not.toBeInTheDocument();
    },
  );

  it("shows the conflict message for a stale application response", async () => {
    mocks.invoke.mockImplementation(async (_name: string, options?: { body?: { action?: string } }) => {
      if (options?.body?.action === "reinstate") {
        return { data: null, error: { context: new Response(null, { status: 409 }) } };
      }
      return { data: listResponse("suspended"), error: null };
    });
    mountAdmin();
    await screen.findByRole("button", { name: "Reinstate NGO access" });
    fireEvent.change(screen.getByRole("textbox", { name: "Reinstatement reason" }), {
      target: { value: "Verified" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Reinstate NGO access" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("no longer eligible for reinstatement");
  });
});
