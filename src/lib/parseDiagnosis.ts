export type ParsedDiagnosis = {
  disease: string;
  severity: "low" | "moderate" | "high";
  confidence: number;
  recommendations: string[];
  symptoms: string[];
  language: string;
};

export function parseDiagnosis(
  text: string,
  userInput: string,
  language: string
): ParsedDiagnosis | null {
  const getField = (label: string): string | null => {
    const escapedLabel = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const pattern = new RegExp(
      `\\*\\*${escapedLabel}:\\*\\*\\s*([^\\n*]+)`,
      "i"
    );

    return pattern.exec(text)?.[1]?.trim() ?? null;
  };

  const assessmentFields = [
    "Possible Condition",
    "Severity",
    "Confidence",
  ];

  const looksLikeAssessment = assessmentFields.some((field) =>
    text.includes(`**${field}:**`)
  );

  if (!looksLikeAssessment) {
    return null;
  }

  const disease = getField("Possible Condition");
  const severityRaw = getField("Severity")?.toLowerCase();
  const confidenceRaw = getField("Confidence");

  if (
    !disease ||
    !severityRaw ||
    !confidenceRaw ||
    !/\*\*Recommendations:?\*\*/i.test(text) ||
    !text.includes("**Disclaimer:**")
  ) {
    return null;
  }

  if (!["low", "moderate", "high"].includes(severityRaw)) {
    return null;
  }

  const confidenceMatch = confidenceRaw.match(/^(\d{1,3})\s*%?$/);

  if (!confidenceMatch) {
    return null;
  }

  const confidence = Number(confidenceMatch[1]);

  if (!Number.isInteger(confidence) || confidence < 0 || confidence > 100) {
    return null;
  }

  const recBlock =
    /\*\*Recommendations:?\*\*([\s\S]*?)(?=\n\*\*|$)/i.exec(text)?.[1] ?? "";

  const recommendations = recBlock
    .split("\n")
    .map((line) => line.replace(/^[-*]\s*/, "").trim())
    .filter(Boolean);

  if (recommendations.length === 0) {
    return null;
  }

  return {
    disease,
    severity: severityRaw as ParsedDiagnosis["severity"],
    confidence,
    recommendations,
    symptoms: [userInput],
    language,
  };
}