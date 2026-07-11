import { Link } from "react-router-dom";
import { Github, Linkedin, Mail, Heart } from "lucide-react";

const SiteFooter = () => (
  <footer className="border-t border-border bg-card">
    <div className="container mx-auto grid gap-8 px-4 py-10 sm:grid-cols-2 md:grid-cols-4">
      <div>
        <h3 className="text-base font-bold text-foreground">
          <span className="text-gradient-primary">AI</span> HealthBot
        </h3>
        <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
          Multilingual AI symptom assessment for rural healthcare.
        </p>
      </div>
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Product</h4>
        <ul className="space-y-1.5 text-sm">
          <li><Link to="/" className="text-foreground/80 hover:text-primary">Home</Link></li>
          <li><Link to="/dashboard" className="text-foreground/80 hover:text-primary">NGO Dashboard</Link></li>
          <li><Link to="/profile" className="text-foreground/80 hover:text-primary">My Account</Link></li>
        </ul>
      </div>
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Company</h4>
        <ul className="space-y-1.5 text-sm">
          <li><Link to="/about" className="text-foreground/80 hover:text-primary">About</Link></li>
          <li><Link to="/contact" className="text-foreground/80 hover:text-primary">Contact</Link></li>
          <li><Link to="/privacy" className="text-foreground/80 hover:text-primary">Privacy & Terms</Link></li>
          <li><Link to="/privacy" className="text-foreground/80 hover:text-primary">Medical Disclaimer</Link></li>
        </ul>
      </div>
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground">Connect</h4>
        <div className="flex gap-2">
          <a href="https://github.com/priyanshuranjan02" target="_blank" rel="noreferrer" aria-label="GitHub" className="flex h-9 w-9 items-center justify-center rounded-full border border-border hover:border-primary hover:text-primary">
            <Github className="h-4 w-4" />
          </a>
          <a href="https://www.linkedin.com/in/priyanshu-ranjan-74170a227/" target="_blank" rel="noreferrer" aria-label="LinkedIn" className="flex h-9 w-9 items-center justify-center rounded-full border border-border hover:border-primary hover:text-primary">
            <Linkedin className="h-4 w-4" />
          </a>
          <a href="mailto:ranjanpriyanshu441@gmail.com" aria-label="Email" className="flex h-9 w-9 items-center justify-center rounded-full border border-border hover:border-primary hover:text-primary">
            <Mail className="h-4 w-4" />
          </a>
        </div>
      </div>
    </div>
    <div className="border-t border-border py-4 text-center text-xs text-muted-foreground">
      © 2026 AI HealthBot · Built with <Heart className="inline h-3 w-3 text-critical" /> by Team for accessible healthcare.
    </div>
  </footer>
);

export default SiteFooter;
