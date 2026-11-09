import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { describe, expect, it } from "vitest";

// Opt-in only. Both endpoints must be loopback addresses and the operator must
// explicitly identify the isolated disposable PostgreSQL 17 test fixture.
const supabaseUrl = process.env.HEALTHBOT_REINSTATEMENT_LOCAL_SUPABASE_URL;
const serviceRoleKey = process.env.HEALTHBOT_REINSTATEMENT_LOCAL_SERVICE_ROLE_KEY;
const reviewerId = process.env.HEALTHBOT_REINSTATEMENT_LOCAL_ADMIN_USER_ID;
const fixtureToken = process.env.HEALTHBOT_REINSTATEMENT_DISPOSABLE_FIXTURE;
const attempted = Boolean(supabaseUrl || serviceRoleKey || reviewerId || fixtureToken);
const isLoopback = (value: string | undefined) => {
  if (!value) return false;
  try {
    return ["localhost", "127.0.0.1", "::1", "[::1]"].includes(new URL(value).hostname);
  } catch {
    return false;
  }
};

describe.skipIf(!attempted)("disposable NGO reinstatement concurrency", () => {
  it("serializes simultaneous reinstatement RPC calls to one transition", async () => {
    if (
      !supabaseUrl || !serviceRoleKey || !reviewerId ||
      fixtureToken !== "aihealthbot-admin-ngo-reinstatement-pg17" ||
      !isLoopback(supabaseUrl) ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(reviewerId)
    ) {
      throw new Error("Concurrency validation requires the explicitly approved loopback-only disposable fixture and reviewer UUID");
    }

    const client = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: role, error: roleError } = await client.from("user_roles")
      .select("user_id").eq("user_id", reviewerId).eq("role", "admin").maybeSingle();
    if (roleError || !role) throw new Error("Fixture reviewer UUID is not an administrator in this disposable project");

    const applicantEmail = `reinstatement-${randomUUID()}@example.invalid`;
    const { data: created, error: createError } = await client.auth.admin.createUser({
      email: applicantEmail,
      password: randomUUID(),
      email_confirm: true,
      user_metadata: { full_name: "Synthetic reinstatement concurrency applicant" },
    });
    if (createError || !created.user) throw new Error("Could not create a synthetic applicant in the approved disposable fixture");

    const applicantId = created.user.id;
    const applicationId = randomUUID();
    try {
      const { data: profile, error: profileError } = await client.from("profiles")
        .select("role").eq("id", applicantId).maybeSingle();
      if (profileError || profile?.role !== "user") {
        throw new Error("Auth signup did not create the expected standard-user profile in the disposable fixture");
      }

      const { error: applicationError } = await client.from("ngo_applications").insert({
        id: applicationId,
        applicant_user_id: applicantId,
        organization_name: "Synthetic concurrent reinstatement",
        registration_identifier: `REINSTATE-${applicationId}`,
        official_contact_email: applicantEmail,
        official_contact_phone: "+10000000000",
        website: null,
        evidence_references: [],
        status: "suspended",
        reviewer_id: reviewerId,
        decided_at: new Date().toISOString(),
        review_reason: "Synthetic original suspension reason",
      });
      if (applicationError) throw new Error("Could not create the synthetic suspended application in the disposable fixture");

      const { error: auditError } = await client.from("admin_audit_log").insert({
        actor_id: reviewerId,
        action: "ngo_application_suspended",
        application_id: applicationId,
        target_user_id: applicantId,
        details: { reason: "Synthetic original suspension reason" },
      });
      if (auditError) throw new Error("Could not create the synthetic suspension audit event in the disposable fixture");

      const attempts = await Promise.all([
        client.rpc("reinstate_ngo_application", {
          p_reviewer_id: reviewerId,
          p_application_id: applicationId,
          p_reason: "Synthetic concurrent reinstatement attempt A",
        }),
        client.rpc("reinstate_ngo_application", {
          p_reviewer_id: reviewerId,
          p_application_id: applicationId,
          p_reason: "Synthetic concurrent reinstatement attempt B",
        }),
      ]);
      expect(attempts.filter(({ error }) => error === null)).toHaveLength(1);
      const rejected = attempts.filter(({ error }) => error !== null);
      expect(rejected).toHaveLength(1);
      expect(rejected[0].error?.code).toBe("P0002");

      const { data: state, error: stateError } = await client.from("ngo_applications")
        .select("status, applicant_user_id, review_reason")
        .eq("id", applicationId).single();
      const { data: restoredProfile, error: restoredProfileError } = await client.from("profiles")
        .select("role").eq("id", applicantId).single();
      const { data: events, error: eventError } = await client.from("admin_audit_log")
        .select("id, action, actor_id, application_id, target_user_id, details")
        .eq("application_id", applicationId);
      if (stateError || restoredProfileError || eventError) throw new Error("Could not verify the concurrent result in the disposable fixture");
      expect(state).toMatchObject({ status: "approved", applicant_user_id: applicantId, review_reason: null });
      expect(restoredProfile.role).toBe("ngo");
      expect(events?.filter((event) => event.action === "ngo_application_reinstated")).toHaveLength(1);
      expect(events?.filter((event) => event.action === "ngo_application_suspended")).toHaveLength(1);

      // Synthetic identifiers only. Capture the exact audit rows before the
      // finally block deletes the applicant and intentionally anonymizes them.
      console.info("AIHB_SYNTHETIC_REINSTATEMENT_AUDIT " + JSON.stringify({
        reviewerId,
        applicantId,
        applicationId,
        events: events?.map(({ id, action, actor_id, application_id, target_user_id }) => ({
          id,
          action,
          actor_id,
          application_id,
          target_user_id,
        })),
      }));
    } finally {
      // Auth deletion cascades the synthetic application; audit rows are
      // intentionally retained. Discard this disposable fixture after testing.
      await client.auth.admin.deleteUser(applicantId);
    }
  }, 30000);
});
