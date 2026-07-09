import { useState, useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { BarChart3, LogIn, LogOut, User } from "lucide-react";
import HeroSection from "@/components/HeroSection";
import CategoryCards from "@/components/CategoryCards";
import ChatInterface from "@/components/ChatInterface";
import EmergencyModal from "@/components/EmergencyModal";
import LanguageToggle from "@/components/LanguageToggle";
import ThemeToggle from "@/components/ThemeToggle";
import SiteFooter from "@/components/SiteFooter";
import { translations, type Language } from "@/lib/i18n";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";

const Index = () => {
  const [language, setLanguage] = useState<Language>("en");
  const [view, setView] = useState<"home" | "chat">("home");
  const [showEmergency, setShowEmergency] = useState(false);
  const [user, setUser] = useState<any>(null);
  const navigate = useNavigate();

  const t = translations[language];

  useEffect(() => {
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setUser(session?.user ?? null);
    });
    supabase.auth.getSession().then(({ data: { session } }) => {
      setUser(session?.user ?? null);
    });
    return () => subscription.unsubscribe();
  }, []);

  const handleLogout = async () => {
    await supabase.auth.signOut();
    toast.success("Logged out");
  };

  if (view === "chat") {
    return (
      <>
        <ChatInterface t={t} language={language} onBack={() => setView("home")} onEmergency={() => setShowEmergency(true)} />
        {showEmergency && <EmergencyModal t={t} onClose={() => setShowEmergency(false)} />}
      </>
    );
  }

  return (
    <div className="min-h-screen bg-background">
      <nav className="sticky top-0 z-20 flex items-center justify-between border-b border-border bg-card/80 px-4 py-3 backdrop-blur-md sm:px-6">
        <span className="text-lg font-bold text-foreground">
          <span className="text-gradient-primary">AI</span> HealthBot
        </span>
        <div className="flex items-center gap-2">
          <button
            onClick={() => navigate("/dashboard")}
            className="flex h-9 items-center gap-1.5 rounded-full border border-border bg-card px-3 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground"
          >
            <BarChart3 className="h-3.5 w-3.5" />
            <span className="hidden sm:inline">Dashboard</span>
          </button>
          {user ? (
            <>
              <button
                onClick={() => navigate("/profile")}
                className="flex h-9 items-center gap-1.5 rounded-full border border-border bg-card px-3 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground"
              >
                <User className="h-3.5 w-3.5" />
                <span className="hidden sm:inline">Profile</span>
              </button>
              <button
                onClick={handleLogout}
                className="flex h-9 items-center gap-1.5 rounded-full border border-border bg-card px-3 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground"
              >
                <LogOut className="h-3.5 w-3.5" />
                <span className="hidden sm:inline">Logout</span>
              </button>
            </>
          ) : (
            <button
              onClick={() => navigate("/auth")}
              className="flex h-9 items-center gap-1.5 rounded-full border border-primary/30 bg-primary/5 px-3 text-xs font-medium text-primary transition-colors hover:bg-primary/10"
            >
              <LogIn className="h-3.5 w-3.5" />
              <span className="hidden sm:inline">Login</span>
            </button>
          )}
          <LanguageToggle language={language} onToggle={setLanguage} />
          <ThemeToggle />
        </div>
      </nav>

      <HeroSection t={t} onStartCheck={() => setView("chat")} onEmergency={() => setShowEmergency(true)} />
      <CategoryCards t={t} onSelect={() => setView("chat")} />

      <SiteFooter />

      {showEmergency && <EmergencyModal t={t} onClose={() => setShowEmergency(false)} />}
    </div>
  );
};

export default Index;
