
import { describe, expect, it } from "vitest";
import { parseDiagnosis } from "@/lib/parseDiagnosis";

const validResponse = `
**Possible Condition:** Common cold
**Severity:** low
**Confidence:** 65%

**Recommendations**
- Rest and drink fluids.
- Monitor your symptoms.

**Disclaimer:** This is informational guidance, not a medical diagnosis.
`;

describe("parseDiagnosis", () => {
  it("accepts a complete valid assessment", () => {
    const result = parseDiagnosis(
      validResponse,
      "I have a cough and runny nose",
      "en"
    );

    expect(result).not.toBeNull();
    expect(result).toMatchObject({
      disease: "Common cold",
      severity: "low",
      confidence: 65,
      recommendations: [
        "Rest and drink fluids.",
        "Monitor your symptoms.",
      ],
      symptoms: ["I have a cough and runny nose"],
      language: "en",
    });
  });

  it("rejects an assessment missing severity", () => {
    const response = validResponse.replace(
      "**Severity:** low\n",
      ""
    );

    expect(
      parseDiagnosis(response, "I feel unwell", "en")
    ).toBeNull();
  });

  it("rejects an assessment missing confidence", () => {
    const response = validResponse.replace(
      "**Confidence:** 65%\n",
      ""
    );

    expect(
      parseDiagnosis(response, "I feel unwell", "en")
    ).toBeNull();
  });

  it("rejects confidence above 100", () => {
    const response = validResponse.replace("65%", "150%");

    expect(
      parseDiagnosis(response, "I feel unwell", "en")
    ).toBeNull();
  });

  it("rejects a non-numeric confidence value", () => {
    const response = validResponse.replace("65%", "high");

    expect(
      parseDiagnosis(response, "I feel unwell", "en")
    ).toBeNull();
  });

  it("rejects an invalid severity", () => {
    const response = validResponse.replace(
      "**Severity:** low",
      "**Severity:** critical"
    );

    expect(
      parseDiagnosis(response, "I feel unwell", "en")
    ).toBeNull();
  });

  it("rejects an assessment without recommendations", () => {
    const response = validResponse.replace(
      "- Rest and drink fluids.\n- Monitor your symptoms.",
      ""
    );

    expect(
      parseDiagnosis(response, "I feel unwell", "en")
    ).toBeNull();
  });

  it("rejects an assessment missing the disclaimer", () => {
    const response = validResponse.replace(
      "**Disclaimer:** This is informational guidance, not a medical diagnosis.",
      ""
    );

    expect(
      parseDiagnosis(response, "I feel unwell", "en")
    ).toBeNull();
  });

  it("does not treat a follow-up question as an assessment", () => {
    const response =
      "How long have you had these symptoms? Do you have a fever?";

    expect(
      parseDiagnosis(response, "I have a headache", "en")
    ).toBeNull();
  });
});

it("accepts recommendations heading with a colon", () => {
  const response = validResponse.replace(
    "**Recommendations**",
    "**Recommendations:**"
  );

  expect(
    parseDiagnosis(response, "I have a cough", "en")
  ).not.toBeNull();
});