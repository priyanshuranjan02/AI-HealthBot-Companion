import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { hasAdministratorRole, minimizeNgoApplication } from "./response.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return response({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return response({ error: "Server configuration error" }, 500);
  const token = req.headers.get("Authorization")?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
  if (!token) return response({ error: "Authentication required" }, 401);

  const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: auth, error: authError } = await authClient.auth.getUser(token);
  if (authError || !auth.user) return response({ error: "Invalid or expired session" }, 401);
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: adminRole, error: roleError } = await admin.from("user_roles").select("role").eq("user_id", auth.user.id).eq("role", "admin").maybeSingle();

  if (roleError) {
    return response({ error: "Unable to verify permissions" }, 500);
  }

  if (!hasAdministratorRole(adminRole?.role)) {
    return response({ error: "Administrator access required" }, 403);
  }

  try {
    const body = await req.json();
    if (body?.action === "check-access") {
      return response({ authorized: true });
    }
    if (body?.action === "review") {
      const validStatus = ["approved", "rejected", "suspended"].includes(body.status);
      const reason = typeof body.reason === "string" ? body.reason.trim() : "";
      if (typeof body.applicationId !== "string" || !validStatus || reason.length > 2000 || ((body.status === "rejected" || body.status === "suspended") && !reason)) {
        return response({ error: "Invalid review request" }, 400);
      }
      const { error } = await admin.rpc("review_ngo_application", {
        p_reviewer_id: auth.user.id,
        p_application_id: body.applicationId,
        p_status: body.status,
        p_reason: reason || null,
      });
      if (error) {
        if (error.code === "42501" && error.message === "Administrators cannot review their own NGO application") {
          return response({ error: "Administrators cannot review their own applications" }, 403);
        }
        if (error.code === "42501") return response({ error: "Administrator access required" }, 403);
        return response({ error: "Unable to record review" }, 400);
      }
      return response({ success: true });
    }

    const { data: applications, error } = await admin
      .from("ngo_applications")
      .select("id, organization_name, registration_identifier, official_contact_email, official_contact_phone, website, evidence_references, status, review_reason, decided_at, created_at")
      .order("created_at", { ascending: false });
    if (error) return response({ error: "Unable to load applications" }, 500);
    const rows = (applications ?? []).map(minimizeNgoApplication);
    const uniqueOrganizationCount = (status?: string) => new Set(
      rows
        .filter((row) => !status || row.status === status)
        .map((row) => row.registration_identifier.trim().toLowerCase()),
    ).size;
    return response({
      counts: {
        totalApplications: rows.length,
        uniqueOrganizations: uniqueOrganizationCount(),
        pendingApplications: rows.filter((row) => row.status === "pending").length,
        approvedNgos: uniqueOrganizationCount("approved"),
        rejectedApplications: rows.filter((row) => row.status === "rejected").length,
        suspendedOrganizations: uniqueOrganizationCount("suspended"),
      },
      applications: rows,
    });
  } catch {
    return response({ error: "Invalid request" }, 400);
  }
});
