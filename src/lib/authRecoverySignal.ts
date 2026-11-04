import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/integrations/supabase/client";

// The Auth page is lazy-loaded. Keep the SDK's validated recovery event in
// memory so that a callback processed before that page mounts is not lost.
let recoverySession: Session | null = null;

supabase.auth.onAuthStateChange((event, session) => {
  if (event === "PASSWORD_RECOVERY" && session) recoverySession = session;
  else if (event === "SIGNED_OUT") recoverySession = null;
});

export const getPasswordRecoverySession = () => recoverySession;

export const clearPasswordRecoverySession = () => {
  recoverySession = null;
};
