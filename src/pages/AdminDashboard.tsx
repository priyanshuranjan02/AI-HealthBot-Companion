import { useCallback, useEffect, useState } from "react";
import { ArrowLeft, Building2, Loader2, ShieldAlert } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import ThemeToggle from "@/components/ThemeToggle";
import { availableReviewActions } from "../../supabase/functions/admin-ngo-management/response";

type Application = {
  id: string;
  organization_name: string;
  registration_identifier: string;
  official_contact_email: string;
  official_contact_phone: string;
  website: string | null;
  evidenceCount: number;
  status: "pending" | "approved" | "rejected" | "suspended";
  created_at: string;
  decided_at: string | null;
  review_reason: string | null;
};
type Data = { counts: Record<string, number>; applications: Application[] };

const AdminDashboard = () => {
  const navigate = useNavigate();
  const [data, setData] = useState<Data | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [reason, setReason] = useState<Record<string, string>>({});
  const [busyId, setBusyId] = useState("");
  const [switchingAccount, setSwitchingAccount] = useState(false);

  const request = useCallback(async (body: Record<string, unknown> = {}) => {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) {
      navigate("/admin/login", { replace: true });
      throw new Error("Your session expired. Sign in again to continue.");
    }
    const { data: result, error: requestError } = await supabase.functions.invoke("admin-ngo-management", {
      headers: { Authorization: `Bearer ${session.access_token}` },
      body,
    });
    if (requestError) {
      const status = requestError.context instanceof Response ? requestError.context.status : undefined;
      if (status === 401) throw new Error("Your session expired. Sign in again to continue.");
      if (status === 403) throw new Error("Administrator access is required. Ask a trusted operator if you believe this is an error.");
      throw requestError;
    }
    return result as Data | { success: true };
  }, [navigate]);

  const load = useCallback(async () => {
    setError("");
    setLoading(true);
    try {
      const result = await request();
      if ("applications" in result) setData(result);
      else throw new Error("The administrator service returned an invalid response.");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to load administrator dashboard.");
    } finally {
      setLoading(false);
    }
  }, [request]);

  useEffect(() => { void load(); }, [load]);

  const review = async (application: Application, status: "approved" | "rejected" | "suspended") => {
    const value = reason[application.id]?.trim() ?? "";
    if ((status === "rejected" || status === "suspended") && !value) {
      setError("A reason is required for rejection or suspension.");
      return;
    }
    if (value.length > 2000) {
      setError("Review reasons must be 2,000 characters or fewer.");
      return;
    }

    setError("");
    setBusyId(application.id);
    try {
      await request({ action: "review", applicationId: application.id, status, reason: value });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Review failed. No status change was confirmed.");
    } finally {
      setBusyId("");
    }
  };

  const switchAccount = async () => {
    setSwitchingAccount(true);
    setError("");
    try {
      const { error: signOutError } = await supabase.auth.signOut({ scope: "local" });
      if (signOutError) throw signOutError;
    } catch {
      setSwitchingAccount(false);
      setError("Sign-out failed. Your current account is still active; please retry.");
      return;
    }
    setSwitchingAccount(false);
    navigate("/admin/login", { replace: true });
  };

  return <div className="min-h-screen bg-background">
    <nav className="flex items-center justify-between border-b border-border bg-card px-4 py-3">
      <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm text-muted-foreground"><ArrowLeft className="h-4 w-4" /> Back</button>
      <ThemeToggle />
    </nav>
    <main className="mx-auto max-w-6xl px-4 py-8">
      <h1 className="text-2xl font-bold">Administrator: NGO verification</h1>
      <p className="mt-1 text-sm text-muted-foreground">Review decisions are authorized and audited by the database workflow. Evidence contents remain restricted.</p>
      {loading ? <Loader2 className="mt-10 h-7 w-7 animate-spin text-primary" /> : error && !data ? (
        <div className="mt-8 rounded-xl border border-critical/30 p-5 text-critical" role="alert">
          <ShieldAlert className="mr-2 inline h-5 w-5" />{error}
          <p className="mt-3 text-sm">If this account is not an administrator, ask a trusted operator to provision access.</p>
          <button type="button" onClick={() => void load()} disabled={loading}
            className="mt-3 mr-4 inline-flex items-center gap-2 text-sm underline disabled:opacity-50">
            {loading && <Loader2 className="h-4 w-4 animate-spin" />}
            Retry access check
          </button>
          <button type="button" onClick={() => void switchAccount()} disabled={switchingAccount}
            className="mt-3 inline-flex items-center gap-2 text-sm underline disabled:opacity-50">
            {switchingAccount && <Loader2 className="h-4 w-4 animate-spin" />}
            Sign out and use another account
          </button>
        </div>
      ) : <>
        {error && <p className="mt-4 text-sm text-critical" role="alert">{error}</p>}
        <div className="mt-6 grid grid-cols-2 gap-3 md:grid-cols-3">
          {Object.entries(data?.counts ?? {}).map(([label, value]) => <div key={label} className="rounded-xl border border-border bg-card p-4">
            <p className="text-xs capitalize text-muted-foreground">{label.replace(/([A-Z])/g, " $1")}</p><p className="text-2xl font-bold">{value}</p>
          </div>)}
        </div>
        <section className="mt-8 space-y-4">
          {(data?.applications ?? []).map((item) => {
            const actions = availableReviewActions(item.status);
            const pending = actions.includes("approved");
            return <article key={item.id} className="rounded-2xl border border-border bg-card p-5">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h2 className="font-semibold">{item.organization_name}</h2>
                  <p className="text-sm text-muted-foreground">{item.registration_identifier} · <span className="capitalize">{item.status}</span></p>
                  <p className="mt-2 text-sm">{item.official_contact_email} · {item.official_contact_phone}</p>
                  {item.website && <a className="text-sm text-primary" href={item.website} target="_blank" rel="noreferrer">Website</a>}
                  {item.evidenceCount > 0 && <p className="mt-2 text-xs text-muted-foreground">{item.evidenceCount} evidence reference(s) were submitted. Their values are intentionally not returned by this dashboard endpoint.</p>}
                  {item.review_reason && <p className="mt-3 rounded-lg bg-muted p-3 text-sm"><strong>Recorded review reason:</strong> {item.review_reason}</p>}
                  {item.decided_at && <p className="mt-1 text-xs text-muted-foreground">Reviewed {new Date(item.decided_at).toLocaleString()}</p>}
                </div>
                <Building2 className="h-6 w-6 text-primary" />
              </div>
              {actions.length > 0 && <div className="mt-4 space-y-3">
                <label className="block text-sm font-medium">{pending ? "Review reason (required for rejection)" : "Suspension reason (required)"}
                  <textarea value={reason[item.id] ?? ""} maxLength={2000} onChange={(event) => setReason({ ...reason, [item.id]: event.target.value })} rows={2} className="mt-1 w-full rounded-lg border border-border bg-background px-3 py-2 text-sm" placeholder="Enter the reason for this decision" />
                </label>
                <div className="flex flex-wrap gap-2">
                  {actions.includes("approved") && <>
                    <button disabled={busyId === item.id} onClick={() => void review(item, "approved")} className="rounded-lg bg-primary px-3 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50">Approve</button>
                    <button disabled={busyId === item.id} onClick={() => void review(item, "rejected")} className="rounded-lg border border-critical px-3 py-2 text-sm text-critical disabled:opacity-50">Reject</button>
                  </>}
                  {actions.includes("suspended") && <button disabled={busyId === item.id} onClick={() => void review(item, "suspended")} className="rounded-lg border border-critical px-3 py-2 text-sm text-critical disabled:opacity-50">Suspend NGO access</button>}
                  {busyId === item.id && <Loader2 className="h-5 w-5 animate-spin text-primary" aria-label="Saving review" />}
                </div>
              </div>}
            </article>;
          })}
          {data?.applications.length === 0 && <p className="rounded-xl border border-border p-6 text-sm text-muted-foreground">There are no NGO applications to review.</p>}
        </section>
      </>}
    </main>
  </div>;
};

export default AdminDashboard;
