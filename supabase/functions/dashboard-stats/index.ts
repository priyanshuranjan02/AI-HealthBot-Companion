
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { dashboardStatsWorkflow } from "./workflow.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      console.error("dashboard-stats: Required environment configuration is missing");
      return jsonResponse({ error: "Server configuration error" }, 500);
    }

    // Authenticate the caller using their supplied access token.
    const authHeader = req.headers.get("Authorization");
    const tokenMatch = authHeader?.match(/^Bearer\s+(.+)$/i);
    const accessToken = tokenMatch?.[1].trim() ?? null;

    const authClient = createClient(supabaseUrl, anonKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });

    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });

    const result = await dashboardStatsWorkflow(accessToken, {
      getUserId: async (token) => {
        const { data, error } = await authClient.auth.getUser(token);
        if (error) {
          if (error.status === 401) return null;
          throw error;
        }
        return data.user?.id ?? null;
      },
      getProfileRole: async (userId) => {
        const { data, error } = await adminClient
          .from("profiles")
          .select("role")
          .eq("id", userId)
          .maybeSingle();
        if (error) throw error;
        return data?.role ?? null;
      },
      getLatestApplicationStatus: async (userId) => {
        const { data, error } = await adminClient
          .from("ngo_applications")
          .select("status")
          .eq("applicant_user_id", userId)
          .order("created_at", { ascending: false })
          .order("id", { ascending: false })
          .limit(1)
          .maybeSingle();
        if (error) throw error;
        return data?.status ?? null;
      },
      getStats: async () => {
        // The RPC is intentionally fail-closed and returns no health statistics.
        const { data, error } = await adminClient.rpc("get_ngo_dashboard_stats");
        if (error) throw error;
        return data;
      },
    });

    return jsonResponse(result.body, result.status);
  } catch (error) {
    console.error(
      "dashboard-stats error:",
      error instanceof Error ? error.message : "Unknown error",
    );
    return jsonResponse({ error: "Internal server error" }, 500);
  }
});
