import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  ArrowLeft, User, Save, Loader2, Building2, MapPin, Phone, Mail, History, Settings, LogOut,
  Search, Trash2, Download, Heart, Activity, AlertTriangle, Calendar, ChevronDown, ChevronUp,
  ShieldCheck, Zap, FileText, Sparkles, Stethoscope,
} from "lucide-react";
import { AreaChart, Area, ResponsiveContainer, XAxis, YAxis, Tooltip, CartesianGrid } from "recharts";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import ThemeToggle from "@/components/ThemeToggle";
import { generateHealthReport, generateFullHistoryReport } from "@/lib/pdfReport";

interface Profile {
  id: string;
  full_name: string;
  avatar_url: string;
  phone: string;
  organization_name: string;
  region: string;
  contact_info: string;
  role: string;
  created_at?: string;
}

interface SymptomCheck {
  id: string;
  diagnosis: string;
  severity: string;
  confidence: number;
  symptoms: string[];
  recommendations: string[] | null;
  language: string;
  created_at: string;
}

type TabId = "overview" | "profile" | "history" | "settings";
type SortMode = "recent" | "severity" | "confidence";
type SeverityFilter = "all" | "low" | "moderate" | "high";

const Profile = () => {
  const navigate = useNavigate();
  const [user, setUser] = useState<any>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [history, setHistory] = useState<SymptomCheck[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [activeTab, setActiveTab] = useState<TabId>("overview");

  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");
  const [orgName, setOrgName] = useState("");
  const [region, setRegion] = useState("");
  const [contactInfo, setContactInfo] = useState("");
  const [role, setRole] = useState("user");

  const [search, setSearch] = useState("");
  const [sortMode, setSortMode] = useState<SortMode>("recent");
  const [sevFilter, setSevFilter] = useState<SeverityFilter>("all");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [deletingAccount, setDeletingAccount] = useState(false);

  useEffect(() => {
    const init = async () => {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) { navigate("/auth"); return; }
      setUser(session.user);

      const { data: prof } = await supabase.from("profiles").select("*").eq("id", session.user.id).single();
      if (prof) {
        setProfile(prof as Profile);
        setFullName(prof.full_name || "");
        setPhone(prof.phone || "");
        setOrgName(prof.organization_name || "");
        setRegion(prof.region || "");
        setContactInfo(prof.contact_info || "");
        setRole(prof.role || "user");
      }

      const { data: checks } = await supabase
        .from("symptom_checks").select("*")
        .eq("user_id", session.user.id)
        .order("created_at", { ascending: false }).limit(200);
      if (checks) setHistory(checks as SymptomCheck[]);
      setLoading(false);
    };
    init();
  }, [navigate]);

  const handleSave = async () => {
    if (!user) return;
    setSaving(true);
    const { error } = await supabase.from("profiles").update({
      full_name: fullName, phone, organization_name: orgName, region,
      contact_info: contactInfo, role, updated_at: new Date().toISOString(),
    }).eq("id", user.id);
    setSaving(false);
    if (error) toast.error("Failed to save profile");
    else toast.success("Profile updated!");
  };

  const handleLogout = async () => {
    await supabase.auth.signOut();
    toast.success("Logged out");
    navigate("/");
  };

  const handleChangePassword = async () => {
    if (!user?.email) return;
    const { error } = await supabase.auth.resetPasswordForEmail(user.email, {
      redirectTo: `${window.location.origin}/auth`,
    });
    if (error) toast.error(error.message);
    else toast.success("Password reset email sent!");
  };

  const handleDeleteRecord = async (id: string) => {
    if (!confirm("Delete this health record permanently?")) return;
    const { error } = await supabase.from("symptom_checks").delete().eq("id", id);
    if (error) return toast.error("Could not delete record");
    setHistory((prev) => prev.filter((h) => h.id !== id));
    toast.success("Record deleted");
  };

  const handleDeleteAccount = async () => {
    if (!confirm("This will PERMANENTLY delete your account and all health records. Continue?")) return;
    setDeletingAccount(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      const { error } = await supabase.functions.invoke("delete-account", {
        headers: { Authorization: `Bearer ${session?.access_token}` },
      });
      if (error) throw error;
      await supabase.auth.signOut();
      toast.success("Account deleted");
      navigate("/");
    } catch (err: any) {
      toast.error(err.message || "Failed to delete account");
    } finally {
      setDeletingAccount(false);
    }
  };

  const downloadRecord = (c: SymptomCheck) => {
    generateHealthReport(c, { name: fullName, email: user?.email });
    toast.success("Report downloaded");
  };

  const downloadAll = () => {
    if (!history.length) return toast.error("No records to export");
    generateFullHistoryReport(history, { name: fullName, email: user?.email });
    toast.success("Full history downloaded");
  };

  // === Derived stats for overview ===
  const stats = useMemo(() => {
    const total = history.length;
    const sev = { low: 0, moderate: 0, high: 0 };
    history.forEach((h) => {
      if (h.severity in sev) sev[h.severity as keyof typeof sev]++;
    });
    const avgConf = total ? Math.round(history.reduce((s, h) => s + h.confidence, 0) / total) : 0;
    // Health score: base 100 minus weighted severity, clamped
    const score = total === 0
      ? 100
      : Math.max(30, Math.min(100, Math.round(100 - (sev.high * 12 + sev.moderate * 5 + sev.low * 1) / Math.max(total, 1) * 4)));

    // Weekly activity (last 8 weeks)
    const weeks: { week: string; count: number }[] = [];
    const now = new Date();
    for (let i = 7; i >= 0; i--) {
      const start = new Date(now); start.setDate(now.getDate() - i * 7);
      const label = `${start.getMonth() + 1}/${start.getDate()}`;
      weeks.push({ week: label, count: 0 });
    }
    history.forEach((h) => {
      const d = new Date(h.created_at);
      const diffWeeks = Math.floor((now.getTime() - d.getTime()) / (7 * 24 * 3600 * 1000));
      if (diffWeeks >= 0 && diffWeeks < 8) weeks[7 - diffWeeks].count++;
    });
    return { total, sev, avgConf, score, weeks };
  }, [history]);

  const filteredHistory = useMemo(() => {
    let list = history;
    if (sevFilter !== "all") list = list.filter((h) => h.severity === sevFilter);
    if (search.trim()) {
      const q = search.toLowerCase();
      list = list.filter((h) => h.diagnosis.toLowerCase().includes(q) || h.symptoms.some((s) => s.toLowerCase().includes(q)));
    }
    if (sortMode === "recent") list = [...list].sort((a, b) => +new Date(b.created_at) - +new Date(a.created_at));
    if (sortMode === "confidence") list = [...list].sort((a, b) => b.confidence - a.confidence);
    if (sortMode === "severity") {
      const order = { high: 0, moderate: 1, low: 2 } as Record<string, number>;
      list = [...list].sort((a, b) => (order[a.severity] ?? 9) - (order[b.severity] ?? 9));
    }
    return list;
  }, [history, search, sortMode, sevFilter]);

  if (loading) {
    return <div className="flex min-h-screen items-center justify-center bg-background"><Loader2 className="h-8 w-8 animate-spin text-primary" /></div>;
  }

  const severityColor = (s: string) => {
    if (s === "high") return "bg-critical/10 text-critical border-critical/30";
    if (s === "moderate") return "bg-yellow-500/10 text-yellow-600 border-yellow-500/30 dark:text-yellow-400";
    return "bg-emerald-500/10 text-emerald-600 border-emerald-500/30 dark:text-emerald-400";
  };

  const scoreTone = stats.score >= 80 ? "text-emerald-500" : stats.score >= 60 ? "text-yellow-500" : "text-critical";
  const memberSince = profile?.created_at ? new Date(profile.created_at) : (user?.created_at ? new Date(user.created_at) : null);
  const lastLogin = user?.last_sign_in_at ? new Date(user.last_sign_in_at) : null;
  const emailVerified = !!user?.email_confirmed_at;

  const tabs = [
    { id: "overview" as const, label: "Overview", icon: Activity },
    { id: "profile" as const, label: "Profile", icon: User },
    { id: "history" as const, label: "History", icon: History },
    { id: "settings" as const, label: "Settings", icon: Settings },
  ];

  return (
    <div className="min-h-screen bg-background">
      <nav className="sticky top-0 z-20 flex items-center justify-between border-b border-border bg-card/80 px-4 py-3 backdrop-blur-md sm:px-6">
        <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground">
          <ArrowLeft className="h-4 w-4" />
          <span className="text-lg font-bold text-foreground"><span className="text-gradient-primary">My</span> Account</span>
        </button>
        <ThemeToggle />
      </nav>

      <div className="container mx-auto max-w-5xl px-4 py-6">
        {/* Hero header */}
        <div className="mb-6 overflow-hidden rounded-3xl border border-border bg-gradient-to-br from-primary/5 via-card to-accent/5 p-6 shadow-sm">
          <div className="flex flex-col items-start gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div className="flex items-center gap-4">
              <div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-primary/10 text-2xl font-bold text-primary">
                {fullName ? fullName.charAt(0).toUpperCase() : user?.email?.charAt(0)?.toUpperCase() || "U"}
              </div>
              <div>
                <h1 className="text-2xl font-bold text-foreground">{fullName || "Welcome"} 👋</h1>
                <p className="text-sm text-muted-foreground">{user?.email}</p>
                <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
                  <span className="rounded-full border border-primary/30 bg-primary/5 px-2.5 py-0.5 font-medium text-primary capitalize">{role}</span>
                  {emailVerified && (
                    <span className="inline-flex items-center gap-1 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-2.5 py-0.5 font-medium text-emerald-600 dark:text-emerald-400">
                      <ShieldCheck className="h-3 w-3" /> Verified
                    </span>
                  )}
                  {memberSince && (
                    <span className="inline-flex items-center gap-1 text-muted-foreground">
                      <Calendar className="h-3 w-3" /> Since {memberSince.toLocaleDateString("en-IN", { month: "short", year: "numeric" })}
                    </span>
                  )}
                </div>
              </div>
            </div>
            <div className="flex flex-col items-end gap-1">
              <div className="text-xs uppercase tracking-wider text-muted-foreground">Health Score</div>
              <div className={`flex items-baseline gap-1 text-4xl font-black ${scoreTone}`}>
                {stats.score}<span className="text-lg font-semibold text-muted-foreground">/100</span>
              </div>
            </div>
          </div>
        </div>

        {/* Tabs */}
        <div className="mb-6 flex gap-1 overflow-x-auto rounded-xl border border-border bg-muted/50 p-1">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`flex flex-1 min-w-fit items-center justify-center gap-2 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors ${
                activeTab === tab.id ? "bg-card text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground"
              }`}
            >
              <tab.icon className="h-4 w-4" />
              {tab.label}
            </button>
          ))}
        </div>

        {/* OVERVIEW */}
        {activeTab === "overview" && (
          <div className="space-y-6">
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
              <MiniStat icon={Activity} label="Total Checks" value={stats.total} tone="text-primary" />
              <MiniStat icon={Heart} label="Avg Confidence" value={`${stats.avgConf}%`} tone="text-emerald-500" />
              <MiniStat icon={AlertTriangle} label="High Risk" value={stats.sev.high} tone="text-critical" />
              <MiniStat icon={Sparkles} label="This Week" value={stats.weeks.at(-1)?.count ?? 0} tone="text-yellow-500" />
            </div>

            {/* Quick actions */}
            <div className="grid gap-3 sm:grid-cols-3">
              <QuickAction icon={Stethoscope} label="Start New Check" hint="Talk to the AI" onClick={() => navigate("/")} tone="primary" />
              <QuickAction icon={AlertTriangle} label="Emergency Help" hint="Nearby hospitals & 108" onClick={() => navigate("/?emergency=1")} tone="critical" />
              <QuickAction icon={FileText} label="Download Report" hint="Full history as PDF" onClick={downloadAll} tone="accent" />
            </div>

            {/* Weekly activity */}
            <div className="rounded-2xl border border-border bg-card p-6 shadow-sm">
              <h3 className="mb-4 text-sm font-semibold text-foreground">Weekly Activity</h3>
              <ResponsiveContainer width="100%" height={200}>
                <AreaChart data={stats.weeks}>
                  <defs>
                    <linearGradient id="fillWeekly" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stopColor="hsl(205, 85%, 45%)" stopOpacity={0.4} />
                      <stop offset="100%" stopColor="hsl(205, 85%, 45%)" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
                  <XAxis dataKey="week" tick={{ fontSize: 11 }} className="fill-muted-foreground" />
                  <YAxis tick={{ fontSize: 11 }} className="fill-muted-foreground" allowDecimals={false} />
                  <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid hsl(var(--border))", background: "hsl(var(--card))" }} />
                  <Area type="monotone" dataKey="count" stroke="hsl(205, 85%, 45%)" strokeWidth={2} fill="url(#fillWeekly)" />
                </AreaChart>
              </ResponsiveContainer>
            </div>

            {/* Recent + Risk distribution */}
            <div className="grid gap-4 lg:grid-cols-2">
              <div className="rounded-2xl border border-border bg-card p-6 shadow-sm">
                <h3 className="mb-4 text-sm font-semibold text-foreground">Recent Predictions</h3>
                {history.slice(0, 4).length === 0 ? (
                  <p className="text-sm text-muted-foreground">No health checks yet. Start your first one!</p>
                ) : (
                  <ul className="space-y-3">
                    {history.slice(0, 4).map((h) => (
                      <li key={h.id} className="flex items-center justify-between gap-3">
                        <div className="min-w-0">
                          <p className="truncate text-sm font-medium text-foreground">{h.diagnosis}</p>
                          <p className="text-xs text-muted-foreground">{new Date(h.created_at).toLocaleDateString()}</p>
                        </div>
                        <span className={`shrink-0 rounded-full border px-2 py-0.5 text-xs font-medium capitalize ${severityColor(h.severity)}`}>
                          {h.severity}
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </div>

              <div className="rounded-2xl border border-border bg-card p-6 shadow-sm">
                <h3 className="mb-4 text-sm font-semibold text-foreground">Risk Distribution</h3>
                <div className="space-y-3">
                  {[
                    { label: "Low", value: stats.sev.low, color: "bg-emerald-500" },
                    { label: "Moderate", value: stats.sev.moderate, color: "bg-yellow-500" },
                    { label: "High", value: stats.sev.high, color: "bg-critical" },
                  ].map((row) => {
                    const pct = stats.total ? Math.round((row.value / stats.total) * 100) : 0;
                    return (
                      <div key={row.label}>
                        <div className="mb-1 flex justify-between text-xs">
                          <span className="font-medium text-foreground">{row.label}</span>
                          <span className="text-muted-foreground">{row.value} ({pct}%)</span>
                        </div>
                        <div className="h-2 overflow-hidden rounded-full bg-muted">
                          <div className={`h-full ${row.color} transition-all`} style={{ width: `${pct}%` }} />
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            </div>

            {/* Health tip */}
            <div className="rounded-2xl border border-primary/20 bg-primary/5 p-5">
              <div className="flex items-start gap-3">
                <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-primary/10">
                  <Zap className="h-5 w-5 text-primary" />
                </div>
                <div>
                  <h4 className="text-sm font-semibold text-foreground">Today's Health Tip</h4>
                  <p className="mt-1 text-sm text-muted-foreground">
                    Drink at least 2 litres of water and take short walking breaks every hour to stay energised.
                  </p>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* PROFILE */}
        {activeTab === "profile" && (
          <div className="space-y-4 rounded-2xl border border-border bg-card p-6">
            <h2 className="text-base font-semibold text-foreground">Personal Information</h2>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field icon={User} label="Full Name" value={fullName} onChange={setFullName} placeholder="Your full name" />
              <Field icon={Phone} label="Phone" value={phone} onChange={setPhone} placeholder="+91 98765 43210" />
              <Field icon={Mail} label="Email" value={user?.email || ""} onChange={() => {}} disabled />
            </div>

            <hr className="border-border" />
            <h2 className="text-base font-semibold text-foreground">NGO / Organization Details</h2>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field icon={Building2} label="Organization Name" value={orgName} onChange={setOrgName} placeholder="e.g. Health First NGO" />
              <Field icon={MapPin} label="Region" value={region} onChange={setRegion} placeholder="e.g. Rural Maharashtra" />
              <div className="sm:col-span-2">
                <Field icon={Mail} label="Contact Info" value={contactInfo} onChange={setContactInfo} placeholder="Additional contact details" />
              </div>
            </div>

            <div className="flex items-center gap-3 pt-2">
              <label className="text-sm font-medium text-muted-foreground">Account Type</label>
              <div className="flex gap-2">
                {["user", "ngo"].map((r) => (
                  <button key={r} onClick={() => setRole(r)}
                    className={`rounded-full border px-4 py-1.5 text-xs font-medium capitalize transition-colors ${
                      role === r ? "border-primary bg-primary/10 text-primary" : "border-border text-muted-foreground hover:text-foreground"
                    }`}>
                    {r === "ngo" ? "NGO" : "User"}
                  </button>
                ))}
              </div>
            </div>

            <button onClick={handleSave} disabled={saving}
              className="mt-4 flex items-center gap-2 rounded-xl bg-primary px-6 py-2.5 text-sm font-semibold text-primary-foreground shadow-lg transition-transform hover:scale-[1.02] disabled:opacity-50">
              {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
              Save Profile
            </button>
          </div>
        )}

        {/* HISTORY */}
        {activeTab === "history" && (
          <div className="space-y-4">
            {/* Toolbar */}
            <div className="flex flex-col gap-3 rounded-2xl border border-border bg-card p-4 sm:flex-row sm:items-center">
              <div className="relative flex-1">
                <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
                <input
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="Search diagnosis or symptom…"
                  className="w-full rounded-lg border border-border bg-background pl-9 pr-3 py-2 text-sm focus:border-primary focus:outline-none"
                />
              </div>
              <select value={sevFilter} onChange={(e) => setSevFilter(e.target.value as SeverityFilter)}
                className="rounded-lg border border-border bg-background px-3 py-2 text-sm focus:border-primary focus:outline-none">
                <option value="all">All severity</option>
                <option value="low">Low</option>
                <option value="moderate">Moderate</option>
                <option value="high">High</option>
              </select>
              <select value={sortMode} onChange={(e) => setSortMode(e.target.value as SortMode)}
                className="rounded-lg border border-border bg-background px-3 py-2 text-sm focus:border-primary focus:outline-none">
                <option value="recent">Most recent</option>
                <option value="severity">By severity</option>
                <option value="confidence">By confidence</option>
              </select>
              <button onClick={downloadAll} disabled={!history.length}
                className="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-50">
                <Download className="h-4 w-4" /> Export all
              </button>
            </div>

            {filteredHistory.length === 0 ? (
              <div className="rounded-2xl border border-border bg-card p-10 text-center">
                <History className="mx-auto mb-3 h-10 w-10 text-muted-foreground" />
                <p className="font-medium text-foreground">{history.length === 0 ? "No symptom checks yet" : "No matching records"}</p>
                <p className="mt-1 text-sm text-muted-foreground">
                  {history.length === 0 ? "Start a health check to see your history here." : "Try a different search or filter."}
                </p>
                {history.length === 0 && (
                  <button onClick={() => navigate("/")} className="mt-4 rounded-xl bg-primary px-5 py-2 text-sm font-semibold text-primary-foreground">
                    Start Health Check
                  </button>
                )}
              </div>
            ) : (
              filteredHistory.map((check) => {
                const expanded = expandedId === check.id;
                return (
                  <div key={check.id} className="rounded-2xl border border-border bg-card p-4 transition-all hover:border-primary/30">
                    <div className="flex items-start justify-between gap-3">
                      <button onClick={() => setExpandedId(expanded ? null : check.id)} className="flex-1 text-left">
                        <h3 className="font-semibold text-foreground">{check.diagnosis}</h3>
                        <p className="mt-1 text-xs text-muted-foreground">
                          {new Date(check.created_at).toLocaleString("en-IN", {
                            day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit",
                          })}
                        </p>
                        <div className="mt-2 flex flex-wrap gap-1.5">
                          {check.symptoms.slice(0, expanded ? undefined : 4).map((s, i) => (
                            <span key={i} className="rounded-full border border-border bg-muted/50 px-2 py-0.5 text-xs text-muted-foreground">{s}</span>
                          ))}
                          {!expanded && check.symptoms.length > 4 && (
                            <span className="text-xs text-muted-foreground">+{check.symptoms.length - 4} more</span>
                          )}
                        </div>
                      </button>
                      <div className="flex flex-col items-end gap-1.5">
                        <span className={`rounded-full border px-2.5 py-0.5 text-xs font-medium capitalize ${severityColor(check.severity)}`}>{check.severity}</span>
                        <span className="text-xs font-medium text-muted-foreground">{check.confidence}%</span>
                      </div>
                    </div>

                    {expanded && check.recommendations && check.recommendations.length > 0 && (
                      <div className="mt-4 rounded-xl bg-muted/40 p-3">
                        <p className="mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Recommendations</p>
                        <ul className="space-y-1 text-sm text-foreground/90">
                          {check.recommendations.map((r, i) => <li key={i}>• {r}</li>)}
                        </ul>
                      </div>
                    )}

                    <div className="mt-3 flex items-center justify-between border-t border-border pt-3">
                      <button onClick={() => setExpandedId(expanded ? null : check.id)}
                        className="inline-flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground">
                        {expanded ? <ChevronUp className="h-3.5 w-3.5" /> : <ChevronDown className="h-3.5 w-3.5" />}
                        {expanded ? "Collapse" : "Expand"}
                      </button>
                      <div className="flex gap-2">
                        <button onClick={() => downloadRecord(check)}
                          className="inline-flex items-center gap-1 rounded-lg border border-border px-2.5 py-1.5 text-xs font-medium text-foreground hover:border-primary hover:text-primary">
                          <Download className="h-3.5 w-3.5" /> PDF
                        </button>
                        <button onClick={() => handleDeleteRecord(check.id)}
                          className="inline-flex items-center gap-1 rounded-lg border border-critical/30 bg-critical/5 px-2.5 py-1.5 text-xs font-medium text-critical hover:bg-critical/10">
                          <Trash2 className="h-3.5 w-3.5" /> Delete
                        </button>
                      </div>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        )}

        {/* SETTINGS */}
        {activeTab === "settings" && (
          <div className="space-y-4">
            <div className="rounded-2xl border border-border bg-card p-6">
              <h2 className="mb-4 text-base font-semibold text-foreground">Account Info</h2>
              <dl className="grid gap-3 text-sm sm:grid-cols-2">
                <InfoRow label="Email" value={user?.email || "—"} />
                <InfoRow label="Email Verified" value={emailVerified ? "Yes" : "No"} tone={emailVerified ? "text-emerald-600" : "text-yellow-600"} />
                <InfoRow label="Member Since" value={memberSince ? memberSince.toLocaleDateString() : "—"} />
                <InfoRow label="Last Login" value={lastLogin ? lastLogin.toLocaleString() : "—"} />
              </dl>
            </div>

            <div className="rounded-2xl border border-border bg-card p-6 space-y-3">
              <h2 className="text-base font-semibold text-foreground">Security</h2>
              <button onClick={handleChangePassword}
                className="flex w-full items-center gap-3 rounded-xl border border-border p-4 text-left transition-colors hover:bg-muted/50">
                <Settings className="h-5 w-5 text-muted-foreground" />
                <div>
                  <p className="text-sm font-medium text-foreground">Change Password</p>
                  <p className="text-xs text-muted-foreground">We'll send a reset link to your email</p>
                </div>
              </button>
              <button onClick={handleLogout}
                className="flex w-full items-center gap-3 rounded-xl border border-border p-4 text-left transition-colors hover:bg-muted/50">
                <LogOut className="h-5 w-5 text-muted-foreground" />
                <div>
                  <p className="text-sm font-medium text-foreground">Log Out</p>
                  <p className="text-xs text-muted-foreground">Sign out of your account</p>
                </div>
              </button>
            </div>

            <div className="rounded-2xl border border-critical/30 bg-critical/5 p-6">
              <h2 className="mb-3 text-base font-semibold text-critical">Danger Zone</h2>
              <button onClick={handleDeleteAccount} disabled={deletingAccount}
                className="inline-flex items-center gap-2 rounded-xl bg-critical px-5 py-2.5 text-sm font-semibold text-critical-foreground shadow-lg hover:opacity-90 disabled:opacity-50">
                {deletingAccount ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
                Delete Account Permanently
              </button>
              <p className="mt-2 text-xs text-muted-foreground">
                This removes your profile, all symptom checks, and login access. This cannot be undone.
              </p>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

const MiniStat = ({ icon: Icon, label, value, tone }: { icon: any; label: string; value: string | number; tone?: string }) => (
  <div className="rounded-2xl border border-border bg-card p-4 shadow-sm">
    <div className="flex items-center gap-2 text-xs font-medium text-muted-foreground">
      <Icon className={`h-4 w-4 ${tone || "text-primary"}`} /> {label}
    </div>
    <div className="mt-2 text-2xl font-bold text-foreground">{value}</div>
  </div>
);

const QuickAction = ({ icon: Icon, label, hint, onClick, tone }: { icon: any; label: string; hint: string; onClick: () => void; tone: "primary" | "critical" | "accent" }) => {
  const toneClasses = {
    primary: "border-primary/30 bg-primary/5 text-primary hover:bg-primary/10",
    critical: "border-critical/30 bg-critical/5 text-critical hover:bg-critical/10",
    accent: "border-border bg-card text-foreground hover:border-primary",
  }[tone];
  return (
    <button onClick={onClick} className={`group flex items-start gap-3 rounded-2xl border p-4 text-left transition-all hover:-translate-y-0.5 ${toneClasses}`}>
      <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-background/70">
        <Icon className="h-5 w-5" />
      </div>
      <div>
        <p className="text-sm font-semibold">{label}</p>
        <p className="text-xs opacity-70">{hint}</p>
      </div>
    </button>
  );
};

const InfoRow = ({ label, value, tone }: { label: string; value: string; tone?: string }) => (
  <div>
    <dt className="text-xs font-medium uppercase tracking-wider text-muted-foreground">{label}</dt>
    <dd className={`mt-1 text-sm font-medium ${tone || "text-foreground"}`}>{value}</dd>
  </div>
);

const Field = ({ icon: Icon, label, value, onChange, placeholder, disabled }: { icon: any; label: string; value: string; onChange: (v: string) => void; placeholder?: string; disabled?: boolean }) => (
  <div>
    <label className="mb-1.5 flex items-center gap-1.5 text-xs font-medium text-muted-foreground">
      <Icon className="h-3.5 w-3.5" /> {label}
    </label>
    <input value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} disabled={disabled}
      className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary disabled:opacity-50" />
  </div>
);

export default Profile;
