import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { ngoApplicationWorkflow, type NgoApplicationStatus } from "./workflow.ts";

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

  const token = req.headers.get("Authorization")?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim() ?? null;
  let body: Record<string, unknown>;
  try {
    body = await req.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) return response({ error: "Invalid request" }, 400);
  } catch {
    return response({ error: "Invalid request" }, 400);
  }

  const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const result = await ngoApplicationWorkflow(token, body.action, body, {
    getUserId: async (accessToken) => {
      const { data, error } = await authClient.auth.getUser(accessToken);
      if (error) return null;
      return data.user?.id ?? null;
    },
    getStatus: async (userId) => {
      const [profileResult, applicationResult] = await Promise.all([
        admin.from("profiles").select("role").eq("id", userId).maybeSingle(),
        admin.from("ngo_applications")
          .select("id, organization_name, status, review_reason, decided_at, created_at")
          .eq("applicant_user_id", userId)
          .order("created_at", { ascending: false })
          .order("id", { ascending: false })
          .limit(1)
          .maybeSingle(),
      ]);
      if (profileResult.error || applicationResult.error) throw new Error("Unable to load application status");
      return {
        profileRole: profileResult.data?.role ?? null,
        application: (applicationResult.data as NgoApplicationStatus | null) ?? null,
      };
    },
    submit: async (userId, input) => {
      const { data, error } = await admin.rpc("submit_ngo_application", {
        p_applicant_user_id: userId,
        p_organization_name: input.organizationName,
        p_registration_identifier: input.registrationIdentifier,
        p_official_contact_email: input.officialContactEmail,
        p_official_contact_phone: input.officialContactPhone,
        p_website: input.website,
        p_evidence_references: input.evidenceReferences,
      });
      return { applicationId: typeof data === "string" ? data : null, errorCode: error?.code };
    },
  });

  return response(result.body, result.status);
});
