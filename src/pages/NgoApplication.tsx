import { useCallback, useEffect, useState, type FormEvent } from "react";
import { ArrowLeft, Building2, Loader2, ShieldCheck } from "lucide-react";
import { Link, useNavigate } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import ThemeToggle from "@/components/ThemeToggle";

type Application = {
  id: string;
  organization_name: string;
  status: "pending" | "approved" | "rejected" | "suspended";
  review_reason: string | null;
  decided_at: string | null;
  created_at: string;
};
type ApplicationStatus = { application: Application | null; canSubmit: boolean; dashboardAvailable: boolean };

const NgoApplication = () => {
  const navigate = useNavigate();
  const [status, setStatus] = useState<ApplicationStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const request = useCallback(async (body: Record<string, unknown>) => {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) {
      navigate("/ngo/login", { replace: true });
      throw new Error("Your session expired. Sign in again to continue.");
    }
    const { data, error: requestError } = await supabase.functions.invoke("ngo-application", {
      headers: { Authorization: `Bearer ${session.access_token}` },
      body,
    });
    if (requestError) {
      const status = requestError.context instanceof Response ? requestError.context.status : undefined;
      if (status === 401) throw new Error("Your session expired. Sign in again to continue.");
      if (status === 403) throw new Error("This account is not permitted to submit an NGO application.");
      if (status === 409) throw new Error("You already have a pending NGO application.");
      throw requestError;
    }
    return data;
  }, [navigate]);

  const loadStatus = useCallback(async () => {
    setError("");
    setLoading(true);
    try {
      setStatus(await request({ action: "status" }) as ApplicationStatus);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to load your application status.");
    } finally {
      setLoading(false);
    }
  }, [request]);

  useEffect(() => { void loadStatus(); }, [loadStatus]);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!status?.canSubmit) return;
    setError("");
    const form = new FormData(event.currentTarget);
    const evidenceReferences = String(form.get("evidenceReferences") ?? "")
      .split("\n").map((value) => value.trim()).filter(Boolean);
    setSaving(true);
    try {
      await request({
        action: "submit",
        organizationName: form.get("organizationName"),
        registrationIdentifier: form.get("registrationIdentifier"),
        officialContactEmail: form.get("officialContactEmail"),
        officialContactPhone: form.get("officialContactPhone"),
        website: form.get("website"),
        evidenceReferences,
      });
      await loadStatus();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not submit the application.");
    } finally {
      setSaving(false);
    }
  };

  const application = status?.application;
  return <div className="min-h-screen bg-background">
    <nav className="flex items-center justify-between border-b border-border bg-card px-4 py-3">
      <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="h-4 w-4" /> Back</button>
      <ThemeToggle />
    </nav>
    <main className="mx-auto max-w-2xl px-4 py-10">
      <div className="rounded-3xl border border-border bg-card p-6 shadow-sm sm:p-8">
        <div className="mb-6 flex items-center gap-3"><Building2 className="h-7 w-7 text-primary" /><div><h1 className="text-2xl font-bold">NGO portal</h1><p className="text-sm text-muted-foreground">Applications are reviewed by an authorized administrator.</p></div></div>
        <div className="mb-6 rounded-xl border border-primary/20 bg-primary/5 p-3 text-sm text-muted-foreground"><ShieldCheck className="mr-2 inline h-4 w-4 text-primary" />Do not include patient data, credentials, or sensitive documents in evidence references.</div>
        {loading ? <div className="flex items-center gap-2 py-8 text-sm text-muted-foreground"><Loader2 className="h-5 w-5 animate-spin" />Loading application status…</div> : error && !status ? (
          <div role="alert" className="space-y-3 text-sm text-critical"><p>{error}</p><button onClick={() => void loadStatus()} className="rounded-lg border border-border px-3 py-2 text-foreground">Retry</button></div>
        ) : status?.dashboardAvailable ? (
          <div className="space-y-4"><StatusBanner status="approved" organizationName={application?.organization_name} /><p className="text-sm text-muted-foreground">Your organization is approved. Health analytics remain subject to the current privacy-safe reporting availability.</p><Link to="/ngo/dashboard" className="inline-flex rounded-xl bg-primary px-5 py-3 font-semibold text-primary-foreground">Open NGO dashboard</Link></div>
        ) : application?.status === "pending" ? (
          <StatusBanner status="pending" organizationName={application.organization_name} />
        ) : application?.status === "suspended" ? (
          <div className="space-y-3"><StatusBanner status="suspended" organizationName={application.organization_name} reason={application.review_reason} /><p className="text-sm text-muted-foreground">Dashboard access is unavailable while this application is suspended. Contact the administrator if you need clarification.</p><Link className="text-sm text-primary underline" to="/contact">Contact support</Link></div>
        ) : application?.status === "rejected" && !status?.canSubmit ? (
          <StatusBanner status="rejected" organizationName={application.organization_name} reason={application.review_reason} />
        ) : application?.status === "approved" ? (
          <div className="space-y-3"><StatusBanner status="approved" organizationName={application.organization_name} /><p className="text-sm text-muted-foreground">Approval and profile access do not currently agree. Dashboard access is withheld; contact an administrator to reconcile the account.</p></div>
        ) : (
          <>
            {application?.status === "rejected" && <StatusBanner status="rejected" organizationName={application.organization_name} reason={application.review_reason} />}
            {status?.canSubmit ? <form onSubmit={submit} className="mt-6 space-y-4">
              <h2 className="text-lg font-semibold">{application ? "Submit an updated application" : "Apply for NGO verification"}</h2>
              <Input name="organizationName" label="Organization name" required maxLength={200} />
              <Input name="registrationIdentifier" label="Registration identifier" required maxLength={160} />
              <Input name="officialContactEmail" type="email" label="Official contact email" required maxLength={320} />
              <Input name="officialContactPhone" label="Official contact phone" required maxLength={64} />
              <Input name="website" type="url" label="Website (optional)" maxLength={2048} />
              <label className="block text-sm font-medium">Evidence references (optional)<textarea name="evidenceReferences" rows={4} className="mt-1 w-full rounded-xl border border-border bg-background p-3" placeholder="One secure reference per line; do not paste document contents" /></label>
              {error && <p role="alert" className="text-sm text-critical">{error}</p>}
              <button disabled={saving} className="flex items-center gap-2 rounded-xl bg-primary px-5 py-3 font-semibold text-primary-foreground disabled:opacity-50">{saving && <Loader2 className="h-4 w-4 animate-spin" />}{application ? "Resubmit for review" : "Submit for review"}</button>
            </form> : !application && <p className="text-sm text-muted-foreground">This account cannot submit an NGO application. Sign in with a standard user account or contact support.</p>}
          </>
        )}
        {error && status && <p role="alert" className="mt-4 text-sm text-critical">{error}</p>}
      </div>
    </main>
  </div>;
};

const StatusBanner = ({ status, organizationName, reason }: { status: Application["status"]; organizationName?: string; reason?: string | null }) => {
  const labels = {
    pending: "Pending review",
    approved: "Approved",
    rejected: "Application rejected",
    suspended: "Application suspended",
  };
  return <section className="rounded-xl border border-border bg-muted/40 p-4">
    <p className="font-semibold">{labels[status]}{organizationName ? ` · ${organizationName}` : ""}</p>
    {status === "pending" && <p className="mt-1 text-sm text-muted-foreground">Your application is awaiting administrator review. NGO analytics is not available until approval.</p>}
    {reason && <p className="mt-2 text-sm"><strong>Review reason:</strong> {reason}</p>}
  </section>;
};

const Input = ({ label, ...props }: React.InputHTMLAttributes<HTMLInputElement> & { label: string }) => <label className="block text-sm font-medium">{label}<input {...props} className="mt-1 w-full rounded-xl border border-border bg-background p-3" /></label>;

export default NgoApplication;
