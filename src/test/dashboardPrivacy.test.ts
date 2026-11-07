import { describe, expect, it } from "vitest";
import {
  buildPrivacySafeAnalytics,
  canRenderAnalytics,
  currentMonthMetric,
  metricDisplay,
  type AssessmentForAnalytics,
} from "@/lib/dashboardPrivacy";

const assessments = (
  rows: Array<Partial<AssessmentForAnalytics>>,
): AssessmentForAnalytics[] => rows.map((row, index) => ({
  createdAt: row.createdAt ?? "2026-10-18T12:00:00.000Z",
  severity: row.severity ?? "low",
  diagnosis: row.diagnosis ?? "Condition A",
  language: row.language ?? "en",
  symptoms: row.symptoms ?? ["cough"],
  confidence: row.confidence ?? 80 + (index % 2),
}));

const repeated = (count: number, row: Partial<AssessmentForAnalytics> = {}) =>
  Array.from({ length: count }, () => row);

describe("privacy-safe health analytics", () => {
  it.each([
    undefined,
    null,
    false,
    [],
    {},
    { totalChecks: 1 },
    { privacySuppressed: true, totalChecks: 10 },
    { privacySuppressed: "false", totalChecks: 10 },
    { privacySuppressed: false, totalChecks: null },
    { privacySuppressed: false, totalChecks: "10" },
    { privacySuppressed: false, totalChecks: 0 },
    { privacySuppressed: false, totalChecks: -1 },
    { privacySuppressed: false, totalChecks: Number.NaN },
    { privacySuppressed: false, totalChecks: Number.POSITIVE_INFINITY },
    { privacySuppressed: false, totalChecks: Number.NEGATIVE_INFINITY },
  ])("keeps malformed or suppressed analytics hidden (%s)", (value) => {
    expect(canRenderAnalytics(value)).toBe(false);
  });

  it("renders only an explicitly unsuppressed positive finite total", () => {
    expect(canRenderAnalytics({ privacySuppressed: false, totalChecks: 1 })).toBe(true);
    expect(canRenderAnalytics({ privacySuppressed: false, totalChecks: 10 })).toBe(true);
  });

  const expectFailClosed = (rows: AssessmentForAnalytics[]) => {
    const result = buildPrivacySafeAnalytics(rows);

    expect(result.privacySuppressed).toBe(true);
    expect(result.totalChecks).toBeNull();
    expect(result.totalUsers).toBeNull();
    expect(result.severityCounts).toEqual({ low: null, moderate: null, high: null });
    expect(result.topDiagnoses).toEqual([]);
    expect(result.dailyChecks).toEqual([]);
    expect(result.monthlyAssessments).toEqual([]);
    expect(result.predictionTrend).toEqual([]);
    expect(result.languageDistribution).toEqual({});
    expect(result.languageBreakdown).toEqual([]);
    expect(result.topSymptoms).toEqual([]);
    expect(result.avgConfidence).toBeNull();
    expect(result.highRiskCases).toBeNull();
    expect(result.suppressedBreakdowns).toEqual(["all"]);
  };

  it.each([9, 10, 21])("suppresses the complete response for a cohort of %i", (size) => {
    expectFailClosed(assessments(repeated(size)));
  });

  it("does not release a category when a caller attempts to add its tenth assessment", () => {
    const nine = assessments(repeated(9, { diagnosis: "Rare condition", severity: "high" }));
    const callerControlledTenth = assessments([
      ...repeated(9, { diagnosis: "Rare condition", severity: "high" }),
      { diagnosis: "Rare condition", severity: "high" },
    ]);

    expectFailClosed(nine);
    expectFailClosed(callerControlledTenth);
    expect(buildPrivacySafeAnalytics(nine)).toEqual(buildPrivacySafeAnalytics(callerControlledTenth));
  });

  it("withholds overlapping daily and monthly outputs whose difference could be five", () => {
    const rows = assessments([
      ...repeated(5, { createdAt: "2026-10-01T08:00:00.000Z" }),
      ...repeated(10, { createdAt: "2026-10-01T13:00:00.000Z" }),
      ...repeated(10, { createdAt: "2026-10-02T13:00:00.000Z" }),
      ...repeated(10, { createdAt: "2026-10-03T13:00:00.000Z" }),
      ...repeated(10, { createdAt: "2026-10-04T13:00:00.000Z" }),
      ...repeated(10, { createdAt: "2026-10-05T13:00:00.000Z" }),
      ...repeated(10, { createdAt: "2026-10-06T13:00:00.000Z" }),
      ...repeated(10, { createdAt: "2026-10-07T13:00:00.000Z" }),
    ]);

    const fullMonthTotal = rows.length;
    const recentDailyTotal = rows.filter(({ createdAt }) =>
      createdAt >= "2026-10-01T12:00:00.000Z",
    ).length;
    expect(fullMonthTotal - recentDailyTotal).toBe(5);
    expectFailClosed(rows);
  });

  it("suppresses empty data and records with missing categories", () => {
    expectFailClosed([]);
    expectFailClosed(assessments(repeated(21, {
      diagnosis: "",
      symptoms: [],
      language: "",
    })));
  });

  it("never formats a suppressed metric as zero or labels a prior month as this month", () => {
    expect(metricDisplay(null)).toBe("Suppressed");
    expect(currentMonthMetric([{ month: "2026-09", count: 18 }], [], "2026-10")).toBeNull();
    expect(currentMonthMetric([{ month: "2026-10", count: 18 }], [], "2026-10")).toBe(18);
    expect(currentMonthMetric([{ month: "2026-10", count: 18 }], ["monthlyAssessments"], "2026-10")).toBeNull();
  });
});
