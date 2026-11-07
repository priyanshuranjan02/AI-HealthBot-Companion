import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Activity, AlertTriangle, ArrowLeft, BadgeCheck, Building2, CalendarDays, ExternalLink, FileCheck2, Globe2, Loader2, Mail, Phone, RefreshCw, ShieldAlert, TrendingUp, Users, type LucideIcon } from "lucide-react";
import { Area, AreaChart, Bar, BarChart, CartesianGrid, Cell, Legend, Line, LineChart, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { supabase } from "@/integrations/supabase/client";
import ThemeToggle from "@/components/ThemeToggle";
import { canRenderAnalytics, currentMonthMetric, isBreakdownSuppressed, metricDisplay } from "@/lib/dashboardPrivacy";

type ApplicationStatus = "pending" | "approved" | "rejected" | "suspended";
type OrganizationApplication = {
  id: string;
  organization_name: string;
  registration_identifier: string;
  official_contact_email: string;
  official_contact_phone: string;
  website: string | null;
  status: ApplicationStatus;
  review_reason: string | null;
  decided_at: string | null;
  created_at: string;
};
type OrganizationStatus = {
  application: OrganizationApplication | null;
  profileRole: string | null;
  canSubmit: boolean;
  dashboardAvailable: boolean;
};
type DashboardData = {
  totalChecks: number;
  totalUsers: number | null;
  severityCounts: { low: number | null; moderate: number | null; high: number | null };
  topDiagnoses: { name: string; count: number }[];
  dailyChecks: { date: string; count: number }[];
  monthlyAssessments: { month: string; count: number }[];
  predictionTrend: { date: string; low: number | null; moderate: number | null; high: number | null }[];
  languageDistribution: Record<string, number>;
  languageBreakdown: { name: string; count: number }[];
  topSymptoms: { name: string; count: number }[];
  avgConfidence: number | null;
  highRiskCases: number | null;
  privacySuppressed: false;
  minimumCohort: number;
  suppressedBreakdowns: string[];
};

const statusValues = new Set<ApplicationStatus>(["pending", "approved", "rejected", "suspended"]);
const severityColors = ["hsl(145, 63%, 42%)", "hsl(38, 92%, 50%)", "hsl(0, 72%, 51%)"];
const languageColors = ["hsl(205, 85%, 45%)", "hsl(280, 65%, 55%)", "hsl(160, 60%, 45%)", "hsl(38, 92%, 50%)", "hsl(340, 70%, 55%)"];

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const parseOrganizationStatus = (value: unknown): OrganizationStatus | null => {
  if (!isRecord(value) || typeof value.canSubmit !== "boolean" || typeof value.dashboardAvailable !== "boolean") return null;
  if (value.profileRole !== null && typeof value.profileRole !== "string") return null;
  let application: OrganizationApplication | null = null;
  if (value.application !== null) {
    if (!isRecord(value.application)) return null;
    const row = value.application;
    if (
      typeof row.id !== "string" || typeof row.organization_name !== "string" ||
      typeof row.registration_identifier !== "string" || typeof row.official_contact_email !== "string" ||
      typeof row.official_contact_phone !== "string" ||
      (row.website !== null && typeof row.website !== "string") ||
      typeof row.status !== "string" || !statusValues.has(row.status as ApplicationStatus) ||
      (row.review_reason !== null && typeof row.review_reason !== "string") ||
      (row.decided_at !== null && typeof row.decided_at !== "string") || typeof row.created_at !== "string"
    ) return null;
    application = {
      id: row.id,
      organization_name: row.organization_name,
      registration_identifier: row.registration_identifier,
      official_contact_email: row.official_contact_email,
      official_contact_phone: row.official_contact_phone,
      website: row.website,
      status: row.status as ApplicationStatus,
      review_reason: row.review_reason,
      decided_at: row.decided_at,
      created_at: row.created_at,
    };
  }
  const profileRole = value.profileRole as string | null;
  const expectedCanSubmit = profileRole === "user" && (!application || application.status === "rejected");
  const expectedDashboardAvailable = profileRole === "ngo" && application?.status === "approved";
  if (value.canSubmit !== expectedCanSubmit || value.dashboardAvailable !== expectedDashboardAvailable) return null;
  return { application, profileRole, canSubmit: value.canSubmit, dashboardAvailable: value.dashboardAvailable };
};

const isCount = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0;
const isCountRows = (value: unknown, key: string): boolean =>
  Array.isArray(value) && value.every((item) => isRecord(item) && typeof item[key] === "string" && isCount(item.count));

const isDashboardData = (value: unknown): value is DashboardData => {
  if (!canRenderAnalytics(value) || !isRecord(value)) return false;
  const severity = value.severityCounts;
  const trendValid = Array.isArray(value.predictionTrend) && value.predictionTrend.every((item) =>
    isRecord(item) && typeof item.date === "string" && [item.low, item.moderate, item.high].every((count) => count === null || isCount(count)));
  return isCount(value.totalChecks) && value.totalChecks > 0 &&
    (value.totalUsers === null || isCount(value.totalUsers)) && isRecord(severity) &&
    [severity.low, severity.moderate, severity.high].every((count) => count === null || isCount(count)) &&
    isCountRows(value.topDiagnoses, "name") &&
    Array.isArray(value.dailyChecks) && value.dailyChecks.every((row) => isRecord(row) && typeof row.date === "string" && isCount(row.count)) &&
    Array.isArray(value.monthlyAssessments) && value.monthlyAssessments.every((row) => isRecord(row) && typeof row.month === "string" && isCount(row.count)) &&
    trendValid && isRecord(value.languageDistribution) && Object.values(value.languageDistribution).every(isCount) &&
    isCountRows(value.languageBreakdown, "name") && isCountRows(value.topSymptoms, "name") &&
    (value.avgConfidence === null || isCount(value.avgConfidence)) &&
    (value.highRiskCases === null || isCount(value.highRiskCases)) &&
    typeof value.minimumCohort === "number" && Number.isFinite(value.minimumCohort) &&
    Array.isArray(value.suppressedBreakdowns) && value.suppressedBreakdowns.every((item) => typeof item === "string");
};

const formatDate = (value: string | null | undefined): string | null => {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(parsed);
};

const safeWebsite = (value: string | null): string | null => {
  if (!value) return null;
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" || parsed.protocol === "http:" ? parsed.toString() : null;
  } catch {
    return null;
  }
};

