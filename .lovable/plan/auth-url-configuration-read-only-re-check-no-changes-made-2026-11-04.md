# Auth URL Configuration: read-only re-check (no changes made)

## Verified identity
- Backend ref `nbqphskrnstcmudvhzie`, environment `prod`.
- The live Vercel bundle points to the same backend.

## Live settings now
- Site URL: `https://ai-health-bot-companion.vercel.app/`. This changed since the last check; it was the Lovable preview before.
- Redirect allowlist: still only the 10 Lovable-hosted entries. `https://ai-health-bot-companion.vercel.app/**` is **NOT present**.

## Recovery path coverage
- `https://ai-health-bot-companion.vercel.app/admin/login?recovery=1`: not on the allowlist.
- `https://ai-health-bot-companion.vercel.app/auth?recovery=1`: not on the allowlist.
- Likely effect: a recovery link that asks for either address is not accepted as an explicit redirect. Auth falls back to the Site URL, which is the Vercel root without the path or `?recovery=1`. So the recovery screens probably won't open. I have not tested this.

## Owner action still required
1. In More -> Users -> Auth settings -> Advanced -> Redirect URLs, add `https://ai-health-bot-companion.vercel.app/**` and save.
2. Confirm the entry stays after the page reloads. It may have been typed into the Site URL field by mistake, since the Site URL is the only thing that changed.
3. Then ask me for another read-only re-check.

No code, deployment, database, role or setting changes are proposed by me.
