import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getSession: vi.fn(),
  onAuthStateChange: vi.fn(),
  signInWithPassword: vi.fn(),
  resetPasswordForEmail: vi.fn(),
  updateUser: vi.fn(),
  signOut: vi.fn(),
  invoke: vi.fn(),
  navigate: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
  authListeners: [] as Array<(event: string, session: unknown) => void>,
  recoverySession: null as { access_token: string; user?: unknown } | null,
}));

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: {
      getSession: mocks.getSession,
      onAuthStateChange: mocks.onAuthStateChange,
      signInWithPassword: mocks.signInWithPassword,
      resetPasswordForEmail: mocks.resetPasswordForEmail,
      updateUser: mocks.updateUser,
      signUp: vi.fn(),
      signOut: mocks.signOut,
    },
    functions: { invoke: mocks.invoke },
  },
}));

vi.mock("@/lib/authRecoverySignal", () => ({
  getPasswordRecoverySession: () => mocks.recoverySession,
  clearPasswordRecoverySession: () => { mocks.recoverySession = null; },
}));
vi.mock("react-router-dom", () => ({ useNavigate: () => mocks.navigate }));
vi.mock("sonner", () => ({ toast: { error: mocks.toastError, success: mocks.toastSuccess } }));

import Auth from "@/pages/Auth";

const session = {
  access_token: "synthetic-session-token",
  user: { id: "synthetic-user", email: "test@example.invalid" },
} as never;

