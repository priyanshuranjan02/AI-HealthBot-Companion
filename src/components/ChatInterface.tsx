import { useState, useRef, useEffect } from "react";
import { Send, ArrowLeft, Loader2 } from "lucide-react";
import { toast } from "sonner";
import MessageBubble from "./MessageBubble";
import { supabase } from "@/integrations/supabase/client";
import { parseDiagnosis, type ParsedDiagnosis } from "@/lib/parseDiagnosis";

interface Message {
  id: number;
  role: "user" | "ai";
  text: string;
}

interface ChatInterfaceProps {
  t: Record<string, string>;
  language: string;
  onBack: () => void;
  onEmergency: () => void;
}

const quickSymptoms = ["fever", "headache", "cough"];
const CHAT_URL = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/analyze-symptoms`;


const ChatInterface = ({ t, language, onBack, onEmergency }: ChatInterfaceProps) => {
  const [messages, setMessages] = useState<Message[]>([
    { id: 1, role: "ai", text: "Hello! I'm your AI Health Assistant. Please describe your symptoms and I'll help assess your condition." },
  ]);
  const [input, setInput] = useState("");
  const [isTyping, setIsTyping] = useState(false);
  const [step, setStep] = useState(1);
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, isTyping]);


  const saveToDb = async (assessment: ParsedDiagnosis): Promise<boolean> => {
    try {
      const {
        data: { user },
        error: authError,
      } = await supabase.auth.getUser();

      if (authError) throw authError;

      const { error: insertError } = await supabase
        .from("symptom_checks")
        .insert({
          user_id: user?.id ?? null,
          symptoms: assessment.symptoms,
          diagnosis: assessment.disease,
          confidence: assessment.confidence,
          severity: assessment.severity,
          recommendations: assessment.recommendations,
          language: assessment.language,
        });

      if (insertError) throw insertError;

      return true;
    } catch (err) {
      console.error("Failed to save symptom check:", err);
      return false;
    }
  };


  const handleSend = async (text?: string) => {
    const msg = text || input.trim();
    if (!msg || isTyping) return;

    const userMsg: Message = { id: Date.now(), role: "user", text: msg };
    const history = [...messages, userMsg];
    setMessages(history);
    setInput("");
    setIsTyping(true);
    setStep(2);

    const aiId = Date.now() + 1;
    setMessages((prev) => [...prev, { id: aiId, role: "ai", text: "" }]);

    try {
      const resp = await fetch(CHAT_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}`,
        },
        body: JSON.stringify({
          language,
          messages: history.map((m) => ({
            role: m.role === "ai" ? "assistant" : "user",
            content: m.text,
          })),
        }),
      });

      if (!resp.ok || !resp.body) {
        if (resp.status === 429) toast.error("Rate limit exceeded. Try again shortly.");
        else if (resp.status === 402) toast.error("AI credits exhausted. Add credits in Lovable workspace.");
        else toast.error("Failed to analyze symptoms.");
        setMessages((prev) => prev.filter((m) => m.id !== aiId));
        setIsTyping(false);
        setStep(1);
        return;
      }

      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let acc = "";
      let done = false;

      while (!done) {
        const { value, done: d } = await reader.read();
        if (d) break;
        buffer += decoder.decode(value, { stream: true });
        let nl: number;
        while ((nl = buffer.indexOf("\n")) !== -1) {
          let line = buffer.slice(0, nl);
          buffer = buffer.slice(nl + 1);
          if (line.endsWith("\r")) line = line.slice(0, -1);
          if (!line.startsWith("data: ")) continue;
          const json = line.slice(6).trim();
          if (json === "[DONE]") { done = true; break; }
          try {
            const parsed = JSON.parse(json);
            const content = parsed.choices?.[0]?.delta?.content;
            if (content) {
              acc += content;
              setMessages((prev) =>
                prev.map((m) => (m.id === aiId ? { ...m, text: acc } : m))
              );
            }
          } catch {
            buffer = line + "\n" + buffer;
            break;
          }
        }
      }

      setStep(3);

      if (acc.trim()) {
        const assessment = parseDiagnosis(acc, msg, language);

        const assessmentMarkers = [
          "**Possible Condition:**",
          "**Severity:**",
          "**Confidence:**",
        ];

        const looksLikeAssessment = assessmentMarkers.some((marker) =>
          acc.includes(marker)
        );

        if (looksLikeAssessment && !assessment) {
          setMessages((prev) =>
            prev.map((message) =>
              message.id === aiId
                ? {
                    ...message,
                    text:
                      "I couldn't validate this assessment. Please try again. " +
                      "If your symptoms are severe or you may be experiencing an " +
                      "emergency, seek urgent medical care rather than waiting " +
                      "for another AI response.",
                  }
                : message
            )
          );
        } else if (assessment) {
          const saved = await saveToDb(assessment);

          if (!saved) {
            toast.error(
              "Assessment completed, but it could not be saved to your history."
            );
          }
        }
      }
    } catch (err: unknown) {
      console.error(err);

      const errorMessage =
        err instanceof Error
          ? err.message
          : "Failed to analyze symptoms.";

      toast.error(errorMessage);
      setMessages((prev) => prev.filter((m) => m.id !== aiId));
      setStep(1);
    } finally {
      setIsTyping(false);
    }
  };

  return (
    <div className="flex min-h-screen flex-col bg-background">
      <header className="sticky top-0 z-10 flex items-center justify-between border-b border-border bg-card/80 px-4 py-3 backdrop-blur-md">
        <button onClick={onBack} className="flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors">
          <ArrowLeft className="h-4 w-4" />
          {t.title}
        </button>
        <div className="flex items-center gap-2 text-xs font-medium">
          {[1, 2, 3].map((s) => (
            <div key={s} className="flex items-center gap-1">
              <div className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold transition-colors ${
                step >= s ? "bg-primary text-primary-foreground" : "bg-muted text-muted-foreground"
              }`}>
                {s}
              </div>
              <span className="hidden sm:inline text-muted-foreground">
                {s === 1 ? t.step1 : s === 2 ? t.step2 : t.step3}
              </span>
              {s < 3 && <div className={`h-px w-4 ${step > s ? "bg-primary" : "bg-border"}`} />}
            </div>
          ))}
        </div>
        <button onClick={onEmergency} className="rounded-full bg-critical/10 px-3 py-1.5 text-xs font-semibold text-critical hover:bg-critical hover:text-critical-foreground transition-colors">
          🚨 SOS
        </button>
      </header>

      <div className="flex-1 overflow-y-auto px-4 py-6">
        <div className="mx-auto max-w-2xl space-y-4">
          {messages.map((msg) => (
            <MessageBubble key={msg.id} role={msg.role} text={msg.text || (isTyping && msg.role === "ai" ? "…" : "")} />
          ))}
          {isTyping && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 className="h-4 w-4 animate-spin text-primary" />
              {t.analyzing}
            </div>
          )}
          <div ref={bottomRef} />
        </div>
      </div>

      <div className="border-t border-border bg-card/50 px-4 py-2">
        <div className="mx-auto flex max-w-2xl gap-2 overflow-x-auto">
          {quickSymptoms.map((sym) => (
            <button
              key={sym}
              onClick={() => handleSend(t[sym])}
              disabled={isTyping}
              className="shrink-0 rounded-full border border-border bg-card px-4 py-2 text-sm font-medium text-foreground transition-colors hover:border-primary hover:text-primary disabled:opacity-50"
            >
              {t[sym]}
            </button>
          ))}
          <button
            onClick={() => handleSend("I have fever, fatigue, and body ache for 2 days")}
            disabled={isTyping}
            className="shrink-0 rounded-full border border-primary/30 bg-primary/5 px-4 py-2 text-sm font-semibold text-primary transition-colors hover:bg-primary/10 disabled:opacity-50"
          >
            🎯 {t.tryDemo}
          </button>
        </div>
      </div>

      <div className="border-t border-border bg-card px-4 py-4">
        <div className="mx-auto flex max-w-2xl gap-3">
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && handleSend()}
            placeholder={t.chatPlaceholder}
            disabled={isTyping}
            className="flex-1 rounded-2xl border border-border bg-muted/50 px-5 py-3 text-base text-foreground placeholder:text-muted-foreground focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20 transition-all disabled:opacity-50"
          />
          <button
            onClick={() => handleSend()}
            disabled={!input.trim() || isTyping}
            className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-primary text-primary-foreground shadow-lg shadow-primary/20 transition-all hover:shadow-xl disabled:opacity-40 disabled:shadow-none"
          >
            {isTyping ? <Loader2 className="h-5 w-5 animate-spin" /> : <Send className="h-5 w-5" />}
          </button>
        </div>
      </div>
    </div>
  );
};

export default ChatInterface;
