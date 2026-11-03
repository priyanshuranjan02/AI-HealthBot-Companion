import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getSession: vi.fn(),
  onAuthStateChange: vi.fn(),
  signInWithPassword: vi.fn(),
  signOut: vi.fn(),
  invoke: vi.fn(),
  navigate: vi.fn(),
}));

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: {
      getSession: mocks.getSession,
      onAuthStateChange: mocks.onAuthStateChange,
      signInWithPassword: mocks.signInWithPassword,
      signUp: vi.fn(),
      signOut: mocks.signOut,
    },
    functions: { invoke: mocks.invoke },
  },
}));

vi.mock("react-router-dom", () => ({ useNavigate: () => mocks.navigate }));

import Auth from "@/pages/Auth";

const session = {
  access_token: "synthetic-session-token",
  user: { id: "synthetic-user", email: "test@example.invalid" },
} as never;

describe("administrator account switching", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getSession.mockResolvedValue({ data: { session }, error: null });
    mocks.onAuthStateChange.mockReturnValue({ data: { subscription: { unsubscribe: vi.fn() } } });
    mocks.signOut.mockResolvedValue({ error: null });
  });

  it("redirects an existing administrator session after backend authorization", async () => {
    mocks.invoke.mockResolvedValue({ data: { applications: [] }, error: null });
    render(<Auth mode="admin" />);

    await waitFor(() => {
      expect(mocks.invoke).toHaveBeenCalledWith("admin-ngo-management", expect.objectContaining({ body: { action: "check-access" } }));
      expect(mocks.navigate).toHaveBeenCalledWith("/admin/ngo-verification", { replace: true });
    });
    expect(mocks.signOut).not.toHaveBeenCalled();
  });

  it("keeps a non-admin on the login page until sign-out completes", async () => {
    mocks.invoke.mockResolvedValue({ data: null, error: { context: new Response(null, { status: 403 }) } });
    let finishSignOut: ((value: { error: null }) => void) | undefined;
    mocks.signOut.mockImplementation(() => new Promise((resolve) => {
      finishSignOut = resolve;
    }));
    render(<Auth mode="admin" />);

    const switchButton = await screen.findByRole("button", { name: /sign out and use another account/i });
    fireEvent.click(switchButton);
    expect(mocks.navigate).not.toHaveBeenCalled();
    expect(mocks.signOut).toHaveBeenCalledWith({ scope: "local" });

    finishSignOut?.({ error: null });
    await screen.findByPlaceholderText("Email address");
    expect(mocks.navigate).not.toHaveBeenCalled();
  });
});
