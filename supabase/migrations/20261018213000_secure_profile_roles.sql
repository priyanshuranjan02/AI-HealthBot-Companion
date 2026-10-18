-- Prevent users from changing their own account role.
-- Existing roles and profile permissions remain unchanged.

CREATE OR REPLACE FUNCTION public.prevent_profile_role_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role
     AND current_user NOT IN (
       'postgres',
       'service_role',
       'supabase_admin'
     )
     AND COALESCE(auth.role(), '') NOT IN (
       'service_role',
       'supabase_admin'
     )
  THEN
    RAISE EXCEPTION 'Changing account role is not permitted'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_profile_role_escalation
ON public.profiles;

CREATE TRIGGER prevent_profile_role_escalation
BEFORE UPDATE OF role ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.prevent_profile_role_escalation();