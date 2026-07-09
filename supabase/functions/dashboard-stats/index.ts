import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const { data: checks, error } = await supabase
      .from("symptom_checks")
      .select("*")
      .order("created_at", { ascending: false });
    if (error) throw error;

    const { count: userCount } = await supabase
      .from("profiles")
      .select("*", { count: "exact", head: true });

    const allChecks = checks || [];
    const totalChecks = allChecks.length;

    const severityCounts = { low: 0, moderate: 0, high: 0 };
    allChecks.forEach((c) => {
      if (c.severity in severityCounts) severityCounts[c.severity as keyof typeof severityCounts]++;
    });

    const diagnosisCounts: Record<string, number> = {};
    allChecks.forEach((c) => { diagnosisCounts[c.diagnosis] = (diagnosisCounts[c.diagnosis] || 0) + 1; });
    const topDiagnoses = Object.entries(diagnosisCounts).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([name, count]) => ({ name, count }));

    // Daily (30d)
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    const dailyCounts: Record<string, number> = {};
    allChecks.filter((c) => new Date(c.created_at) >= thirtyDaysAgo).forEach((c) => {
      const day = c.created_at.split("T")[0];
      dailyCounts[day] = (dailyCounts[day] || 0) + 1;
    });
    const dailyChecks = Object.entries(dailyCounts).sort((a, b) => a[0].localeCompare(b[0])).map(([date, count]) => ({ date, count }));

    // Monthly (last 12)
    const monthlyCounts: Record<string, number> = {};
    allChecks.forEach((c) => {
      const m = c.created_at.slice(0, 7);
      monthlyCounts[m] = (monthlyCounts[m] || 0) + 1;
    });
    const monthlyAssessments = Object.entries(monthlyCounts).sort((a, b) => a[0].localeCompare(b[0])).slice(-12).map(([month, count]) => ({ month, count }));

    // Severity trend (last 30d, stacked)
    const severityTrend: Record<string, { date: string; low: number; moderate: number; high: number }> = {};
    allChecks.filter((c) => new Date(c.created_at) >= thirtyDaysAgo).forEach((c) => {
      const day = c.created_at.split("T")[0];
      if (!severityTrend[day]) severityTrend[day] = { date: day, low: 0, moderate: 0, high: 0 };
      const sev = c.severity as "low" | "moderate" | "high";
      if (sev in severityTrend[day]) severityTrend[day][sev]++;
    });
    const predictionTrend = Object.values(severityTrend).sort((a, b) => a.date.localeCompare(b.date));

    // Language
    const langCounts: Record<string, number> = {};
    allChecks.forEach((c) => { langCounts[c.language] = (langCounts[c.language] || 0) + 1; });
    const languageBreakdown = Object.entries(langCounts).map(([name, count]) => ({ name: name.toUpperCase(), count }));

    // Symptoms
    const symptomCounts: Record<string, number> = {};
    allChecks.forEach((c) => (c.symptoms || []).forEach((s: string) => { symptomCounts[s] = (symptomCounts[s] || 0) + 1; }));
    const topSymptoms = Object.entries(symptomCounts).sort((a, b) => b[1] - a[1]).slice(0, 10).map(([name, count]) => ({ name, count }));

    const avgConfidence = totalChecks > 0 ? Math.round(allChecks.reduce((s, c) => s + c.confidence, 0) / totalChecks) : 0;
    const highRiskCases = severityCounts.high;

    return new Response(
      JSON.stringify({
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
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("dashboard-stats error:", error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
