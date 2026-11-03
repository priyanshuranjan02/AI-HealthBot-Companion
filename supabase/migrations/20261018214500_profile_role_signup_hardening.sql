-- Fail-closed profile role and Auth signup hardening for the October 2026 local path.
-- Kept separate from the privacy-preserving analytics RPC migration.

BEGIN;

-- This is the earliest migration that removes client profile INSERT access.
-- Validate the trusted signup path before changing any policy, grant, role
-- constraint, or function. The historical profile migration uses
-- search_path=public; this preflight accepts only that known body or the
-- hardened empty path, then the replacement below always uses an empty path.
DO $$
DECLARE
  signup_function oid;
  signup_owner oid;
  profiles_owner oid;
  profiles_force_rls boolean;
  owner_bypasses_rls boolean;
  profiles_rls_enabled boolean;
  owner_can_insert_id boolean;
  owner_can_insert_name boolean;
  function_settings text[];
  function_definition text;
  profile_role_default text;
  enabled_trigger_count integer;
BEGIN
  SELECT p.oid, p.proowner, c.relowner, c.relrowsecurity,
         c.relforcerowsecurity,
         r.rolsuper OR r.rolbypassrls,
         has_column_privilege(p.proowner, c.oid, 'id', 'INSERT'),
         has_column_privilege(p.proowner, c.oid, 'full_name', 'INSERT'),
         p.proconfig,
         pg_get_functiondef(p.oid)
    INTO signup_function, signup_owner, profiles_owner, profiles_rls_enabled,
         profiles_force_rls,
         owner_bypasses_rls, owner_can_insert_id, owner_can_insert_name,
         function_settings, function_definition
  FROM pg_proc AS p
  JOIN pg_namespace AS pn ON pn.oid = p.pronamespace
  JOIN pg_class AS c ON c.oid = 'public.profiles'::regclass
  JOIN pg_roles AS r ON r.oid = p.proowner
  WHERE pn.nspname = 'public'
    AND p.proname = 'handle_new_user'
    AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype
    AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql');

  IF signup_function IS NULL THEN
    RAISE EXCEPTION 'public.handle_new_user() with the expected trigger signature is required';
  END IF;

  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = signup_function) THEN
    RAISE EXCEPTION 'public.handle_new_user() must be SECURITY DEFINER';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE oid = signup_owner AND rolname IN ('anon', 'authenticated', 'public')
  ) THEN
    RAISE EXCEPTION 'handle_new_user() must be owned by a trusted database role';
  END IF;

  IF NOT (
    COALESCE(function_settings @> ARRAY['search_path=""']::text[], false)
    OR COALESCE(function_settings @> ARRAY['search_path=public']::text[], false)
  ) THEN
    RAISE EXCEPTION 'Existing handle_new_user search_path is not an approved historical or hardened value';
  END IF;

  IF position('INSERT INTO public.profiles (id, full_name)' IN function_definition) = 0
     OR function_definition ~* 'raw_user_meta_data[^;]*role|INSERT INTO public\.profiles\s*\([^)]*role'
     OR COALESCE(array_length(regexp_split_to_array(function_definition, '\mINSERT\M'), 1) - 1, 0) <> 1
     OR function_definition ~* '\m(UPDATE|DELETE|TRUNCATE|EXECUTE|CALL|PERFORM)\M'
  THEN
    RAISE EXCEPTION 'Existing handle_new_user must create only the expected profile fields and ignore role metadata';
  END IF;

  IF NOT has_schema_privilege(signup_owner, 'public', 'USAGE')
     OR NOT owner_can_insert_id
     OR NOT owner_can_insert_name
     OR (profiles_rls_enabled AND profiles_force_rls AND NOT owner_bypasses_rls)
     OR (profiles_rls_enabled AND NOT profiles_force_rls
         AND signup_owner <> profiles_owner AND NOT owner_bypasses_rls)
  THEN
    RAISE EXCEPTION 'handle_new_user owner lacks required schema, column, or RLS privileges';
  END IF;

  SELECT pg_get_expr(d.adbin, d.adrelid)
    INTO profile_role_default
  FROM pg_attribute AS a
  JOIN pg_attrdef AS d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE a.attrelid = 'public.profiles'::regclass
    AND a.attname = 'role'
    AND NOT a.attisdropped;

  IF profile_role_default IS NULL
     OR position('user' IN lower(profile_role_default)) = 0
  THEN
    RAISE EXCEPTION 'profiles.role must have the expected user default before signup hardening';
  END IF;

  SELECT count(*)
    INTO enabled_trigger_count
  FROM pg_trigger AS t
  WHERE t.tgrelid = 'auth.users'::regclass
    AND t.tgname = 'on_auth_user_created'
    AND t.tgfoid = signup_function
    AND t.tgtype = 5 -- AFTER INSERT, FOR EACH ROW
    AND t.tgconstraint = 0
    AND NOT t.tgdeferrable
    AND NOT t.tginitdeferred
    AND t.tgenabled IN ('O', 'A')
    AND NOT t.tgisinternal;

  IF enabled_trigger_count <> 1 THEN
    RAISE EXCEPTION 'Exactly one enabled AFTER INSERT row trigger on auth.users must invoke public.handle_new_user()';
  END IF;

  IF NOT has_schema_privilege(signup_owner, 'auth', 'USAGE')
     OR to_regprocedure('auth.role()') IS NULL
     OR NOT has_function_privilege(signup_owner, 'auth.role()', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'handle_new_user owner lacks required Auth schema/function privileges';
  END IF;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE role IS NULL OR role NOT IN ('user', 'ngo')
  ) THEN
    RAISE EXCEPTION
      'profiles.role contains NULL or unsupported values; remediate those rows to user or ngo through an approved administrator process before applying this migration';
  END IF;
END;
$$;

ALTER TABLE public.profiles
  ALTER COLUMN role SET NOT NULL,
  ADD CONSTRAINT profiles_role_allowed_values
  CHECK (role IN ('user', 'ngo'));

-- Profiles are created only by public.handle_new_user(), which runs from the
-- auth.users trigger. Removing this policy prevents an account with no profile
-- from inserting itself with role = 'ngo'.
DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
REVOKE INSERT ON TABLE public.profiles FROM authenticated;

-- The auth.users trigger itself must be enabled separately by the Lovable
-- Cloud table owner. This function remains inaccessible to API callers.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;

COMMIT;
