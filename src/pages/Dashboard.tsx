import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, Activity, Users, TrendingUp, AlertTriangle, Loader2, Globe2, ShieldAlert, CalendarDays } from "lucide-react";
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, PieChart, Pie, Cell, LineChart, Line, AreaChart, Area, Legend } from "recharts";
import { supabase } from "@/integrations/supabase/client";
import ThemeToggle from "@/components/ThemeToggle";

interface DashboardData {
  totalChecks: number;
  totalUsers: number;
  severityCounts: { low: number; moderate: number; high: number };
  topDiagnoses: { name: string; count: number }[];
  dailyChecks: { date: string; count: number }[];
  monthlyAssessments: { month: string; count: number }[];
  predictionTrend: { date: string; low: number; moderate: number; high: number }[];
  languageDistribution: Record<string, number>;
  languageBreakdown: { name: string; count: number }[];
  topSymptoms: { name: string; count: number }[];
  avgConfidence: number;
  highRiskCases: number;
}

const SEVERITY_COLORS = ["hsl(145, 63%, 42%)", "hsl(38, 92%, 50%)", "hsl(0, 72%, 51%)"];
const LANG_COLORS = ["hsl(205, 85%, 45%)", "hsl(280, 65%, 55%)", "hsl(160, 60%, 45%)", "hsl(38, 92%, 50%)", "hsl(340, 70%, 55%)"];

