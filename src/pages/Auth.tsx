import { useState, useEffect, useRef } from "react";
import { useNavigate } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/integrations/supabase/client";
import { Mail, Lock, ArrowLeft, Loader2 } from "lucide-react";
import { toast } from "sonner";
import ThemeToggle from "@/components/ThemeToggle";
import { clearPasswordRecoverySession, getPasswordRecoverySession } from "@/lib/authRecoverySignal";

type AuthMode = "standard" | "admin" | "ngo";
type RecoveryState = "none" | "pending" | "ready" | "invalid" | "completed";
const RESET_REQUEST_MESSAGE = "If an account exists for that email, a reset link will be sent. Check your inbox or try again later.";

function recoveryUrlState(): RecoveryState {
  const search = new URLSearchParams(window.location.search);
  const hash = new URLSearchParams(window.location.hash.slice(1));
  if (search.has("error") || search.has("error_code") || hash.has("error") || hash.has("error_code")) return "invalid";
  if (search.get("recovery") === "1" || hash.get("type") === "recovery") return "pending";
  return "none";
}

const Auth = ({ mode = "standard" }: { mode?: AuthMode }) => {
  const loginOnly = mode !== "standard";
  const destination = mode === "admin" ? "/admin/ngo-verification" : mode === "ngo" ? "/ngo/application" : "/";
  const [isLogin, setIsLogin] = useState(true);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [session, setSession] = useState<Session | null>(null);
  const [sessionReady, setSessionReady] = useState(false);
  const [adminAccess, setAdminAccess] = useState<"checking" | "allowed" | "denied" | "error">("checking");
  const [switchingAccount, setSwitchingAccount] = useState(false);
  const [sessionMessage, setSessionMessage] = useState("");
  const [accessCheckAttempt, setAccessCheckAttempt] = useState(0);
  const [resetRequest, setResetRequest] = useState(false);
  const [recoveryState, setRecoveryState] = useState<RecoveryState>(recoveryUrlState);
  const recoveryStateRef = useRef(recoveryState);
  const authEventObservedRef = useRef(false);
  const [recoverySignOutFailed, setRecoverySignOutFailed] = useState(false);
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const navigate = useNavigate();

  const updateRecoveryState = (next: RecoveryState) => {
    recoveryStateRef.current = next;
    setRecoveryState(next);
  };
  const passwordRecovery = recoveryState === "ready";

  useEffect(() => {
    let active = true;
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, nextSession) => {
      if (active) {
        authEventObservedRef.current = true;
        if (event === "PASSWORD_RECOVERY" && nextSession) {
          updateRecoveryState("ready");
        }
        setSession(nextSession);
        setSessionReady(true);
      }
    });

    void supabase.auth.getSession().then(({ data: { session: currentSession }, error }) => {
      if (!active) return;
      if (!authEventObservedRef.current) setSession(currentSession);
      setSessionReady(true);
      if (error) {
        if (recoveryStateRef.current === "pending") updateRecoveryState("invalid");
        else setSessionMessage("Unable to verify the current session. Try again.");
        return;
      }

      if (recoveryStateRef.current === "pending") {
        const signaledRecovery = getPasswordRecoverySession();
        if (signaledRecovery && currentSession?.access_token === signaledRecovery.access_token) {
          setSession(signaledRecovery);
          updateRecoveryState("ready");
        } else {
          // Supabase emits PASSWORD_RECOVERY just after URL-session processing.
          // Wait for that authenticated signal before treating the link as valid.
          window.setTimeout(() => {
            if (recoveryStateRef.current !== "pending") return;
            const verified = getPasswordRecoverySession();
            if (verified && currentSession?.access_token === verified.access_token) {
              setSession(verified);
              updateRecoveryState("ready");
            } else {
              clearPasswordRecoverySession();
              updateRecoveryState("invalid");
            }
          }, 100);
        }
      }
    }).catch(() => {
      if (!active) return;
      setSessionReady(true);
      if (recoveryStateRef.current === "pending") updateRecoveryState("invalid");
      else setSessionMessage("Unable to verify the current session. Try again.");
    });

    return () => {
      active = false;
      subscription.unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (!sessionReady) return;
    if (!session) {
      setAdminAccess("checking");
      if (mode !== "admin") return;
      return;
    }

    if (recoveryState !== "none") return;

    if (mode !== "admin") {
      navigate(destination, { replace: true });
      return;
    }

    let active = true;
    setAdminAccess("checking");
    void supabase.functions.invoke("admin-ngo-management", {
      headers: { Authorization: `Bearer ${session.access_token}` },
      body: { action: "check-access" },
    }).then(({ error }) => {
      if (!active) return;
      if (!error) {
        setAdminAccess("allowed");
        navigate(destination, { replace: true });
        return;
      }
      const status = error.context instanceof Response ? error.context.status : undefined;
      setAdminAccess(status === 403 ? "denied" : "error");
      if (status === 401) setSessionMessage("Your session expired or is no longer valid. Sign in again.");
      else if (status !== 403) setSessionMessage("Could not verify administrator access. Retry or switch accounts.");
    });

    return () => { active = false; };
  }, [accessCheckAttempt, destination, mode, navigate, recoveryState, session, sessionReady]);

  const switchAccount = async () => {
    setSwitchingAccount(true);
    setSessionMessage("");
    try {
      const { error } = await supabase.auth.signOut({ scope: "local" });
      if (error) throw error;
    } catch {
      setSwitchingAccount(false);
      setSessionMessage("Sign-out failed. Your current account is still active; please retry.");
      return;
    }
    setSwitchingAccount(false);
    setSession(null);
    setSessionReady(true);
    setAdminAccess("checking");
    setEmail("");
    setPassword("");
    setSessionMessage("Signed out. Sign in with the intended administrator account.");
  };

  const finishRecoverySignOut = async () => {
    let signOutFailed = false;
    try {
      const { error } = await supabase.auth.signOut({ scope: "local" });
      signOutFailed = Boolean(error);
    } catch {
      signOutFailed = true;
    }
    if (signOutFailed) {
      setRecoverySignOutFailed(true);
      setSessionMessage("Your password was updated, but this device could not be signed out. Sign out here before continuing.");
      return false;
    }
    clearPasswordRecoverySession();
    setRecoverySignOutFailed(false);
    setSession(null);
    setSessionReady(true);
    updateRecoveryState("none");
    setSessionMessage("Password updated. Sign in with your new password.");
    return true;
  };

  const leaveRecovery = async () => {
    if (recoveryState === "ready" || recoveryState === "completed") {
      const signedOut = await finishRecoverySignOut();
      if (!signedOut) return;
    }
    setResetRequest(false);
    if (recoveryState === "invalid" || recoveryState === "pending") updateRecoveryState("none");
    setNewPassword("");
    setConfirmPassword("");
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (passwordRecovery && newPassword.length < 6) {
      toast.error("Password must be at least 6 characters.");
      return;
    }
    if (passwordRecovery && newPassword !== confirmPassword) {
      toast.error("Passwords do not match.");
      return;
    }
    if (passwordRecovery ? !newPassword.trim() || !confirmPassword : !email.trim() || (!resetRequest && !password.trim())) {
      toast.error("Please fill in all fields");
      return;
    }
    setLoading(true);

    try {
      if (passwordRecovery) {
        const { error } = await supabase.auth.updateUser({ password: newPassword });
        if (error) {
          if (("status" in error && (error.status === 401 || error.status === 403))
            || ("name" in error && error.name === "AuthSessionMissingError")) {
            clearPasswordRecoverySession();
            updateRecoveryState("invalid");
            setNewPassword("");
            setConfirmPassword("");
            setSessionMessage("This password reset link is invalid, expired, or already used. Request a new link.");
          } else {
            toast.error("We could not confirm the password update. Try again, or request a new reset link if this link has expired.");
          }
          return;
        }
        updateRecoveryState("completed");
        setRecoverySignOutFailed(false);
        setNewPassword("");
        setConfirmPassword("");
        await finishRecoverySignOut();
      } else if (resetRequest) {
        const path = mode === "admin" ? "/admin/login?recovery=1" : "/auth?recovery=1";
        const { error } = await supabase.auth.resetPasswordForEmail(email, {
          redirectTo: `${window.location.origin}${path}`,
        });
        if (error) throw error;
        setResetRequest(false);
        setSessionMessage(RESET_REQUEST_MESSAGE);
      } else if (isLogin) {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        toast.success("Logged in successfully!");
      } else {
        const { error } = await supabase.auth.signUp({
          email,
          password,
          options: { emailRedirectTo: window.location.origin },
        });
        if (error) throw error;
        toast.success("Account created! Check your email to verify.");
      }
    } catch (error: unknown) {
      if (resetRequest) {
        setResetRequest(false);
        setSessionMessage(RESET_REQUEST_MESSAGE);
      } else {
        toast.error(error instanceof Error ? error.message : "Authentication failed");
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex min-h-screen flex-col bg-background">
      <nav className="flex items-center justify-between border-b border-border bg-card/80 px-4 py-3 backdrop-blur-md">
        <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors">
          <ArrowLeft className="h-4 w-4" />
          <span className="text-lg font-bold text-foreground">
            <span className="text-gradient-primary">AI</span> HealthBot
          </span>
        </button>
        <ThemeToggle />
      </nav>

      <div className="flex flex-1 items-center justify-center px-4 py-12">
        <div className="w-full max-w-md">
          <div className="rounded-3xl border border-border bg-card p-8 shadow-xl">
            <h1 className="mb-2 text-center text-2xl font-bold text-foreground">
              {passwordRecovery ? "Choose a new password" : resetRequest ? "Reset your password" : mode === "admin" ? "Administrator sign in" : mode === "ngo" ? "NGO sign in" : isLogin ? "Welcome Back" : "Create Account"}
            </h1>
            <p className="mb-8 text-center text-sm text-muted-foreground">
              {passwordRecovery ? "Choose a new password for your account."
                : resetRequest ? "Enter the email address associated with your account."
                : mode === "admin"
                ? "Use an account provisioned with administrator access. Public administrator registration is disabled."
                : mode === "ngo"
                  ? "Sign in to submit an application or check its review status."
                  : isLogin ? "Sign in to access your health history" : "Join AI HealthBot for personalized health insights"}
            </p>

            {sessionMessage && <p className="mb-4 text-sm text-muted-foreground" role="status">{sessionMessage}</p>}

            {!passwordRecovery && mode === "admin" && session && adminAccess === "denied" ? (
              <div className="space-y-4" role="alert">
                <p className="text-sm text-critical">This signed-in account does not have administrator access.</p>
                <button type="button" onClick={() => void switchAccount()} disabled={switchingAccount}
                  className="flex w-full items-center justify-center gap-2 rounded-2xl bg-primary py-3 font-semibold text-primary-foreground disabled:opacity-50">
                  {switchingAccount && <Loader2 className="h-4 w-4 animate-spin" />}
                  Sign out and use another account
                </button>
              </div>
            ) : !passwordRecovery && mode === "admin" && session && adminAccess === "error" ? (
              <div className="space-y-4" role="alert">
                <p className="text-sm text-critical">{sessionMessage || "Administrator access could not be checked."}</p>
                <button type="button" onClick={() => {
                  setSessionMessage("");
                  setAdminAccess("checking");
                  setAccessCheckAttempt((attempt) => attempt + 1);
                }} className="w-full rounded-2xl border border-border py-3 font-semibold">Retry access check</button>
                <button type="button" onClick={() => void switchAccount()} disabled={switchingAccount}
                  className="w-full rounded-2xl bg-primary py-3 font-semibold text-primary-foreground disabled:opacity-50">Sign out and use another account</button>
              </div>
            ) : recoveryState === "pending" ? (
              <div className="flex items-center justify-center gap-2 py-8 text-sm text-muted-foreground" role="status">
                <Loader2 className="h-4 w-4 animate-spin" /> Validating your password reset link…
              </div>
            ) : recoveryState === "invalid" ? (
              <div className="space-y-4" role="alert">
                <p className="text-sm text-critical">{sessionMessage || "This password reset link is invalid, expired, or already used."}</p>
                <button type="button" onClick={() => { updateRecoveryState("none"); setResetRequest(true); setSessionMessage(""); }} className="w-full rounded-2xl bg-primary py-3 font-semibold text-primary-foreground">Request another reset link</button>
                <button type="button" onClick={() => { updateRecoveryState("none"); setSessionMessage(""); }} className="w-full text-sm text-muted-foreground hover:underline">Back to sign in</button>
              </div>
            ) : recoveryState === "completed" ? (
              <div className="space-y-4" role="status">
                <p className="text-sm text-muted-foreground">{sessionMessage || (recoverySignOutFailed ? "Your password was updated, but sign-out did not complete." : "Password updated. Signing out…")}</p>
                {recoverySignOutFailed && <button type="button" onClick={() => void finishRecoverySignOut()} className="w-full rounded-2xl bg-primary py-3 font-semibold text-primary-foreground">Sign out and continue</button>}
              </div>
            ) : !sessionReady || (!passwordRecovery && mode === "admin" && session && adminAccess === "checking") ? (
              <div className="flex items-center justify-center gap-2 py-8 text-sm text-muted-foreground" role="status">
                <Loader2 className="h-4 w-4 animate-spin" /> Checking your session…
              </div>
            ) : <form onSubmit={handleSubmit} className="space-y-4">
              {!passwordRecovery && <div className="relative">
                <Mail className="absolute left-4 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <input
                  type="email"
                  aria-label="Email address"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="Email address"
                  className="w-full rounded-2xl border border-border bg-muted/50 py-3 pl-11 pr-4 text-foreground placeholder:text-muted-foreground focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
                  required
                />
              </div>}
              {passwordRecovery ? <div className="relative">
                <Lock className="absolute left-4 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <input
                  type="password"
                  aria-label="New password"
                  value={newPassword}
                  onChange={(e) => setNewPassword(e.target.value)}
                  placeholder="New password"
                  minLength={6}
                  className="w-full rounded-2xl border border-border bg-muted/50 py-3 pl-11 pr-4 text-foreground placeholder:text-muted-foreground focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
                  required
                />
              </div> : !resetRequest && <div className="relative">
                <Lock className="absolute left-4 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <input
                  type="password"
                  aria-label="Password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="Password"
                  minLength={6}
                  className="w-full rounded-2xl border border-border bg-muted/50 py-3 pl-11 pr-4 text-foreground placeholder:text-muted-foreground focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
                  required
                />
              </div>}
              {passwordRecovery && <div className="relative">
                <Lock className="absolute left-4 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <input
                  type="password"
                  aria-label="Confirm new password"
                  value={confirmPassword}
                  onChange={(e) => setConfirmPassword(e.target.value)}
                  placeholder="Confirm new password"
                  minLength={6}
                  className="w-full rounded-2xl border border-border bg-muted/50 py-3 pl-11 pr-4 text-foreground placeholder:text-muted-foreground focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
                  required
                />
              </div>}
              <button
                type="submit"
                disabled={loading}
                className="flex w-full items-center justify-center gap-2 rounded-2xl bg-primary py-3 font-semibold text-primary-foreground shadow-lg shadow-primary/25 transition-all hover:shadow-xl disabled:opacity-50"
              >
                {loading && <Loader2 className="h-4 w-4 animate-spin" />}
                {passwordRecovery ? "Update password" : resetRequest ? "Send reset link" : isLogin ? "Sign In" : "Create Account"}
              </button>
              {isLogin && !resetRequest && !passwordRecovery && <button type="button" onClick={() => setResetRequest(true)} className="w-full text-sm font-medium text-primary hover:underline">Forgot password?</button>}
              {(resetRequest || passwordRecovery) && <button type="button" onClick={() => void leaveRecovery()} className="w-full text-sm text-muted-foreground hover:underline">Back to sign in</button>}
            </form>}

            {!loginOnly && !resetRequest && !passwordRecovery && <p className="mt-6 text-center text-sm text-muted-foreground">
              {isLogin ? "Don't have an account?" : "Already have an account?"}{" "}
              <button
                onClick={() => setIsLogin(!isLogin)}
                className="font-semibold text-primary hover:underline"
              >
                {isLogin ? "Sign up" : "Sign in"}
              </button>
            </p>}
          </div>
        </div>
      </div>
    </div>
  );
};

export default Auth;
