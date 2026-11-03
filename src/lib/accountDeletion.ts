export const requireDeletionConfirmation = (response: unknown): void => {
  if (
    typeof response !== "object" ||
    response === null ||
    (response as { success?: unknown }).success !== true
  ) {
    throw new Error("Deletion was not confirmed");
  }
};