const Dashboard = () => {
  const navigate = useNavigate();
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const { data: result, error: fnError } = await supabase.functions.invoke("dashboard-stats");
        if (fnError) throw fnError;
        setData(result);
      } catch (err: any) {
        setError(err.message || "Failed to load dashboard data");
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const severityPie = data ? [
    { name: "Low", value: data.severityCounts.low },
    { name: "Moderate", value: data.severityCounts.moderate },
    { name: "High", value: data.severityCounts.high },
  ] : [];

  return (
    <div className="min-h-screen bg-background">
      <nav className="sticky top-0 z-20 flex items-center justify-between border-b border-border bg-card/80 px-4 py-3 backdrop-blur-md sm:px-6">
        <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground">
          <ArrowLeft className="h-4 w-4" />
          <span className="text-lg font-bold text-foreground">
            <span className="text-gradient-primary">NGO</span> Analytics
          </span>
        </button>
        <ThemeToggle />
      </nav>

      <div className="container mx-auto px-4 py-8">
        {loading ? (
          <div className="flex items-center justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-primary" /></div>
        ) : error ? (
          <div className="rounded-2xl border border-critical/30 bg-critical/5 p-6 text-center text-critical">{error}</div>
        ) : !data || data.totalChecks === 0 ? (
          <div className="py-20 text-center">
            <Activity className="mx-auto mb-4 h-12 w-12 text-muted-foreground" />
            <h2 className="text-xl font-bold text-foreground">No Data Yet</h2>
            <p className="mt-2 text-muted-foreground">Start health checks to populate the dashboard.</p>
            <button onClick={() => navigate("/")} className="mt-4 rounded-2xl bg-primary px-6 py-3 font-semibold text-primary-foreground shadow-lg">Go to Health Check</button>
          </div>
        ) : (
          <>
            {/* Stat cards */}
            <div className="mb-8 grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
              <StatCard icon={Activity} label="Total Assessments" value={data.totalChecks} />
              <StatCard icon={Users} label="Registered Users" value={data.totalUsers} />
              <StatCard icon={TrendingUp} label="Avg Confidence" value={`${data.avgConfidence}%`} />
              <StatCard icon={ShieldAlert} label="High Risk Cases" value={data.highRiskCases} color="text-critical" />
              <StatCard icon={CalendarDays} label="This Month" value={data.monthlyAssessments.at(-1)?.count ?? 0} />
              <StatCard icon={Globe2} label="Languages" value={Object.keys(data.languageDistribution).length} />
            </div>

            <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
              {data.monthlyAssessments.length > 0 && (
                <ChartCard title="Monthly Assessments (Last 12 Months)">
                  <ResponsiveContainer width="100%" height={260}>
                    <AreaChart data={data.monthlyAssessments}>
                      <defs>
                        <linearGradient id="fillMonthly" x1="0" y1="0" x2="0" y2="1">
                          <stop offset="0%" stopColor="hsl(205, 85%, 45%)" stopOpacity={0.4} />
                          <stop offset="100%" stopColor="hsl(205, 85%, 45%)" stopOpacity={0} />
                        </linearGradient>
                      </defs>
                      <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                      <XAxis dataKey="month" tick={{ fontSize: 11 }} className="fill-muted-foreground" />
                      <YAxis tick={{ fontSize: 11 }} className="fill-muted-foreground" />
                      <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid hsl(var(--border))", background: "hsl(var(--card))" }} />
                      <Area type="monotone" dataKey="count" stroke="hsl(205, 85%, 45%)" strokeWidth={2} fill="url(#fillMonthly)" />
                    </AreaChart>
                  </ResponsiveContainer>
                </ChartCard>
              )}

              {data.predictionTrend.length > 0 && (
                <ChartCard title="Prediction Severity Trend (30 Days)">
                  <ResponsiveContainer width="100%" height={260}>
                    <BarChart data={data.predictionTrend}>
                      <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                      <XAxis dataKey="date" tick={{ fontSize: 10 }} className="fill-muted-foreground" tickFormatter={(v) => v.slice(5)} />
                      <YAxis tick={{ fontSize: 11 }} className="fill-muted-foreground" />
                      <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid hsl(var(--border))", background: "hsl(var(--card))" }} />
                      <Legend wrapperStyle={{ fontSize: 11 }} />
                      <Bar dataKey="low" stackId="s" fill={SEVERITY_COLORS[0]} name="Low" radius={[0, 0, 0, 0]} />
                      <Bar dataKey="moderate" stackId="s" fill={SEVERITY_COLORS[1]} name="Moderate" />
                      <Bar dataKey="high" stackId="s" fill={SEVERITY_COLORS[2]} name="High" radius={[4, 4, 0, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                </ChartCard>
              )}

              <ChartCard title="Severity Distribution">
                <ResponsiveContainer width="100%" height={260}>
                  <PieChart>
                    <Pie data={severityPie} cx="50%" cy="50%" outerRadius={90} dataKey="value" label={({ name, percent }) => `${name} ${(percent * 100).toFixed(0)}%`}>
                      {severityPie.map((_, i) => <Cell key={i} fill={SEVERITY_COLORS[i]} />)}
                    </Pie>
                    <Tooltip />
                  </PieChart>
                </ResponsiveContainer>
              </ChartCard>

              {data.languageBreakdown.length > 0 && (
                <ChartCard title="Language Usage">
                  <ResponsiveContainer width="100%" height={260}>
                    <PieChart>
                      <Pie data={data.languageBreakdown} cx="50%" cy="50%" outerRadius={90} dataKey="count" nameKey="name" label={({ name, percent }) => `${name} ${(percent * 100).toFixed(0)}%`}>
                        {data.languageBreakdown.map((_, i) => <Cell key={i} fill={LANG_COLORS[i % LANG_COLORS.length]} />)}
                      </Pie>
                      <Tooltip />
                    </PieChart>
                  </ResponsiveContainer>
                </ChartCard>
              )}

              {data.topDiagnoses.length > 0 && (
                <ChartCard title="Most Common Diseases">
                  <ResponsiveContainer width="100%" height={260}>
                    <BarChart data={data.topDiagnoses} layout="vertical">
                      <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                      <XAxis type="number" tick={{ fontSize: 11 }} className="fill-muted-foreground" />
                      <YAxis dataKey="name" type="category" tick={{ fontSize: 11 }} width={120} className="fill-muted-foreground" />
                      <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid hsl(var(--border))", background: "hsl(var(--card))" }} />
                      <Bar dataKey="count" fill="hsl(205, 85%, 45%)" radius={[0, 6, 6, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                </ChartCard>
              )}

              {data.topSymptoms.length > 0 && (
                <ChartCard title="Most Common Symptoms">
                  <ResponsiveContainer width="100%" height={260}>
                    <BarChart data={data.topSymptoms}>
                      <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                      <XAxis dataKey="name" tick={{ fontSize: 10 }} angle={-30} textAnchor="end" height={60} className="fill-muted-foreground" />
                      <YAxis tick={{ fontSize: 11 }} className="fill-muted-foreground" />
                      <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid hsl(var(--border))", background: "hsl(var(--card))" }} />
                      <Bar dataKey="count" fill="hsl(160, 60%, 45%)" radius={[6, 6, 0, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                </ChartCard>
              )}

              {data.dailyChecks.length > 0 && (
                <ChartCard title="Daily Health Checks (Last 30 Days)">
                  <ResponsiveContainer width="100%" height={260}>
                    <LineChart data={data.dailyChecks}>
                      <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                      <XAxis dataKey="date" tick={{ fontSize: 10 }} className="fill-muted-foreground" tickFormatter={(v) => v.slice(5)} />
                      <YAxis tick={{ fontSize: 11 }} className="fill-muted-foreground" />
                      <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid hsl(var(--border))", background: "hsl(var(--card))" }} />
                      <Line type="monotone" dataKey="count" stroke="hsl(205, 85%, 45%)" strokeWidth={2} dot={{ r: 3 }} />
                    </LineChart>
                  </ResponsiveContainer>
                </ChartCard>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
};

const StatCard = ({ icon: Icon, label, value, color }: { icon: any; label: string; value: string | number; color?: string }) => (
  <div className="rounded-2xl border border-border bg-card p-4 shadow-sm">
    <div className="flex items-center gap-3">
      <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-primary/10">
        <Icon className={`h-5 w-5 ${color || "text-primary"}`} />
      </div>
      <div className="min-w-0">
        <p className="truncate text-xs font-medium text-muted-foreground">{label}</p>
        <p className="text-xl font-bold text-foreground">{value}</p>
      </div>
    </div>
  </div>
);

const ChartCard = ({ title, children }: { title: string; children: React.ReactNode }) => (
  <div className="rounded-2xl border border-border bg-card p-6 shadow-sm">
    <h3 className="mb-4 text-sm font-semibold text-foreground">{title}</h3>
    {children}
  </div>
);

export default Dashboard;
