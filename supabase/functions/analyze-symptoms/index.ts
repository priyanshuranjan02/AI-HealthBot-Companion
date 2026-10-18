import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const LANG_NAMES: Record<string, string> = {
  en: "English",
  hi: "Hindi",
  es: "Spanish",
  fr: "French",
  ar: "Arabic",
  zh: "Chinese",
  pt: "Portuguese",
  bn: "Bengali",
};

const EMERGENCY_PATTERNS = [
  // Chest pain and breathing difficulties
  /\b(chest pain|chest pressure|difficulty breathing|trouble breathing|shortness of breath|can't breathe|cannot breathe|not breathing)\b/i,

  // Possible stroke symptoms
  /\b(face drooping|facial droop|slurred speech|difficulty speaking|weakness on one side|sudden loss of vision)\b/i,

  // Other potentially life-threatening symptoms
  /\b(severe bleeding|bleeding won't stop|bleeding will not stop|unconscious|not waking up|seizure|throat swelling|tongue swelling|severe allergic reaction)\b/i,

  // Common Hindi phrases
  /सीने में दर्द|सीने में दबाव|सांस लेने में दिक्कत|साँस लेने में दिक्कत|सांस नहीं ले पा रहा|बेहोश|खून बहना बंद नहीं|चेहरा टेढ़ा|बोलने में दिक्कत|एक तरफ कमजोरी|गले में सूजन|जीभ में सूजन/,
];

function hasEmergencyIndicators(text: string): boolean {
  return EMERGENCY_PATTERNS.some((pattern) => pattern.test(text));
}

function emergencyGuidance(language: string): string {
  if (language === "hi") {
    return [
      "## संभावित चिकित्सा आपातस्थिति",
      "",
      "आपके बताए लक्षणों के लिए तुरंत चिकित्सा सहायता की आवश्यकता हो सकती है।",
      "",
      "- अभी अपनी स्थानीय आपातकालीन सेवा से संपर्क करें या नजदीकी आपातकालीन विभाग में जाएँ।",
      "- यदि संभव हो, तो किसी व्यक्ति से आपके साथ रहने और सहायता लेने के लिए कहें।",
      "- ऑनलाइन AI प्रतिक्रिया की प्रतीक्षा न करें।",
      "",
      "**अस्वीकरण:** यह AI प्रणाली चिकित्सा निदान नहीं कर सकती।",
    ].join("\n");
  }

  return [
    "## Possible Medical Emergency",
    "",
    "The symptoms you mentioned may require immediate medical attention.",
    "",
    "- Contact your local emergency services now or go to the nearest emergency department.",
    "- If possible, ask someone to stay with you and help you obtain care.",
    "- Do not wait for an online AI response if you may be experiencing an emergency.",
    "",
    "**Disclaimer:** This AI system cannot provide a medical diagnosis.",
  ].join("\n");
}

function createEmergencyStream(message: string): Response {
  // Match the streaming format expected by the existing chat client.
  const streamBody =
    `data: ${JSON.stringify({
      choices: [{ delta: { content: message } }],
    })}\n\n` +
    "data: [DONE]\n\n";

  return new Response(streamBody, {
    status: 200,
    headers: {
      ...corsHeaders,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
    },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), {
        status: 405,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          Allow: "POST, OPTIONS",
        },
      });
    }

    const body = await req.json();
    const messages = body?.messages;
    const requestedLanguage = body?.language ?? "en";

    if (
      !Array.isArray(messages) ||
      messages.length === 0 ||
      messages.length > 30 ||
      !["en", "hi"].includes(requestedLanguage) ||
      messages.some(
        (message: unknown) =>
          typeof message !== "object" ||
          message === null ||
          !("role" in message) ||
          !("content" in message) ||
          !["user", "assistant"].includes(
            (message as { role: string }).role
          ) ||
          typeof (message as { content: unknown }).content !== "string" ||
          ((message as { content: string }).content.length > 8000)
      )
    ) {
      return new Response(JSON.stringify({ error: "Invalid request" }), {
        status: 400,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      });
    }

    const language: string = requestedLanguage;
    const latestUserMessage = [...messages]
      .reverse()
      .find((message: { role: string }) => message.role === "user");

    if (!latestUserMessage) {
      return new Response(JSON.stringify({ error: "A user message is required" }), {
        status: 400,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      });
    }

    if (hasEmergencyIndicators(latestUserMessage.content)) {
      return createEmergencyStream(emergencyGuidance(language));
    }

    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) throw new Error("LOVABLE_API_KEY not configured");

    const langName = LANG_NAMES[language] || "English";

    const systemPrompt = `You are an experienced AI Health Assistant. Analyze the user's symptoms carefully and empathetically.

ALWAYS respond ONLY in ${langName}.

Format your reply as clean, well-structured GitHub-Flavored Markdown using the EXACT section headings below. Each section header MUST be on its own line as bold text, followed by content on new lines. Use bullet lists where appropriate. Add a blank line between sections.

**Possible Condition:** <short name>

**Severity:** <low | moderate | high>

**Confidence:** <0-100>%

**Summary**
A short 1-2 sentence empathetic explanation of what may be happening.

**Symptoms Identified**
- symptom one
- symptom two

**Possible Causes**
- cause one
- cause two

**Recommendations**
- actionable recommendation one
- actionable recommendation two
- actionable recommendation three

**When to See a Doctor**
- warning sign one
- warning sign two

**Self-Care Tips**
- tip one
- tip two

---

**Disclaimer:** This is not a medical diagnosis. Please consult a qualified healthcare professional for proper evaluation.

Rules:
- Always include EVERY section above, each on its own line with a blank line between sections — never put multiple sections on the same line.
- If symptoms suggest emergency (chest pain, stroke signs, severe bleeding, breathing difficulty), set Severity: high and urge immediate emergency care in the Recommendations.
- Be empathetic, clear, and concise.
- Ask follow-up questions only if symptoms are too vague to assess.`;

    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-pro",
        messages: [{ role: "system", content: systemPrompt }, ...messages],
        stream: true,
      }),
    });

    if (!response.ok) {
      if (response.status === 429) {
        return new Response(JSON.stringify({ error: "Rate limit exceeded, please try again later." }), {
          status: 429,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (response.status === 402) {
        return new Response(JSON.stringify({ error: "AI credits exhausted. Please add funds in Lovable workspace." }), {
          status: 402,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const t = await response.text();
      console.error("AI gateway error:", response.status, t);
      return new Response(JSON.stringify({ error: "AI gateway error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(response.body, {
      headers: { ...corsHeaders, "Content-Type": "text/event-stream" },
    });
  } catch (e) {
    console.error("analyze-symptoms error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : "Unknown error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
