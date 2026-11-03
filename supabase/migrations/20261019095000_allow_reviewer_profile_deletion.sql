-- Preserve application decisions when the reviewing profile is deleted.
-- The nullable reviewer_id FK already uses ON DELETE SET NULL; the original
-- status check must not require that profile to remain present forever.

BEGIN;

DO $$
DECLARE
  existing_definition text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
    INTO existing_definition
  FROM pg_constraint AS c
  WHERE c.conrelid = 'public.ngo_applications'::regclass
    AND c.conname = 'ngo_applications_check'
    AND c.contype = 'c';

  IF existing_definition IS NULL
     OR position('reviewer_id IS NOT NULL' IN existing_definition) = 0
  THEN
    RAISE EXCEPTION
      'Expected ngo_applications_check requiring reviewer_id; inspect the live constraint before applying this migration';
  END IF;
END;
$$;

ALTER TABLE public.ngo_applications
  DROP CONSTRAINT ngo_applications_check,
  ADD CONSTRAINT ngo_applications_review_state_check
  CHECK (
    (
      status = 'pending'
      AND reviewer_id IS NULL
      AND decided_at IS NULL
      AND review_reason IS NULL
    )
    OR (
      status = 'approved'
      AND decided_at IS NOT NULL
    )
    OR (
      status IN ('rejected', 'suspended')
      AND decided_at IS NOT NULL
      AND coalesce(length(trim(review_reason)), 0) > 0
    )
  );

COMMIT;
