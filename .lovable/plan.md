# Dashboard privacy gate: fail closed unless explicitly unsuppressed

## Findings (read-only)

- Current branch in this session: `edit/edt-50e72dc4-...` (a Lovable edit branch). Remotes are Lovable-internal storage only; no GitHub remote is visible from the sandbox.
- GitHub target, synced branch and whether sync is on are **not verifiable from here**. The agent cannot see the Git connection; check Project settings -> Git. If connected, Lovable pushes to the synced branch (default branch unless changed) automatically.
- Vercel wiring is **not verifiable from here**. `vercel.json` has only an SPA rewrite, with no branch or deploy settings. The production branch is set in Vercel (Settings -> Git -> Production Branch). It matches Lovable only if it is the same branch Lovable syncs to.

## Current gate

`src/pages/Dashboard.tsx` line 113:
```tsx
) : !data || data.privacySuppressed || data.totalChecks === 0 ? (
```
If `privacySuppressed` is missing, `undefined`, `null` or `"false"`, it counts as falsy, so the charts render. That means the dashboard fails open.

## Proposed patch (smallest)

1. `src/lib/dashboardPrivacy.ts`: add
```ts
export const canRenderAnalytics = (data: unknown): boolean =>
  typeof data === "object" && data !== null &&
  (data as { privacySuppressed?: unknown }).privacySuppressed === false &&
  typeof (data as { totalChecks?: unknown }).totalChecks === "number" &&
  (data as { totalChecks: number }).totalChecks > 0;
```
2. `src/pages/Dashboard.tsx` line 113: replace the condition with
```tsx
) : !canRenderAnalytics(data) ? (
```
and import `canRenderAnalytics` from `@/lib/dashboardPrivacy`.

## Regression test

Add to `src/test/dashboardPrivacy.test.ts`. It already covers this module's fail-closed behaviour. Add one `describe("canRenderAnalytics")` with these cases:
- returns false when the field is missing, `undefined`, `null`, `true` or `"false"`, and when `data` is null
- returns false when `totalChecks` is 0, null or missing
- returns true only for `{ privacySuppressed: false, totalChecks: 12 }`

## Not done

No edits, commits, pushes, deploys or settings changes.
