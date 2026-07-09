import { useNavigate } from "react-router-dom";
import { ArrowLeft, ShieldCheck, FileText, AlertTriangle, Cookie } from "lucide-react";
import ThemeToggle from "@/components/ThemeToggle";

const Privacy = () => {
  const navigate = useNavigate();
  return (
    <div className="min-h-screen bg-background">
      <nav className="sticky top-0 z-20 flex items-center justify-between border-b border-border bg-card/80 px-4 py-3 backdrop-blur-md sm:px-6">
        <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground">
          <ArrowLeft className="h-4 w-4" />
          <span className="text-lg font-bold text-foreground"><span className="text-gradient-primary">Privacy</span> & Terms</span>
        </button>
        <ThemeToggle />
      </nav>

      <div className="container mx-auto max-w-3xl px-4 py-10 space-y-6">
        <p className="text-sm text-muted-foreground">
          This page is maintained by the AI HealthBot project team to explain what data the
          application collects and how it is used. Last updated: {new Date().toLocaleDateString()}.
        </p>

        <Card icon={ShieldCheck} title="Privacy Policy">
          <p>We collect only what is necessary to provide the service:</p>
          <ul className="mt-2 list-disc pl-5 space-y-1">
            <li>Account details you provide (email, name, optional organisation info).</li>
            <li>Symptom text you submit and the AI-generated assessment.</li>
            <li>Basic technical metadata (language, timestamp) used for analytics.</li>
          </ul>
          <p className="mt-3">
            Data is stored on Lovable Cloud (Supabase) with row-level security so each user can
            only access their own records. Aggregated (non-identifying) data may power the NGO
            analytics dashboard. You can delete your account and history at any time from your
            profile settings.
          </p>
        </Card>

        <Card icon={AlertTriangle} title="Medical Disclaimer">
          AI HealthBot provides general health information and educational guidance only.
          It is <strong>not</strong> a substitute for professional medical advice, diagnosis, or
          treatment. Never disregard professional medical advice or delay seeking it because of
          something you read here. For emergencies, call 108 (India) or your local emergency
          number.
        </Card>

        <Card icon={FileText} title="Terms of Use">
          By using AI HealthBot you agree to use it lawfully and responsibly, not attempt to
          reverse-engineer the service, not misuse the AI to obtain harmful advice, and accept
          that the service is provided on an "as-is" basis without warranty. Account access may
          be suspended for abuse.
        </Card>

        <Card icon={Cookie} title="Cookie Policy">
          We use only essential cookies and local storage to keep you signed in and to remember
          your language and theme preferences. No third-party advertising cookies are used.
        </Card>
      </div>
    </div>
  );
};

const Card = ({
  icon: Icon,
  title,
  children,
}: {
  icon: any;
  title: string;
  children: React.ReactNode;
}) => (
  <section className="rounded-2xl border border-border bg-card p-6 shadow-sm">
    <div className="mb-3 flex items-center gap-3">
      <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-primary/10">
        <Icon className="h-5 w-5 text-primary" />
      </div>
      <h2 className="text-lg font-bold text-foreground">{title}</h2>
    </div>
    <div className="text-sm leading-relaxed text-muted-foreground">{children}</div>
  </section>
);

export default Privacy;
