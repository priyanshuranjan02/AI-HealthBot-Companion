import { useNavigate } from "react-router-dom";
import { ArrowLeft, Target, Cpu, Users, Sparkles, ShieldCheck, Globe2, Layers } from "lucide-react";
import ThemeToggle from "@/components/ThemeToggle";

const About = () => {
  const navigate = useNavigate();

  return (
    <div className="min-h-screen bg-background">
      <nav className="sticky top-0 z-20 flex items-center justify-between border-b border-border bg-card/80 px-4 py-3 backdrop-blur-md sm:px-6">
        <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground">
          <ArrowLeft className="h-4 w-4" />
          <span className="text-lg font-bold text-foreground"><span className="text-gradient-primary">About</span> HealthBot</span>
        </button>
        <ThemeToggle />
      </nav>

      <div className="container mx-auto max-w-4xl px-4 py-10 space-y-10">
        <header className="text-center">
          <div className="inline-flex items-center gap-2 rounded-full bg-primary/10 px-3 py-1 text-xs font-semibold text-primary">
            <Sparkles className="h-3.5 w-3.5" /> About the project
          </div>
          <h1 className="mt-4 text-4xl font-extrabold tracking-tight text-foreground md:text-5xl">
            Democratising healthcare with <span className="text-gradient-primary">explainable AI</span>
          </h1>
          <p className="mx-auto mt-4 max-w-2xl text-muted-foreground">
            AI HealthBot is a multilingual symptom-assessment platform built to make first-line
            healthcare guidance accessible to rural and underserved communities across India.
          </p>
        </header>

        <Section icon={Target} title="Mission">
          Empower every person with fast, private, and understandable health guidance —
          regardless of language, location, or literacy level.
        </Section>

        <Section icon={ShieldCheck} title="Problem Statement">
          In many rural regions, the first available doctor is hours away. People often wait too
          long or self-medicate. AI HealthBot bridges the gap by offering conversational triage,
          severity assessment, and emergency guidance in the user's own language.
        </Section>

        <Section icon={Layers} title="Architecture Overview">
          A React + Vite front-end talks to a serverless backend on Lovable Cloud (Supabase).
          Symptom analysis is performed by Google Gemini 2.5 Pro through the Lovable AI Gateway,
          with streaming responses. Every assessment is stored anonymously in Postgres and
          aggregated for the NGO analytics dashboard.
        </Section>

        <Section icon={Cpu} title="Technology Stack">
          <ul className="grid gap-2 sm:grid-cols-2 text-sm text-muted-foreground">
            <li>• React 18 + Vite + TypeScript</li>
            <li>• Tailwind CSS + shadcn/ui</li>
            <li>• Supabase (Auth, Postgres, Edge Functions)</li>
            <li>• Gemini 2.5 Pro via Lovable AI Gateway</li>
            <li>• Recharts for analytics</li>
            <li>• jsPDF for downloadable reports</li>
          </ul>
        </Section>

        <Section icon={Globe2} title="Project Goals">
          <ul className="space-y-1.5 text-sm text-muted-foreground">
            <li>• Reach 10+ Indian languages with dialect awareness</li>
            <li>• Provide explainable risk assessment, not black-box scores</li>
            <li>• Offer real-time NGO analytics for health outreach programs</li>
            <li>• Stay lightweight enough to run on low-bandwidth mobile networks</li>
          </ul>
        </Section>

        <Section icon={Users} title="Team & Supervision">
          Built as an EPICS / IEEE research initiative. Contributors span computer science,
          public health, and community outreach domains — advised by faculty supervisors and
          partner NGOs.
        </Section>

        <footer className="rounded-2xl border border-border bg-card p-6 text-center text-sm text-muted-foreground">
          Research motivation: bridge the gap between AI capability and last-mile health access.
        </footer>
      </div>
    </div>
  );
};

const Section = ({
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

export default About;
