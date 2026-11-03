export type AccountDeletionResult = {
  status: number;
  body: { success?: true; error?: string };
};

export type AccountDeletionServices = {
  getUser: (accessToken: string) => Promise<
    | { kind: "authenticated"; userId: string }
    | { kind: "invalid" }
    | { kind: "unavailable" }
  >;
  deleteAuthUser: (userId: string) => Promise<{ error: boolean }>;
};

export type AuthLookupError = { status?: number; code?: string };

const INVALID_SESSION_CODES = new Set(["bad_jwt", "user_not_found"]);

/** Supabase Auth returns these codes for a rejected bearer credential. Do not
 * classify unrelated 401/403 responses or service/network failures as invalid. */
export const isInvalidSessionAuthError = (error: AuthLookupError): boolean =>
  (error.status === 401 || error.status === 403) &&
  INVALID_SESSION_CODES.has(error.code ?? "");

/**
 * Auth Admin issues one deletion operation; PostgreSQL cascades and audit
 * anonymization run in that database transaction. The HTTP request/response
 * can still be lost, so only a confirmed Auth Admin response reports success.
 */
export const deleteAccountWorkflow = async (
  accessToken: string | null,
  services: AccountDeletionServices,
): Promise<AccountDeletionResult> => {
  if (!accessToken) {
    return { status: 401, body: { error: "Authentication required" } };
  }

  let auth: Awaited<ReturnType<AccountDeletionServices["getUser"]>>;
  try {
    auth = await services.getUser(accessToken);
  } catch {
    return {
      status: 503,
      body: {
        error: "Unable to verify the session. Deletion was not attempted by this request; a previous request may have completed.",
      },
    };
  }

  if (auth.kind === "unavailable") {
    return {
      status: 503,
      body: {
        error: "Unable to verify the session. Deletion was not attempted by this request; a previous request may have completed.",
      },
    };
  }

  if (auth.kind === "invalid") {
    return {
      status: 401,
      body: {
        error: "The session is invalid. A previous deletion request may have completed; this response cannot confirm its outcome.",
      },
    };
  }

  try {
    const deletion = await services.deleteAuthUser(auth.userId);
    if (deletion.error) {
      return {
        status: 503,
        body: {
          error: "Deletion could not be confirmed. It may have completed; if you can still sign in, retry once, otherwise contact support.",
        },
      };
    }
  } catch {
    return {
      status: 503,
      body: {
        error: "Deletion could not be confirmed. It may have completed; if you can still sign in, retry once, otherwise contact support.",
      },
    };
  }

  return { status: 200, body: { success: true } };
};
