export const MINIMUM_ANALYTICS_COHORT = 10;

export type AssessmentForAnalytics = {
  createdAt: string;
  severity: "low" | "moderate" | "high";
  diagnosis: string;
  language: string;
  symptoms: string[];
  confidence: number;
};

type Count = { name: string; count: number };

export type PrivacySafeAnalytics = {
  totalChecks: number | null;
  totalUsers: number | null;
  severityCounts: Record<"low" | "moderate" | "high", number | null>;
  topDiagnoses: Count[];
  dailyChecks: { date: string; count: number }[];
  monthlyAssessments: { month: string; count: number }[];
  predictionTrend: { date: string; low: number | null; moderate: number | null; high: number | null }[];
  languageDistribution: Record<string, number>;
  languageBreakdown: Count[];
  topSymptoms: Count[];
  avgConfidence: number | null;
  highRiskCases: number | null;
  privacySuppressed: boolean;
  minimumCohort: number;
  suppressedBreakdowns: string[];
};

/**
 * Fail-closed response while raw assessment rows remain caller-controlled.
 * Input rows are intentionally ignored: threshold suppression alone cannot
 * prevent a dashboard consumer from adding records to cross a threshold.
 */
export const buildPrivacySafeAnalytics = (
  _assessments: AssessmentForAnalytics[],
): PrivacySafeAnalytics => {
  void _assessments;
  return {
    totalChecks: null,
    totalUsers: null,
    severityCounts: { low: null, moderate: null, high: null },
    topDiagnoses: [],
    dailyChecks: [],
    monthlyAssessments: [],
    predictionTrend: [],
    languageDistribution: {},
    languageBreakdown: [],
    topSymptoms: [],
    avgConfidence: null,
    highRiskCases: null,
    privacySuppressed: true,
    minimumCohort: MINIMUM_ANALYTICS_COHORT,
    suppressedBreakdowns: ["all"],
  };
};

export const isBreakdownSuppressed = (
  suppressedBreakdowns: readonly string[] | undefined,
  breakdown: string,
) => suppressedBreakdowns?.includes("all") || suppressedBreakdowns?.includes(breakdown) || false;

export const currentMonthMetric = (
  monthlyAssessments: readonly { month: string; count: number }[],
  suppressedBreakdowns: readonly string[] | undefined,
  currentMonth: string,
): number | null => {
  if (isBreakdownSuppressed(suppressedBreakdowns, "monthlyAssessments")) return null;
  return monthlyAssessments.find(({ month }) => month === currentMonth)?.count ?? null;
};

export const metricDisplay = (value: number | null) => value === null ? "Suppressed" : value;
