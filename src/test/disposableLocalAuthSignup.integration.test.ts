import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { createClient } from "@supabase/supabase-js";

// These tests are opt-in and only permit loopback URLs. Supply credentials for
// a fresh, disposable local Supabase project; never point them at production.
const localUrl = process.env.HEALTHBOT_DISPOSABLE_LOCAL_SUPABASE_URL;
const localAnonKey = process.env.HEALTHBOT_DISPOSABLE_LOCAL_SUPABASE_ANON_KEY;
const isLoopbackUrl = (() => {
  if (!localUrl) return false;
  try {
    return ["localhost", "127.0.0.1", "::1", "[::1]"].includes(new URL(localUrl).hostname);
  } catch {
    return false;
  }
})();

describe.skipIf(!localUrl || !localAnonKey || !isLoopbackUrl)(
  "disposable local Supabase Auth signup",
  () => {
    it.each(["admin", "ngo"] as const)(
      "ignores hostile %s role metadata and creates a user profile",
      async (forgedRole) => {
        const authClient = createClient(localUrl!, localAnonKey!, {
          auth: { autoRefreshToken: false, persistSession: false },
        });
        const syntheticId = randomUUID();
        const { data, error } = await authClient.auth.signUp({
          email: `healthbot-${syntheticId}@example.invalid`,
          password: `Local-only-${randomUUID()}-aA1!`,
          options: {
            data: {
              full_name: "Synthetic signup integration test",
              role: forgedRole,
            },
          },
        });

        if (error || !data.user) {
          throw new Error("Disposable local Auth signup did not return a user");
        }
        if (!data.session) {
          throw new Error(
            "Disposable local Auth must issue a session so the profile can be read under own-profile RLS",
          );
        }

        const profileClient = createClient(localUrl!, localAnonKey!, {
          auth: { autoRefreshToken: false, persistSession: false },
          global: {
            headers: { Authorization: `Bearer ${data.session.access_token}` },
          },
        });
        const { data: profile, error: profileError } = await profileClient
          .from("profiles")
          .select("role")
          .eq("id", data.user.id)
          .single();

        if (profileError) {
          throw new Error("Could not read the synthetic signup profile locally");
        }
        expect(profile.role).toBe("user");
      },
    );
  },
);
