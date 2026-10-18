
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "npm:@supabase/supabase-js@2/cors";

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

    if (!tokenMatch) {
      return jsonResponse({ error: "Authentication required" }, 401);
    }

    const accessToken = tokenMatch[1].trim();

    const authClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });

    const { data: authData, error: authError } =
      await authClient.auth.getClaims(accessToken);

    const userId = authData?.claims?.sub;
    if (authError || typeof userId !== "string" || !userId) {
      return jsonResponse({ error: "Invalid or expired session" }, 401);
    }

    // Use the trusted database role, never a role supplied by the client.
    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });

    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("role")
      .eq("id", userId)
      .maybeSingle();

    if (profileError) {
      console.error("dashboard-stats: Role lookup failed", profileError.message);
      return jsonResponse({ error: "Unable to verify account permissions" }, 500);
    }

    if (profile?.role !== "ngo") {
      return jsonResponse({ error: "Forbidden: NGO access required" }, 403);
    }

    // Privileged analytics queries run only after successful authorization.
    const { data: checks, error } = await adminClient
      .from("symptom_checks")
      .select("*")
      .order("created_at", { ascending: false });

    if (error) {
      console.error("dashboard-stats: Assessment query failed", error.message);
      return jsonResponse({ error: "Unable to load dashboard statistics" }, 500);
    }

    const { count: userCount, error: countError } = await adminClient
      .from("profiles")
      .select("*", { count: "exact", head: true });

    if (countError) {
      console.error("dashboard-stats: User count failed", countError.message);
      return jsonResponse({ error: "Unable to load dashboard statistics" }, 500);
    }

    const allChecks = checks || [];
    const totalChecks = allChecks.length;

    const severityCounts = { low: 0, moderate: 0, high: 0 };
    allChecks.forEach((c) => {
      if (c.severity === "low" || c.severity === "moderate" || c.severity === "high") {
        severityCounts[c.severity as keyof typeof severityCounts]++;
      }
    });

    const diagnosisCounts: Record<string, number> = {};
    allChecks.forEach((c) => {
      const diagnosis = c.diagnosis || "Unknown";
      diagnosisCounts[diagnosis] = (diagnosisCounts[diagnosis] || 0) + 1;
    });

    const topDiagnoses = Object.entries(diagnosisCounts)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 8)
      .map(([name, count]) => ({ name, count }));

    // Daily counts (last 30 days).
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);

    const recentChecks = allChecks.filter(
      (c) => c.created_at && new Date(c.created_at) >= thirtyDaysAgo,
    );

    const dailyCounts: Record<string, number> = {};
    recentChecks.forEach((c) => {
      const day = c.created_at.split("T")[0];
      dailyCounts[day] = (dailyCounts[day] || 0) + 1;
    });

    const dailyChecks = Object.entries(dailyCounts)
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([date, count]) => ({ date, count }));

    // Monthly assessments (last 12 months with data).
    const monthlyCounts: Record<string, number> = {};
    allChecks.forEach((c) => {
      if (!c.created_at) return;
      const month = c.created_at.slice(0, 7);
      monthlyCounts[month] = (monthlyCounts[month] || 0) + 1;
    });

    const monthlyAssessments = Object.entries(monthlyCounts)
      .sort((a, b) => a[0].localeCompare(b[0]))
      .slice(-12)
      .map(([month, count]) => ({ month, count }));

    // Severity trend (last 30 days).
    const severityTrend: Record<
      string,
      { date: string; low: number; moderate: number; high: number }
    > = {};

    recentChecks.forEach((c) => {
      const day = c.created_at.split("T")[0];

      if (!severityTrend[day]) {
        severityTrend[day] = { date: day, low: 0, moderate: 0, high: 0 };
      }

      if (c.severity === "low" || c.severity === "moderate" || c.severity === "high") {
        severityTrend[day][
          c.severity as "low" | "moderate" | "high"
        ]++;
      }
    });

    const predictionTrend = Object.values(severityTrend)
      .sort((a, b) => a.date.localeCompare(b.date));

    // Language breakdown.
    const langCounts: Record<string, number> = {};
    allChecks.forEach((c) => {
      const language = c.language || "unknown";
      langCounts[language] = (langCounts[language] || 0) + 1;
    });

    const languageBreakdown = Object.entries(langCounts).map(
      ([name, count]) => ({ name: name.toUpperCase(), count }),
    );

    // Most frequently reported symptoms.
    const symptomCounts: Record<string, number> = {};
    allChecks.forEach((c) => {
      (Array.isArray(c.symptoms) ? c.symptoms : []).forEach((s: string) => {
        symptomCounts[s] = (symptomCounts[s] || 0) + 1;
      });
    });

    const topSymptoms = Object.entries(symptomCounts)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 10)
      .map(([name, count]) => ({ name, count }));

    const avgConfidence =
      totalChecks > 0
        ? Math.round(
            allChecks.reduce((sum, c) => sum + (Number(c.confidence) || 0), 0) /
              totalChecks,
          )
        : 0;

    const highRiskCases = severityCounts.high;

    return jsonResponse({
      totalChecks,
      totalUsers: userCount || 0,
      severityCounts,
      topDiagnoses,
      dailyChecks,
      monthlyAssessments,
      predictionTrend,
      languageDistribution: langCounts,
      languageBreakdown,
      topSymptoms,
      avgConfidence,
      highRiskCases,
    });
  } catch (error) {
    console.error(
      "dashboard-stats error:",
      error instanceof Error ? error.message : "Unknown error",
    );
    return jsonResponse({ error: "Internal server error" }, 500);
  }
});