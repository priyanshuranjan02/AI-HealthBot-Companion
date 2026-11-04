# Auth URL Configuration — read-only findings (no changes made)

## Verified identity
- Lovable Cloud backend ref: `nbqphskrnstcmudvhzie`, environment `prod` (one instance serves Lovable preview and published app).
- The live Vercel site (https://ai-health-bot-companion.vercel.app, HTTP 200) ships a JS bundle pointing to `nbqphskrnstcmudvhzie.supabase.co`. So the Vercel app uses the same backend as this Lovable project.

## Current settings (read directly)
- Site URL: `https://id-preview--cc7a15fd-139e-4990-88aa-59a17264f910.lovable.app` (Lovable preview, not Vercel).
- Redirect allowlist: only Lovable-hosted addresses (preview, project, lovableproject.com, `health-kind-ai.lovable.app`). No `ai-health-bot-companion.vercel.app` entry.
- Impact: recovery links redirecting to `.../admin/login?recovery=1` and `.../auth?recovery=1` will be rejected and fall back to the Site URL (Lovable preview).

## Can it be changed through this integration?
- Redirect URLs: no agent tool edits them. Owner action required.
- Site URL: no supported agent tool sets it to a custom external value. Lovable sync also replaces a Lovable-hosted/empty Site URL with its own preview/published address; a non-Lovable domain is kept, but enabling the OAuth server would reset it.

## Owner action required
In Lovable: More -> Users -> Auth settings -> Advanced:
1. Add Redirect URL `https://ai-health-bot-companion.vercel.app/**` (covers both recovery paths with query strings). Optionally add the two exact URLs too.
2. Optionally set Site URL to `https://ai-health-bot-companion.vercel.app` if Vercel is the canonical production frontend (this changes the fallback for all auth emails, including Lovable-preview signups).
3. Keep existing Lovable entries (max 50 total).

## After owner action (when approved)
- Re-read settings read-only with the same inspection to confirm entries.
- Optionally trigger one password reset to a test account and confirm the link lands on the Vercel recovery page.

No code, deployment, database, role or setting changes are proposed by me.
