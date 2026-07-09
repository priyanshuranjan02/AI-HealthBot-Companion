import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, Mail, Github, Linkedin, Send, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { z } from "zod";
import ThemeToggle from "@/components/ThemeToggle";

const schema = z.object({
  name: z.string().trim().min(1, "Name required").max(80),
  email: z.string().trim().email("Invalid email").max(255),
  message: z.string().trim().min(5, "Message too short").max(1000),
});

const Contact = () => {
  const navigate = useNavigate();
  const [form, setForm] = useState({ name: "", email: "", message: "" });
  const [sending, setSending] = useState(false);

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const parsed = schema.safeParse(form);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0].message);
      return;
    }
    setSending(true);
    setTimeout(() => {
      setSending(false);
      setForm({ name: "", email: "", message: "" });
      toast.success("Thanks! We'll get back to you shortly.");
    }, 700);
  };

  return (
    <div className="min-h-screen bg-background">
      <nav className="sticky top-0 z-20 flex items-center justify-between border-b border-border bg-card/80 px-4 py-3 backdrop-blur-md sm:px-6">
        <button onClick={() => navigate("/")} className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground">
          <ArrowLeft className="h-4 w-4" />
          <span className="text-lg font-bold text-foreground"><span className="text-gradient-primary">Contact</span> Us</span>
        </button>
        <ThemeToggle />
      </nav>

      <div className="container mx-auto grid max-w-4xl gap-6 px-4 py-10 md:grid-cols-[1fr_1.2fr]">
        <aside className="space-y-3">
          <h1 className="text-2xl font-bold text-foreground">Get in touch</h1>
          <p className="text-sm text-muted-foreground">
            Questions, feedback, or partnership ideas? We'd love to hear from you.
          </p>
          <a href="mailto:team@aihealthbot.dev" className="flex items-center gap-3 rounded-xl border border-border bg-card p-3 text-sm hover:bg-muted/50">
            <Mail className="h-4 w-4 text-primary" /> team@aihealthbot.dev
          </a>
          <a href="https://github.com" target="_blank" rel="noreferrer" className="flex items-center gap-3 rounded-xl border border-border bg-card p-3 text-sm hover:bg-muted/50">
            <Github className="h-4 w-4 text-primary" /> github.com/ai-healthbot
          </a>
          <a href="https://linkedin.com" target="_blank" rel="noreferrer" className="flex items-center gap-3 rounded-xl border border-border bg-card p-3 text-sm hover:bg-muted/50">
            <Linkedin className="h-4 w-4 text-primary" /> AI HealthBot on LinkedIn
          </a>
        </aside>

        <form onSubmit={submit} className="space-y-3 rounded-2xl border border-border bg-card p-6 shadow-sm">
          <h2 className="text-base font-semibold text-foreground">Send feedback</h2>
          <input
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            placeholder="Your name"
            className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm focus:border-primary focus:outline-none"
          />
          <input
            type="email"
            value={form.email}
            onChange={(e) => setForm({ ...form, email: e.target.value })}
            placeholder="you@example.com"
            className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm focus:border-primary focus:outline-none"
          />
          <textarea
            value={form.message}
            onChange={(e) => setForm({ ...form, message: e.target.value })}
            placeholder="How can we help?"
            rows={5}
            className="w-full resize-none rounded-lg border border-border bg-background px-3 py-2 text-sm focus:border-primary focus:outline-none"
          />
          <button
            type="submit"
            disabled={sending}
            className="flex items-center gap-2 rounded-xl bg-primary px-5 py-2.5 text-sm font-semibold text-primary-foreground shadow-lg disabled:opacity-50"
          >
            {sending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
            Send message
          </button>
        </form>
      </div>
    </div>
  );
};

export default Contact;
