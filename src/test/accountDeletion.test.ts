import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import {
  deleteAccountWorkflow,
  isInvalidSessionAuthError,
} from "../../supabase/functions/delete-account/workflow";
import { requireDeletionConfirmation } from "@/lib/accountDeletion";

const migration = readFileSync(
  join(process.cwd(), "supabase/migrations/20261019100000_atomic_account_deletion.sql"),
  "utf8",
);
const edgeFunction = readFileSync(
  join(process.cwd(), "supabase/functions/delete-account/index.ts"),
  "utf8",
);

describe("account deletion workflow", () => {
  it.each([
    { name: "malformed JWT", error: { status: 403, code: "bad_jwt" }, expected: true },
    { name: "deleted-user token", error: { status: 403, code: "user_not_found" }, expected: true },
    { name: "401 invalid JWT", error: { status: 401, code: "bad_jwt" }, expected: true },
    { name: "unrelated 403", error: { status: 403, code: "insufficient_privilege" }, expected: false },
    { name: "invalid service API key", error: { status: 401, code: "invalid_api_key" }, expected: false },
    { name: "Auth service failure", error: { status: 503, code: "service_unavailable" }, expected: false },
    { name: "network error without an HTTP status", error: {}, expected: false },
  ])("classifies $name as invalid only for known credential errors", ({ error, expected }) => {
    expect(isInvalidSessionAuthError(error)).toBe(expected);
  });

  it("requires explicit endpoint success before the UI may report deletion", () => {
    expect(() => requireDeletionConfirmation({ success: true })).not.toThrow();
    expect(() => requireDeletionConfirmation({ success: false })).toThrow(/not confirmed/i);
    expect(() => requireDeletionConfirmation(null)).toThrow(/not confirmed/i);
    expect(() => requireDeletionConfirmation(undefined)).toThrow(/not confirmed/i);
  });

  it("does not call Auth Admin without a bearer token", async () => {
    const getUser = vi.fn();
    const deleteAuthUser = vi.fn();
    const result = await deleteAccountWorkflow(null, { getUser, deleteAuthUser });

    expect(result.status).toBe(401);
    expect(result.body.success).toBeUndefined();
    expect(getUser).not.toHaveBeenCalled();
    expect(deleteAuthUser).not.toHaveBeenCalled();
  });

  it("deletes the authenticated account with one Auth operation", async () => {
    const deleteAuthUser = vi.fn(async () => ({ error: false }));
    const result = await deleteAccountWorkflow("valid-token", {
      getUser: async () => ({ kind: "authenticated", userId: "user-1" }),
      deleteAuthUser,
    });

    expect(result).toEqual({ status: 200, body: { success: true } });
    expect(deleteAuthUser).toHaveBeenCalledOnce();
    expect(deleteAuthUser).toHaveBeenCalledWith("user-1");
  });

  it("does not report success when Auth returns a deletion error", async () => {
    const deleteAuthUser = vi.fn(async () => ({ error: true }));
    const result = await deleteAccountWorkflow("valid-token", {
      getUser: async () => ({ kind: "authenticated", userId: "user-1" }),
      deleteAuthUser,
    });

    expect(result.status).toBe(503);
    expect(result.body.success).toBeUndefined();
    expect(result.body.error).toMatch(/may have completed/i);
    expect(deleteAuthUser).toHaveBeenCalledOnce();
  });

  it("returns a retryable service error when Auth lookup returns a service failure", async () => {
    const deleteAuthUser = vi.fn(async () => ({ error: false }));
    const result = await deleteAccountWorkflow("valid-token", {
      getUser: async () => ({ kind: "unavailable" }),
      deleteAuthUser,
    });

    expect(result.status).toBe(503);
    expect(result.body.error).toMatch(/unable to verify the session/i);
    expect(deleteAuthUser).not.toHaveBeenCalled();
  });

  it("does not start deletion when Auth lookup throws", async () => {
    const deleteAuthUser = vi.fn(async () => ({ error: false }));
    const result = await deleteAccountWorkflow("valid-token", {
      getUser: async () => { throw new Error("auth lookup unavailable"); },
      deleteAuthUser,
    });

    expect(result.status).toBe(503);
    expect(result.body.success).toBeUndefined();
    expect(result.body.error).toMatch(/previous request may have completed/i);
    expect(deleteAuthUser).not.toHaveBeenCalled();
  });

  it("treats invalid or expired credentials as unauthorized without disclosing account status", async () => {
    const deleteAuthUser = vi.fn(async () => ({ error: false }));
    const result = await deleteAccountWorkflow("expired-token", {
      getUser: async () => ({ kind: "invalid" }),
      deleteAuthUser,
    });

    expect(result.status).toBe(401);
    expect(result.body.success).toBeUndefined();
    expect(result.body.error).toMatch(/previous deletion request may have completed/i);
    expect(result.body.error).not.toMatch(/account (exists|does not exist)/i);
    expect(deleteAuthUser).not.toHaveBeenCalled();
  });

  it("reports a deletion failure without performing pre-delete cleanup", async () => {
    const result = await deleteAccountWorkflow("valid-token", {
      getUser: async () => ({ kind: "authenticated", userId: "user-1" }),
      deleteAuthUser: async () => { throw new Error("transaction failed"); },
    });

    expect(result.status).toBe(503);
    expect(result.body.error).toMatch(/could not be confirmed/i);
    expect(result.body.success).toBeUndefined();
    expect(edgeFunction).not.toContain('.from("symptom_checks").delete()');
    expect(edgeFunction).not.toContain('.from("profiles").delete()');
  });

  it("can safely retry after a failed Auth deletion", async () => {
    const deleteAuthUser = vi.fn()
      .mockResolvedValueOnce({ error: true })
      .mockResolvedValueOnce({ error: false });
    const services = {
      getUser: async () => ({ kind: "authenticated" as const, userId: "user-1" }),
      deleteAuthUser,
    };

    const first = await deleteAccountWorkflow("valid-token", services);
    const retry = await deleteAccountWorkflow("valid-token", services);

    expect(first.status).toBe(503);
    expect(retry).toEqual({ status: 200, body: { success: true } });
    expect(deleteAuthUser).toHaveBeenNthCalledWith(1, "user-1");
    expect(deleteAuthUser).toHaveBeenNthCalledWith(2, "user-1");
  });

  it("does not claim success when a lost response is retried with an invalidated token", async () => {
    const deleteAuthUser = vi.fn(async () => { throw new Error("response lost after commit"); });
    const first = await deleteAccountWorkflow("valid-token", {
      getUser: async () => ({ kind: "authenticated", userId: "user-1" }),
      deleteAuthUser,
    });
    const retry = await deleteAccountWorkflow("old-token", {
      getUser: async () => ({ kind: "invalid" }),
      deleteAuthUser,
    });

    expect(first.status).toBe(503);
    expect(first.body.success).toBeUndefined();
    expect(retry.status).toBe(401);
    expect(retry.body.success).toBeUndefined();
    expect(retry.body.error).toMatch(/cannot confirm its outcome/i);
    expect(deleteAuthUser).toHaveBeenCalledOnce();
  });

  it("declares atomic health deletion and anonymized, retained audit events", () => {
    expect(migration).toMatch(/REFERENCES auth\.users\(id\)\s+ON DELETE CASCADE/i);
    expect(migration).toMatch(/actor_id\s+DROP NOT NULL/i);
    expect(migration).toMatch(/REFERENCES public\.profiles\(id\)\s+ON DELETE SET NULL/i);
    expect(migration).toContain("BEFORE DELETE ON public.profiles");
    expect(migration).toContain("details = '{}'::jsonb");
    expect(migration).toContain("anonymized_at = now()");
    expect(migration).toMatch(/\bBEGIN;[\s\S]*\bCOMMIT;/);
  });
});
