import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { deleteAccountWorkflow, isInvalidSessionAuthError } from "./workflow.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    const token = authHeader?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim() ?? null;
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    if (!supabaseUrl || !anonKey || !serviceKey) {
      return new Response(JSON.stringify({ error: "Server configuration error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const auth = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const result = await deleteAccountWorkflow(token, {
      getUser: async (accessToken) => {
        const { data, error } = await auth.auth.getUser(accessToken);
        if (error) {
          // Only known invalid-session codes are unauthorized. Other Auth
          // errors, including network/service failures, remain unavailable.
          return isInvalidSessionAuthError(error) ? { kind: "invalid" } : { kind: "unavailable" };
        }
        return data.user
          ? { kind: "authenticated", userId: data.user.id }
          : { kind: "invalid" };
      },
      deleteAuthUser: async (userId) => {
        const { error } = await admin.auth.admin.deleteUser(userId);
        return { error: Boolean(error) };
      },
    });

    return new Response(JSON.stringify(result.body), {
      status: result.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch {
    return new Response(
      JSON.stringify({
        error: "Deletion could not be confirmed. It may have completed. Retry only if you can still sign in; otherwise contact support.",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