describe("administrator account switching", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.history.replaceState({}, "", "/");
    mocks.authListeners.length = 0;
    mocks.recoverySession = null;
    mocks.getSession.mockResolvedValue({ data: { session }, error: null });
    mocks.onAuthStateChange.mockImplementation((callback) => {
      mocks.authListeners.push(callback as (event: string, session: unknown) => void);
      return { data: { subscription: { unsubscribe: vi.fn() } } };
    });
    mocks.signOut.mockResolvedValue({ error: null });
    mocks.signInWithPassword.mockResolvedValue({ error: null });
    mocks.resetPasswordForEmail.mockResolvedValue({ error: null });
    mocks.updateUser.mockResolvedValue({ error: null });
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

  it("submits administrator credentials through Supabase Auth", async () => {
    mocks.getSession.mockResolvedValue({ data: { session: null }, error: null });
    render(<Auth mode="admin" />);
    fireEvent.change(await screen.findByLabelText("Email address"), { target: { value: "admin@example.invalid" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "synthetic-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign In" }));

    await waitFor(() => expect(mocks.signInWithPassword).toHaveBeenCalledWith({
      email: "admin@example.invalid",
      password: "synthetic-password",
    }));
    expect(mocks.toastSuccess).toHaveBeenCalledWith("Logged in successfully!");
  });

  it("surfaces Auth credential failure without treating it as an authorization decision", async () => {
    mocks.getSession.mockResolvedValue({ data: { session: null }, error: null });
    mocks.signInWithPassword.mockResolvedValue({ error: new Error("Invalid login credentials") });
    render(<Auth mode="admin" />);
    fireEvent.change(await screen.findByLabelText("Email address"), { target: { value: "admin@example.invalid" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "wrong-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign In" }));

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalledWith("Invalid login credentials"));
    expect(mocks.invoke).not.toHaveBeenCalled();
  });

  it("denies an authenticated account whose persisted admin role is missing", async () => {
    mocks.invoke.mockResolvedValue({ data: null, error: { context: new Response(null, { status: 403 }) } });
    render(<Auth mode="admin" />);

    expect(await screen.findByText("This signed-in account does not have administrator access.")).toBeInTheDocument();
    expect(mocks.invoke).toHaveBeenCalledWith("admin-ngo-management", expect.objectContaining({ body: { action: "check-access" } }));
    expect(mocks.navigate).not.toHaveBeenCalled();
  });

  it("offers a non-enumerating password reset for the administrator account", async () => {
    mocks.getSession.mockResolvedValue({ data: { session: null }, error: null });
    render(<Auth mode="admin" />);
    fireEvent.click(await screen.findByRole("button", { name: "Forgot password?" }));
    fireEvent.change(screen.getByLabelText("Email address"), { target: { value: "admin@example.invalid" } });
    fireEvent.click(screen.getByRole("button", { name: "Send reset link" }));

    await waitFor(() => expect(mocks.resetPasswordForEmail).toHaveBeenCalledWith("admin@example.invalid", {
      redirectTo: `${window.location.origin}/admin/login?recovery=1`,
    }));
    expect(await screen.findByText("If an account exists for that email, a reset link will be sent. Check your inbox or try again later.")).toBeInTheDocument();
  });

  it("uses a generic reset message when the reset request errors", async () => {
    mocks.getSession.mockResolvedValue({ data: { session: null }, error: null });
    mocks.resetPasswordForEmail.mockResolvedValue({ error: new Error("synthetic reset transport error") });
    render(<Auth mode="admin" />);
    fireEvent.click(await screen.findByRole("button", { name: "Forgot password?" }));
    fireEvent.change(screen.getByLabelText("Email address"), { target: { value: "admin@example.invalid" } });
    fireEvent.click(screen.getByRole("button", { name: "Send reset link" }));

    expect(await screen.findByText("If an account exists for that email, a reset link will be sent. Check your inbox or try again later.")).toBeInTheDocument();
    expect(mocks.toastError).not.toHaveBeenCalledWith("synthetic reset transport error");
  });

  it("does not accept the recovery query parameter without a PASSWORD_RECOVERY session event", async () => {
    window.history.replaceState({}, "", "/admin/login?recovery=1");
    render(<Auth mode="admin" />);

    expect(await screen.findByRole("alert")).toHaveTextContent("invalid, expired, or already used");
    expect(screen.queryByLabelText("New password")).not.toBeInTheDocument();
    expect(mocks.invoke).not.toHaveBeenCalled();
    expect(mocks.navigate).not.toHaveBeenCalled();
  });

  it("fails closed when session validation rejects", async () => {
    window.history.replaceState({}, "", "/auth?recovery=1");
    mocks.getSession.mockRejectedValue(new Error("session storage unavailable"));
    render(<Auth />);

    expect(await screen.findByRole("alert")).toHaveTextContent("invalid, expired, or already used");
    expect(screen.queryByLabelText("New password")).not.toBeInTheDocument();
    expect(mocks.updateUser).not.toHaveBeenCalled();
  });

  it("shows expired Auth callback errors without trusting a previously stored session", async () => {
    window.history.replaceState({}, "", "/auth?recovery=1&error=access_denied&error_code=otp_expired");
    render(<Auth />);

    expect(await screen.findByRole("alert")).toHaveTextContent("invalid, expired, or already used");
    expect(screen.queryByLabelText("New password")).not.toBeInTheDocument();
    expect(mocks.navigate).not.toHaveBeenCalled();
  });

  it("waits for recovery authorization before redirecting when getSession resolves first", async () => {
    window.history.replaceState({}, "", "/admin/login?recovery=1");
    let resolveSession: ((value: { data: { session: typeof session }; error: null }) => void) | undefined;
    mocks.getSession.mockReturnValue(new Promise((resolve) => { resolveSession = resolve; }));
    render(<Auth mode="admin" />);

    expect(screen.getByText("Validating your password reset link…")).toBeInTheDocument();
    await act(async () => {
      mocks.authListeners.forEach((listener) => listener("PASSWORD_RECOVERY", session));
    });
    expect(await screen.findByLabelText("New password")).toBeInTheDocument();
    await act(async () => { resolveSession?.({ data: { session }, error: null }); });

    expect(mocks.navigate).not.toHaveBeenCalled();
    expect(mocks.invoke).not.toHaveBeenCalled();
  });

  it("recognizes a validated recovery event received before the lazy Auth page mounts", async () => {
    window.history.replaceState({}, "", "/auth?recovery=1");
    mocks.recoverySession = session as { access_token: string; user?: unknown };
    render(<Auth />);

    expect(await screen.findByLabelText("New password")).toBeInTheDocument();
    expect(mocks.navigate).not.toHaveBeenCalled();
  });

  it("updates the password from the recovery callback and returns to fresh sign-in", async () => {
    window.history.replaceState({}, "", "/admin/login?recovery=1");
    mocks.recoverySession = session as { access_token: string; user?: unknown };
    render(<Auth mode="admin" />);
    fireEvent.change(await screen.findByLabelText("New password"), { target: { value: "updated-synthetic-password" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "updated-synthetic-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Update password" }));

    await waitFor(() => expect(mocks.updateUser).toHaveBeenCalledWith({ password: "updated-synthetic-password" }));
    expect(mocks.signOut).toHaveBeenCalledWith({ scope: "local" });
    expect(await screen.findByText("Password updated. Sign in with your new password.")).toBeInTheDocument();
    expect(await screen.findByLabelText("Password")).toBeInTheDocument();
  });

  it("requires the existing six-character minimum and matching confirmation", async () => {
    window.history.replaceState({}, "", "/admin/login?recovery=1");
    mocks.recoverySession = session as { access_token: string; user?: unknown };
    render(<Auth mode="admin" />);
    fireEvent.change(await screen.findByLabelText("New password"), { target: { value: "short" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "different" } });
    fireEvent.click(screen.getByRole("button", { name: "Update password" }));

    expect(mocks.updateUser).not.toHaveBeenCalled();
    expect(mocks.toastError).toHaveBeenCalledWith("Password must be at least 6 characters.");
  });

  it("handles a reused recovery link rejected by Auth as invalid", async () => {
    window.history.replaceState({}, "", "/admin/login?recovery=1");
    mocks.recoverySession = session as { access_token: string; user?: unknown };
    mocks.updateUser.mockResolvedValue({ error: Object.assign(new Error("expired"), { status: 401 }) });
    render(<Auth mode="admin" />);
    fireEvent.change(await screen.findByLabelText("New password"), { target: { value: "updated-password" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "updated-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Update password" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("invalid, expired, or already used");
    expect(mocks.signOut).not.toHaveBeenCalled();
    expect(mocks.invoke).not.toHaveBeenCalled();
  });

  it("handles a recovery session that expired before password update", async () => {
    window.history.replaceState({}, "", "/auth?recovery=1");
    mocks.recoverySession = session as { access_token: string; user?: unknown };
    mocks.updateUser.mockResolvedValue({ error: Object.assign(new Error("Auth session missing!"), { name: "AuthSessionMissingError", status: 400 }) });
    render(<Auth />);
    fireEvent.change(await screen.findByLabelText("New password"), { target: { value: "updated-password" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "updated-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Update password" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("invalid, expired, or already used");
    expect(mocks.signOut).not.toHaveBeenCalled();
  });

  it("reports password update success separately if local sign-out then fails", async () => {
    window.history.replaceState({}, "", "/admin/login?recovery=1");
    mocks.recoverySession = session as { access_token: string; user?: unknown };
    mocks.signOut.mockResolvedValue({ error: new Error("local sign-out failed") });
    render(<Auth mode="admin" />);
    fireEvent.change(await screen.findByLabelText("New password"), { target: { value: "updated-password" } });
    fireEvent.change(screen.getByLabelText("Confirm new password"), { target: { value: "updated-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Update password" }));

    expect(await screen.findAllByText("Your password was updated, but this device could not be signed out. Sign out here before continuing.")).toHaveLength(2);
    expect(screen.getByRole("button", { name: "Sign out and continue" })).toBeInTheDocument();
    expect(mocks.updateUser).toHaveBeenCalled();
    expect(mocks.navigate).not.toHaveBeenCalled();
    expect(mocks.invoke).not.toHaveBeenCalled();
    expect(mocks.toastError).not.toHaveBeenCalled();
  });

  it("reports an expired backend session distinctly from missing admin authorization", async () => {
    mocks.invoke.mockResolvedValue({ data: null, error: { context: new Response(null, { status: 401 }) } });
    render(<Auth mode="admin" />);

    const alert = await screen.findByRole("alert");
    expect(within(alert).getByText("Your session expired or is no longer valid. Sign in again.")).toBeInTheDocument();
    expect(within(alert).getByRole("button", { name: "Sign out and use another account" })).toBeInTheDocument();
  });
});
