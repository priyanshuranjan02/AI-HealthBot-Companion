import { useEffect, useState, type ReactNode } from "react";
import { Navigate } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";

/** This is an authentication gate only. Admin and approved-NGO authorization
 * remains enforced by the corresponding Edge Function/database workflow. */
const RequireSession = ({ children, loginPath }: { children: ReactNode; loginPath: string }) => {
  const [checking, setChecking] = useState(true);
  const [authenticated, setAuthenticated] = useState(false);

  useEffect(() => {
    let active = true;
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      if (active) {
        setAuthenticated(Boolean(session));
        setChecking(false);
      }
    });

    void supabase.auth.getSession().then(({ data: { session } }) => {
      if (active) {
        setAuthenticated(Boolean(session));
        setChecking(false);
      }
    });

    return () => {
      active = false;
      subscription.unsubscribe();
    };
  }, []);

  if (checking) {
    return <div className="flex min-h-screen items-center justify-center text-sm text-muted-foreground">Checking your session…</div>;
  }

  if (!authenticated) return <Navigate to={loginPath} replace />;
  return <>{children}</>;
};

export default RequireSession;