const Dashboard = () => {
  const navigate = useNavigate();
  const [status, setStatus] = useState<OrganizationStatus | null>(null);
  const [analytics, setAnalytics] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [analyticsError, setAnalyticsError] = useState("");

  const loadDashboard = useCallback(async () => {
    setLoading(true);
    setError("");
    setAnalyticsError("");
    setAnalytics(null);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) {
        setStatus(null);
        setError("Sign in again to verify your organization access.");
        return;
      }

      const { data: statusData, error: statusError } = await supabase.functions.invoke("ngo-application", {
        headers: { Authorization: `Bearer ${session.access_token}` }, body: { action: "status" },
      });
      if (statusError) throw statusError;
      const organizationStatus = parseOrganizationStatus(statusData);
      if (!organizationStatus) throw new Error("The organization status response could not be verified.");
      setStatus(organizationStatus);

      const entitled = organizationStatus.dashboardAvailable === true && organizationStatus.profileRole === "ngo" && organizationStatus.application?.status === "approved";
      if (!entitled) return;

      const { data: stats, error: statsError } = await supabase.functions.invoke("dashboard-stats", {
        headers: { Authorization: `Bearer ${session.access_token}` },
      });
      if (statsError) {
        const response = isRecord(statsError) ? statsError.context : undefined;
        if (response instanceof Response && (response.status === 401 || response.status === 403)) {
          setStatus(null);
          setError("Your organization access could not be confirmed. Please retry or contact support.");
          return;
        }
        setAnalyticsError("Community Health Insights could not be loaded. Your organization verification remains available below.");
        return;
      }
      if (isDashboardData(stats)) setAnalytics(stats);
    } catch {
      setError("We could not verify your organization access. Please retry or contact support.");
      setStatus(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void loadDashboard(); }, [loadDashboard]);

  const application = status?.application ?? null;
  const approvedAccess = status?.dashboardAvailable === true && status.profileRole === "ngo" && application?.status === "approved";
  const profileMismatch = Boolean(status && (
    (status.profileRole === "ngo" && application?.status !== "approved") ||
    (application?.status === "approved" && status.profileRole !== "ngo") ||
    (application && status.profileRole !== "user" && status.profileRole !== "ngo") ||
    (!application && status.profileRole === "ngo")
  ));

  return <div className="min-h-screen bg-background">
    <nav className="sticky top-0 z-20 flex items-center justify-between border-b border-border bg-card/90 px-4 py-3 backdrop-blur-md sm:px-6">
      <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground"><ArrowLeft className="h-4 w-4" /><span className="text-lg font-bold text-foreground"><span className="text-gradient-primary">NGO</span> Organization Dashboard</span></button>
      <ThemeToggle />
    </nav>

    <main className="container mx-auto max-w-6xl px-4 py-8 sm:py-10">
      {loading ? <div className="flex min-h-64 items-center justify-center gap-3 text-muted-foreground" role="status"><Loader2 className="h-6 w-6 animate-spin" />Verifying your organization access…</div> : error ? (
        <section className="mx-auto max-w-xl rounded-2xl border border-border bg-card p-8 text-center shadow-sm">
          <ShieldAlert className="mx-auto mb-4 h-10 w-10 text-primary" /><h1 className="text-2xl font-bold">Organization access could not be verified</h1><p className="mt-2 text-muted-foreground">{error}</p>
          <div className="mt-6 flex flex-wrap justify-center gap-3"><button onClick={() => void loadDashboard()} className="inline-flex items-center gap-2 rounded-xl bg-primary px-4 py-3 font-semibold text-primary-foreground"><RefreshCw className="h-4 w-4" />Retry access check</button><Link to="/contact" className="rounded-xl border border-border px-4 py-3 font-semibold">Contact support</Link></div>
        </section>
      ) : !approvedAccess ? <PortalState application={application} profileMismatch={profileMismatch} canSubmit={status?.canSubmit === true} /> : application ? (
        <div className="space-y-7">
          <header className="flex flex-col justify-between gap-4 rounded-3xl border border-border bg-card p-6 shadow-sm sm:flex-row sm:items-center sm:p-8">
            <div><p className="text-sm font-semibold uppercase tracking-wide text-primary">Organization workspace</p><h1 className="mt-1 text-3xl font-bold tracking-tight">{application.organization_name}</h1><p className="mt-2 max-w-2xl text-muted-foreground">Your organization’s verification and account information, confirmed by an authorized administrator.</p></div>
            <span className="inline-flex w-fit items-center gap-2 rounded-full border border-emerald-600/20 bg-emerald-600/10 px-4 py-2 text-sm font-semibold text-emerald-700 dark:text-emerald-400"><BadgeCheck className="h-4 w-4" />Approved · Verified</span>
          </header>

          <div className="grid gap-6 lg:grid-cols-[1.2fr_0.8fr]">
            <section className="rounded-2xl border border-border bg-card p-6 shadow-sm" aria-labelledby="organization-profile-title">
              <div className="mb-5 flex items-center gap-3"><Building2 className="h-5 w-5 text-primary" /><h2 id="organization-profile-title" className="text-lg font-semibold">Organization profile</h2></div>
              <dl className="grid gap-x-6 gap-y-5 sm:grid-cols-2">
                <ProfileField label="Organization name" value={application.organization_name} /><ProfileField label="Registration identifier" value={application.registration_identifier} />
                <ProfileField label="Official contact email" value={application.official_contact_email} icon={<Mail className="h-4 w-4" />} /><ProfileField label="Official contact phone" value={application.official_contact_phone} icon={<Phone className="h-4 w-4" />} />
                <div className="sm:col-span-2"><dt className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Website</dt><dd className="mt-1 break-all text-sm">{safeWebsite(application.website) ? <a href={safeWebsite(application.website)!} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-primary underline">{application.website}<ExternalLink className="h-3.5 w-3.5" /></a> : <span className="text-muted-foreground">Not provided</span>}</dd></div>
              </dl>
              <div className="mt-6 rounded-xl bg-muted/50 p-4 text-sm text-muted-foreground">Profile changes are not available here. <Link to="/contact" className="font-medium text-primary underline">Contact support</Link> to request an update.</div>
            </section>

            <section className="rounded-2xl border border-border bg-card p-6 shadow-sm" aria-labelledby="verification-title">
              <div className="mb-5 flex items-center gap-3"><FileCheck2 className="h-5 w-5 text-primary" /><h2 id="verification-title" className="text-lg font-semibold">Verification timeline</h2></div>
              <ol className="space-y-5"><TimelineItem title="Application submitted" date={formatDate(application.created_at)} description="Your organization details were received." />{application.decided_at && <TimelineItem title="Administrator decision · Approved" date={formatDate(application.decided_at)} description="An authorized administrator approved the application." />}<TimelineItem title="Current state · Verified" description="Organization dashboard access is active." current /></ol>
              <p className="mt-6 flex items-center gap-2 rounded-xl bg-emerald-600/10 p-3 text-sm font-medium text-emerald-800 dark:text-emerald-300"><BadgeCheck className="h-4 w-4 shrink-0" />Approved organization account access is active.</p>
            </section>
          </div>

          <section className="rounded-2xl border border-border bg-card p-6 shadow-sm sm:p-8" aria-labelledby="health-insights-title">
            <div className="mb-4 flex items-start gap-3"><div className="rounded-xl bg-primary/10 p-2.5 text-primary"><Activity className="h-5 w-5" /></div><div><h2 id="health-insights-title" className="text-xl font-semibold">Community Health Insights</h2><p className="mt-1 text-sm text-muted-foreground">Community-wide assessment reporting for verified partners.</p></div></div>
            {analyticsError && <p role="alert" className="mb-4 rounded-xl border border-border bg-muted/40 p-4 text-sm text-muted-foreground">{analyticsError}</p>}
            {analytics && canRenderAnalytics(analytics) ? <AnalyticsCharts data={analytics} /> : <div className="rounded-2xl border border-dashed border-border bg-muted/30 p-6 sm:p-8"><div className="flex gap-3"><ShieldAlert className="mt-0.5 h-5 w-5 shrink-0 text-primary" /><div><h3 className="font-semibold">Health statistics are currently withheld</h3><p className="mt-2 max-w-3xl text-sm leading-relaxed text-muted-foreground">A trusted, consented assessment dataset and reporting privacy safeguards are still being reviewed. A minimum cohort-size threshold alone does not guarantee privacy, so no community health figures or charts are shown until a separately reviewed and governed aggregate is available.</p></div></div></div>}
            <p className="mt-5 text-sm text-muted-foreground">For organization profile updates or verification questions, <Link to="/contact" className="font-medium text-primary underline">contact the HealthBot team</Link>.</p>
          </section>
        </div>
      ) : null}
    </main>
  </div>;
};

const PortalState = ({ application, profileMismatch, canSubmit }: { application: OrganizationApplication | null; profileMismatch: boolean; canSubmit: boolean }) => {
  let title = "NGO portal";
  let message = "Apply for administrator-approved NGO access through the application portal.";
  let reason: string | null = null;
  if (profileMismatch) { title = "Organization access needs reconciliation"; message = "Your saved profile role and application state do not agree. Dashboard access is withheld until support reconciles them."; }
  else if (application?.status === "pending") { title = "Application pending review"; message = "Your application is awaiting administrator review. The organization dashboard is not available yet."; }
  else if (application?.status === "rejected") { title = "Application update available"; message = "The application was not approved. You may submit updated organization information for another review."; reason = application.review_reason; }
  else if (application?.status === "suspended") { title = "Application suspended"; message = "Self-service reapplication is disabled for suspended accounts. Reinstatement requires administrator action, but the current admin dashboard does not yet offer reinstatement. Contact support for assistance."; reason = application.review_reason; }
  else if (application?.status === "approved") { title = "Organization access needs reconciliation"; message = "The application is approved, but the server did not confirm the matching NGO profile role. Dashboard access remains withheld."; }
  else if (!canSubmit) { title = "NGO access unavailable"; message = "This account is not eligible to submit an NGO application. Contact support if you believe this is incorrect."; }
  return <section className="mx-auto max-w-2xl rounded-3xl border border-border bg-card p-7 shadow-sm sm:p-9"><div className="mb-4 inline-flex rounded-xl bg-primary/10 p-3 text-primary"><Building2 className="h-6 w-6" /></div><h1 className="text-2xl font-bold">{title}</h1><p className="mt-2 text-muted-foreground">{message}</p>{application?.organization_name && <p className="mt-4 rounded-xl bg-muted/50 p-3 text-sm"><span className="font-medium">Organization:</span> {application.organization_name}</p>}{reason && <p className="mt-3 rounded-xl border border-border p-3 text-sm"><span className="font-medium">Review reason:</span> {reason}</p>}{application && <p className="mt-3 text-sm text-muted-foreground">Submitted {formatDate(application.created_at) ?? "date unavailable"}</p>}<div className="mt-6 flex flex-wrap gap-3">{!profileMismatch && canSubmit && <Link to="/ngo/application" className="rounded-xl bg-primary px-4 py-3 font-semibold text-primary-foreground">{application?.status === "rejected" ? "Update application" : "Open NGO application portal"}</Link>}<Link to="/contact" className="rounded-xl border border-border px-4 py-3 font-semibold">Contact support</Link><Link to="/" className="rounded-xl border border-border px-4 py-3 font-semibold">Return home</Link></div></section>;
};

const ProfileField = ({ label, value, icon }: { label: string; value: string; icon?: React.ReactNode }) => <div><dt className="flex items-center gap-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">{icon}{label}</dt><dd className="mt-1 break-words text-sm font-medium">{value || "Not provided"}</dd></div>;

const TimelineItem = ({ title, date, description, current = false }: { title: string; date?: string | null; description: string; current?: boolean }) => <li className="relative flex gap-3"><span className={`mt-1 flex h-7 w-7 shrink-0 items-center justify-center rounded-full ${current ? "bg-primary text-primary-foreground" : "bg-primary/10 text-primary"}`}>{current ? <BadgeCheck className="h-4 w-4" /> : <CalendarDays className="h-4 w-4" />}</span><div><p className="font-medium">{title}</p>{date && <p className="mt-0.5 text-xs text-muted-foreground">{date}</p>}<p className="mt-1 text-sm text-muted-foreground">{description}</p></div></li>;

const AnalyticsCharts = ({ data }: { data: DashboardData }) => {
  const thisMonth = currentMonthMetric(data.monthlyAssessments, data.suppressedBreakdowns, new Date().toISOString().slice(0, 7));
  const languagesSuppressed = isBreakdownSuppressed(data.suppressedBreakdowns, "languages");
  const severityPie = !isBreakdownSuppressed(data.suppressedBreakdowns, "severityCounts") && Object.values(data.severityCounts).every((count) => count !== null)
    ? [
        { name: "Low", value: data.severityCounts.low as number },
        { name: "Moderate", value: data.severityCounts.moderate as number },
        { name: "High", value: data.severityCounts.high as number },
      ]
    : [];

  return <>
    <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
      <StatCard icon={Activity} label="Total Assessments" value={metricDisplay(data.totalChecks)} />
      <StatCard icon={Users} label="Registered Users" value={metricDisplay(data.totalUsers)} />
      <StatCard icon={TrendingUp} label="Avg Confidence" value={data.avgConfidence === null ? "Suppressed" : `${data.avgConfidence}%`} />
      <StatCard icon={AlertTriangle} label="High Risk Cases" value={metricDisplay(data.highRiskCases)} color="text-critical" />
      <StatCard icon={CalendarDays} label="This Month" value={metricDisplay(thisMonth)} />
      <StatCard icon={Globe2} label="Languages" value={languagesSuppressed ? "Suppressed" : Object.keys(data.languageDistribution).length} />
    </div>
    <div className="grid gap-5 lg:grid-cols-2">
      {!isBreakdownSuppressed(data.suppressedBreakdowns, "monthlyAssessments") && data.monthlyAssessments.length > 0 && <Chart title="Monthly Assessments (Last 12 Months)"><ResponsiveContainer width="100%" height={230}><AreaChart data={data.monthlyAssessments}><defs><linearGradient id="fillMonthly" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stopColor="hsl(205, 85%, 45%)" stopOpacity={0.4} /><stop offset="100%" stopColor="hsl(205, 85%, 45%)" stopOpacity={0} /></linearGradient></defs><CartesianGrid strokeDasharray="3 3" className="stroke-border" /><XAxis dataKey="month" /><YAxis /><Tooltip /><Area type="monotone" dataKey="count" stroke="hsl(205, 85%, 45%)" fill="url(#fillMonthly)" /></AreaChart></ResponsiveContainer></Chart>}
      {!isBreakdownSuppressed(data.suppressedBreakdowns, "predictionTrend") && data.predictionTrend.length > 0 && <Chart title="Prediction Severity Trend (30 Days)"><ResponsiveContainer width="100%" height={230}><BarChart data={data.predictionTrend}><CartesianGrid strokeDasharray="3 3" className="stroke-border" /><XAxis dataKey="date" /><YAxis /><Tooltip /><Legend /><Bar dataKey="low" stackId="s" fill={severityColors[0]} name="Low" /><Bar dataKey="moderate" stackId="s" fill={severityColors[1]} name="Moderate" /><Bar dataKey="high" stackId="s" fill={severityColors[2]} name="High" /></BarChart></ResponsiveContainer></Chart>}
      {severityPie.length > 0 && <Chart title="Severity Distribution"><ResponsiveContainer width="100%" height={230}><PieChart><Pie data={severityPie} dataKey="value" nameKey="name" outerRadius={78} label>{severityPie.map((entry, index) => <Cell key={entry.name} fill={severityColors[index]} />)}</Pie><Tooltip /></PieChart></ResponsiveContainer></Chart>}
      {!isBreakdownSuppressed(data.suppressedBreakdowns, "languages") && data.languageBreakdown.length > 0 && <Chart title="Language Usage"><ResponsiveContainer width="100%" height={230}><PieChart><Pie data={data.languageBreakdown} dataKey="count" nameKey="name" outerRadius={78} label>{data.languageBreakdown.map((item, index) => <Cell key={item.name} fill={languageColors[index % languageColors.length]} />)}</Pie><Tooltip /></PieChart></ResponsiveContainer></Chart>}
      {!isBreakdownSuppressed(data.suppressedBreakdowns, "topDiagnoses") && data.topDiagnoses.length > 0 && <Chart title="Most Common Diagnoses"><ResponsiveContainer width="100%" height={230}><BarChart data={data.topDiagnoses} layout="vertical"><CartesianGrid strokeDasharray="3 3" className="stroke-border" /><XAxis type="number" /><YAxis dataKey="name" type="category" width={120} /><Tooltip /><Bar dataKey="count" fill="hsl(205, 85%, 45%)" /></BarChart></ResponsiveContainer></Chart>}
      {!isBreakdownSuppressed(data.suppressedBreakdowns, "topSymptoms") && data.topSymptoms.length > 0 && <Chart title="Most Common Symptoms"><ResponsiveContainer width="100%" height={230}><BarChart data={data.topSymptoms}><CartesianGrid strokeDasharray="3 3" className="stroke-border" /><XAxis dataKey="name" angle={-30} textAnchor="end" height={60} /><YAxis /><Tooltip /><Bar dataKey="count" fill="hsl(160, 60%, 45%)" /></BarChart></ResponsiveContainer></Chart>}
      {!isBreakdownSuppressed(data.suppressedBreakdowns, "dailyChecks") && data.dailyChecks.length > 0 && <Chart title="Daily Health Checks (Last 30 Days)"><ResponsiveContainer width="100%" height={230}><LineChart data={data.dailyChecks}><CartesianGrid strokeDasharray="3 3" className="stroke-border" /><XAxis dataKey="date" /><YAxis /><Tooltip /><Line dataKey="count" stroke="hsl(205, 85%, 45%)" /></LineChart></ResponsiveContainer></Chart>}
    </div>
  </>;
};

const Chart = ({ title, children }: { title: string; children: React.ReactNode }) => <div className="rounded-xl border border-border p-4"><h3 className="mb-3 font-semibold">{title}</h3>{children}</div>;

const StatCard = ({ icon: Icon, label, value, color }: { icon: LucideIcon; label: string; value: string | number; color?: string }) => <div className="rounded-2xl border border-border bg-card p-4 shadow-sm"><div className="flex items-center gap-3"><span className="flex h-10 w-10 items-center justify-center rounded-xl bg-primary/10"><Icon className={`h-5 w-5 ${color ?? "text-primary"}`} /></span><div className="min-w-0"><p className="truncate text-xs font-medium text-muted-foreground">{label}</p><p className="text-xl font-bold text-foreground">{value}</p></div></div></div>;

export default Dashboard;
