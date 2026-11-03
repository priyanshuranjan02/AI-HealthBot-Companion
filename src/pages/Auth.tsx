import { useState, useEffect } from "react";
import { useNavigate } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/integrations/supabase/client";
import { Mail, Lock, ArrowLeft, Loader2 } from "lucide-react";
import { toast } from "sonner";
import ThemeToggle from "@/components/ThemeToggle";

type AuthMode = "standard" | "admin" | "ngo";

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
  const navigate = useNavigate();

  useEffect(() => {
    let active = true;
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      if (active) {
        setSession(nextSession);
        setSessionReady(true);
      }
    });

    void supabase.auth.getSession().then(({ data: { session: currentSession }, error }) => {
      if (!active) return;
      setSession(currentSession);
      setSessionReady(true);
      if (error) setSessionMessage("Unable to verify the current session. Try again.");
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
      if (status !== 403) setSessionMessage("Could not verify administrator access. Retry or switch accounts.");
    });

    return () => { active = false; };
  }, [accessCheckAttempt, destination, mode, navigate, session, sessionReady]);

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

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!email.trim() || !password.trim()) {
      toast.error("Please fill in all fields");
      return;
    }
    setLoading(true);

    try {
      if (isLogin) {
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
      toast.error(error instanceof Error ? error.message : "Authentication failed");
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
              {mode === "admin" ? "Administrator sign in" : mode === "ngo" ? "NGO sign in" : isLogin ? "Welcome Back" : "Create Account"}
            </h1>
            <p className="mb-8 text-center text-sm text-muted-foreground">
              {mode === "admin"
                ? "Use an account provisioned with administrator access. Public administrator registration is disabled."
                : mode === "ngo"
                  ? "Sign in to submit an application or check its review status."
                  : isLogin ? "Sign in to access your health history" : "Join AI HealthBot for personalized health insights"}
            </p>

            {sessionMessage && <p className="mb-4 text-sm text-muted-foreground" role="status">{sessionMessage}</p>}

            {mode === "admin" && session && adminAccess === "denied" ? (
              <div className="space-y-4" role="alert">
                <p className="text-sm text-critical">This signed-in account does not have administrator access.</p>
                <button type="button" onClick={() => void switchAccount()} disabled={switchingAccount}
                  className="flex w-full items-center justify-center gap-2 rounded-2xl bg-primary py-3 font-semibold text-primary-foreground disabled:opacity-50">
                  {switchingAccount && <Loader2 className="h-4 w-4 animate-spin" />}
                  Sign out and use another account
                </button>
              </div>
            ) : mode === "admin" && session && adminAccess === "error" ? (
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
            ) : !sessionReady || (mode === "admin" && session && adminAccess === "checking") ? (
              <div className="flex items-center justify-center gap-2 py-8 text-sm text-muted-foreground" role="status">
                <Loader2 className="h-4 w-4 animate-spin" /> Checking your session…
              </div>
            ) : <form onSubmit={handleSubmit} className="space-y-4">
              <div className="relative">
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
              </div>
              <div className="relative">
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
              </div>
              <button
                type="submit"
                disabled={loading}
                className="flex w-full items-center justify-center gap-2 rounded-2xl bg-primary py-3 font-semibold text-primary-foreground shadow-lg shadow-primary/25 transition-all hover:shadow-xl disabled:opacity-50"
              >
                {loading && <Loader2 className="h-4 w-4 animate-spin" />}
                {isLogin ? "Sign In" : "Create Account"}
              </button>
            </form>}

            {!loginOnly && <p className="mt-6 text-center text-sm text-muted-foreground">
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
