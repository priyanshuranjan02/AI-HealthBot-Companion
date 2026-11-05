-- Forward-only correction for the verified Lovable profile self-insert gap.
-- This migration preserves the existing Auth signup and role-update trigger
-- functions/ACLs; it changes profile role constraints, the identified own-
-- profile INSERT policy, and INSERT grants only.
BEGIN;

-- Fail before taking a relation lock unless the effective executor can perform
-- the required table-owner DDL. Membership alone is not sufficient.
DO $runner_preflight$
DECLARE
  profiles_oid oid := pg_catalog.to_regclass('public.profiles');
  profiles_owner oid;
  executor_oid oid;
  executor_is_superuser boolean;
BEGIN
  IF profiles_oid IS NULL THEN
    RAISE EXCEPTION 'Required relation public.profiles is missing';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class
                 WHERE oid = profiles_oid AND relkind IN ('r', 'p')) THEN
    RAISE EXCEPTION 'public.profiles must be a table or partitioned table';
  END IF;

  SELECT c.relowner INTO profiles_owner
  FROM pg_catalog.pg_class AS c
  WHERE c.oid = profiles_oid;

  SELECT r.oid, r.rolsuper INTO executor_oid, executor_is_superuser
  FROM pg_catalog.pg_roles AS r
  WHERE r.rolname = current_user;

  IF executor_oid IS NULL
     OR (NOT COALESCE(executor_is_superuser, false)
         AND executor_oid <> profiles_owner) THEN
    RAISE EXCEPTION
      'Migration executor must be a superuser or the owner of public.profiles';
  END IF;
END;
$runner_preflight$;

-- Hold writes to profiles between the data gate and NOT NULL/CHECK creation.
LOCK TABLE public.profiles IN ACCESS EXCLUSIVE MODE;

DO $baseline_preflight$
DECLARE
  profiles_oid oid := pg_catalog.to_regclass('public.profiles');
  auth_users_oid oid := pg_catalog.to_regclass('auth.users');
  profiles_owner oid;
  role_attnum smallint;
  role_type oid;
  role_is_notnull boolean;
  role_default text;
  null_role_count bigint;
  unsupported_role_count bigint;
  auth_oid oid;
  anon_oid oid;
  service_oid oid;
  signup_oid oid := pg_catalog.to_regprocedure('public.handle_new_user()');
  signup_owner oid;
  signup_source text;
  signup_is_definer boolean;
  signup_settings text[];
  signup_language oid;
  signup_profile_rls boolean;
  signup_profile_force_rls boolean;
  role_guard_oid oid := pg_catalog.to_regprocedure('public.prevent_profile_role_escalation()');
  role_guard_source text;
  role_guard_settings text[];
  role_guard_language oid;
  policy_count integer;
BEGIN
  IF auth_users_oid IS NULL THEN
    RAISE EXCEPTION 'Required relation auth.users is missing; Auth signup cannot be preserved';
  END IF;

  SELECT oid INTO anon_oid FROM pg_catalog.pg_roles WHERE rolname = 'anon';
  SELECT oid INTO auth_oid FROM pg_catalog.pg_roles WHERE rolname = 'authenticated';
  SELECT oid INTO service_oid FROM pg_catalog.pg_roles WHERE rolname = 'service_role';
  IF anon_oid IS NULL OR auth_oid IS NULL OR service_oid IS NULL THEN
    RAISE EXCEPTION 'Required API roles anon, authenticated, and service_role must exist';
  END IF;

  SELECT c.relowner, c.relrowsecurity, c.relforcerowsecurity
    INTO profiles_owner, signup_profile_rls, signup_profile_force_rls
  FROM pg_catalog.pg_class AS c
  WHERE c.oid = profiles_oid;

  SELECT a.attnum, a.atttypid, a.attnotnull
    INTO role_attnum, role_type, role_is_notnull
  FROM pg_catalog.pg_attribute AS a
  WHERE a.attrelid = profiles_oid AND a.attname = 'role'
    AND a.attnum > 0 AND NOT a.attisdropped;
  IF role_attnum IS NULL OR role_type <> 'text'::regtype THEN
    RAISE EXCEPTION 'public.profiles.role must exist as a text column';
  END IF;
  IF role_is_notnull IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Expected starting state requires nullable public.profiles.role';
  END IF;

  SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid)
    INTO role_default
  FROM pg_catalog.pg_attrdef AS d
  WHERE d.adrelid = profiles_oid AND d.adnum = role_attnum;
  IF regexp_replace(COALESCE(role_default, ''), '[[:space:]]+', '', 'g')
       NOT IN ('''user''::text', '''user''') THEN
    RAISE EXCEPTION 'profiles.role must retain its existing default of user';
  END IF;

  SELECT count(*) FILTER (WHERE p.role IS NULL),
         count(*) FILTER (WHERE p.role IS NOT NULL AND p.role NOT IN ('user', 'ngo'))
    INTO null_role_count, unsupported_role_count
  FROM public.profiles AS p;
  IF null_role_count <> 0 OR unsupported_role_count <> 0 THEN
    RAISE EXCEPTION
      'Profile role data is not eligible for hardening (NULL rows: %, unsupported rows: %); remediate through an approved process, then retry',
      null_role_count, unsupported_role_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint AS c
    WHERE c.conrelid = profiles_oid
      AND (c.conname = 'profiles_role_allowed_values'
           OR (c.contype = 'c' AND role_attnum = ANY (c.conkey)))
  ) THEN
    RAISE EXCEPTION
      'A CHECK constraint already references profiles.role; reconcile its exact definition before applying this migration';
  END IF;

  IF NOT signup_profile_rls THEN
    RAISE EXCEPTION 'RLS must remain enabled on public.profiles';
  END IF;

  -- Require the exact known own-profile policy before removing it. Other
  -- INSERT/ALL policies applicable to API roles or PUBLIC fail closed.
  SELECT count(*) INTO policy_count
  FROM pg_catalog.pg_policy AS p
  WHERE p.polrelid = profiles_oid AND p.polname = 'Users can insert own profile'
    AND p.polcmd = 'a' AND p.polpermissive
    AND p.polroles = ARRAY[auth_oid]::oid[]
    AND p.polqual IS NULL
    AND regexp_replace(lower(pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid)),
                       '[[:space:]]+', '', 'g')
        IN ('(uid()=id)', '(auth.uid()=id)');
  IF policy_count <> 1 THEN
    RAISE EXCEPTION
      'Expected exactly one authenticated own-profile INSERT policy with auth.uid() = id; actual policy state requires review';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy AS p
    WHERE p.polrelid = profiles_oid AND p.polcmd IN ('a', '*')
      AND p.polroles && ARRAY[0::oid, anon_oid, auth_oid, service_oid]::oid[]
      AND p.polname <> 'Users can insert own profile'
  ) THEN
    RAISE EXCEPTION
      'An additional profile INSERT/ALL policy applies to PUBLIC or an API role; reconcile it before migration';
  END IF;

  IF NOT has_column_privilege(auth_oid, profiles_oid, 'role', 'INSERT') THEN
    RAISE EXCEPTION
      'The reported starting condition (authenticated can INSERT profiles.role) is absent; reconcile target state before migration';
  END IF;

  -- Preserve and verify the trusted Auth signup implementation. This migration
  -- does not replace the function, alter its owner, or change its ACL.
  SELECT p.proowner, p.prosrc, p.prosecdef, p.proconfig, p.prolang
    INTO signup_owner, signup_source, signup_is_definer, signup_settings, signup_language
  FROM pg_catalog.pg_proc AS p
  WHERE p.oid = signup_oid AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype;
  IF signup_oid IS NULL OR signup_owner IS NULL
     OR signup_language <> (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
     OR signup_is_definer IS DISTINCT FROM true
     OR NOT (COALESCE(signup_settings @> ARRAY['search_path=""']::text[], false)
             OR COALESCE(signup_settings @> ARRAY['search_path=public']::text[], false))
     OR btrim(signup_source) IS DISTINCT FROM btrim($signup_body$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$signup_body$)
     OR EXISTS (
       SELECT 1 FROM pg_catalog.pg_roles AS r
       WHERE r.oid = signup_owner AND r.rolname IN ('anon', 'authenticated', 'service_role')
     )
     OR NOT has_schema_privilege(signup_owner, 'public', 'USAGE')
     OR NOT has_column_privilege(signup_owner, profiles_oid, 'id', 'INSERT')
     OR NOT has_column_privilege(signup_owner, profiles_oid, 'full_name', 'INSERT')
     OR (signup_profile_rls AND signup_profile_force_rls
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE oid = signup_owner
                         AND (rolsuper OR rolbypassrls)))
     OR (signup_profile_rls AND NOT signup_profile_force_rls
         AND signup_owner <> profiles_owner
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE oid = signup_owner
                         AND (rolsuper OR rolbypassrls))) THEN
    RAISE EXCEPTION
      'Trusted handle_new_user() definition, owner, or profile INSERT authority differs; refusing to alter the signup path';
  END IF;

  IF (SELECT count(*) FROM pg_catalog.pg_trigger AS t
      WHERE t.tgrelid = auth_users_oid AND NOT t.tgisinternal
        AND t.tgname = 'on_auth_user_created'
        AND t.tgfoid = signup_oid AND t.tgtype = 5 AND t.tgqual IS NULL
        AND t.tgconstraint = 0 AND NOT t.tgdeferrable AND NOT t.tginitdeferred
        AND t.tgenabled IN ('O', 'A')) <> 1 THEN
    RAISE EXCEPTION
      'Expected enabled AFTER INSERT row trigger on auth.users calling handle_new_user() is missing or differs';
  END IF;

  -- Verify, but do not replace or change, the UPDATE-only role guard.
  SELECT p.prosrc, p.proconfig, p.prolang
    INTO role_guard_source, role_guard_settings, role_guard_language
  FROM pg_catalog.pg_proc AS p
  WHERE p.oid = role_guard_oid AND p.pronargs = 0
    AND p.prorettype = 'pg_catalog.trigger'::regtype
    AND NOT p.prosecdef;
  IF role_guard_oid IS NULL OR role_guard_source IS NULL
     OR role_guard_language <> (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
     OR role_guard_settings IS DISTINCT FROM ARRAY['search_path=""']::text[]
     OR btrim(role_guard_source) IS DISTINCT FROM btrim($role_guard_body$
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
$role_guard_body$)
     OR (SELECT count(*) FROM pg_catalog.pg_trigger AS t
         WHERE t.tgrelid = profiles_oid AND NOT t.tgisinternal
           AND t.tgname = 'prevent_profile_role_escalation'
           AND t.tgfoid = role_guard_oid AND t.tgtype = 19
           AND t.tgqual IS NULL AND t.tgconstraint = 0
           AND NOT t.tgdeferrable AND NOT t.tginitdeferred
           AND t.tgenabled IN ('O', 'A')
           AND array_length(t.tgattr, 1) = 1
           AND role_attnum = ANY (t.tgattr)) <> 1 THEN
    RAISE EXCEPTION
      'Existing role-update trigger/function differs from the reviewed contract; refusing to replace or weaken it';
  END IF;

  -- Trigger contract for profile writes: the only enabled non-internal
  -- INSERT/UPDATE trigger on profiles (including inheritance descendants) may
  -- be the exact BEFORE UPDATE OF role guard validated above. Other INSERT
  -- triggers can change NEW.role, and other UPDATE triggers can change it or
  -- perform follow-up writes that interfere with role protection. Unrelated
  -- DELETE/TRUNCATE-only triggers are outside this write-path contract.
  IF EXISTS (
    WITH RECURSIVE profile_relations(relid, relation_path) AS (
      SELECT profiles_oid, ARRAY[profiles_oid]::oid[]
      UNION ALL
      SELECT i.inhrelid, r.relation_path || i.inhrelid
      FROM profile_relations AS r
      JOIN pg_catalog.pg_inherits AS i ON i.inhparent = r.relid
      WHERE NOT (i.inhrelid = ANY (r.relation_path))
    )
    SELECT 1
    FROM profile_relations AS part
    JOIN pg_catalog.pg_trigger AS t ON t.tgrelid = part.relid
    WHERE NOT t.tgisinternal
      AND t.tgenabled IN ('O', 'A', 'R')
      AND (t.tgtype & 20) <> 0 -- INSERT or UPDATE event
      AND NOT (
        t.tgname = 'prevent_profile_role_escalation'
        AND t.tgfoid = role_guard_oid
        AND t.tgtype = 19
        AND t.tgqual IS NULL
        AND t.tgconstraint = 0
        AND NOT t.tgdeferrable
        AND NOT t.tginitdeferred
        AND t.tgenabled IN ('O', 'A')
        AND array_length(t.tgattr, 1) = 1
        AND role_attnum = ANY (t.tgattr)
      )
  ) THEN
    RAISE EXCEPTION
      'Unexpected enabled INSERT/UPDATE trigger on public.profiles or a partition; reconcile the write-trigger contract before migration';
  END IF;
END;
$baseline_preflight$;

-- These changes are narrowly scoped to role validity and API profile INSERT.
ALTER TABLE public.profiles
  ALTER COLUMN role SET NOT NULL,
  ADD CONSTRAINT profiles_role_allowed_values
    CHECK (role IN ('user', 'ngo'));

DROP POLICY "Users can insert own profile" ON public.profiles;

REVOKE INSERT ON TABLE public.profiles
  FROM PUBLIC, anon, authenticated, service_role;

-- Table REVOKE does not remove independent column-level grants. Revoke INSERT
-- from the same grantees on every current user column without touching any
-- other column privilege or depending on a hard-coded column list.
DO $revoke_column_insert$
DECLARE
  column_list text;
BEGIN
  SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum)
    INTO column_list
  FROM pg_catalog.pg_attribute AS a
  WHERE a.attrelid = 'public.profiles'::regclass
    AND a.attnum > 0 AND NOT a.attisdropped;

  IF column_list IS NULL THEN
    RAISE EXCEPTION 'public.profiles has no user columns; refusing column ACL cleanup';
  END IF;

  EXECUTE format(
    'REVOKE INSERT (%s) ON TABLE public.profiles FROM PUBLIC, anon, authenticated, service_role',
    column_list
  );
END;
$revoke_column_insert$;

DO $postconditions$
DECLARE
  profiles_oid oid := 'public.profiles'::regclass;
  anon_oid oid := 'anon'::regrole;
  auth_oid oid := 'authenticated'::regrole;
  service_oid oid := 'service_role'::regrole;
  api_oid oid;
  role_attnum smallint;
BEGIN
  IF NOT (SELECT a.attnotnull AND a.atttypid = 'text'::regtype
          FROM pg_catalog.pg_attribute AS a
          WHERE a.attrelid = profiles_oid AND a.attname = 'role'
            AND a.attnum > 0 AND NOT a.attisdropped)
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_constraint AS c
       WHERE c.conrelid = profiles_oid AND c.conname = 'profiles_role_allowed_values'
         AND c.contype = 'c' AND c.convalidated
         AND regexp_replace(lower(pg_catalog.pg_get_constraintdef(c.oid)),
                            '[[:space:]]+', '', 'g')
             = 'check((role=any(array[''user''::text,''ngo''::text])))'
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_attrdef AS d
       JOIN pg_catalog.pg_attribute AS a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
       WHERE d.adrelid = profiles_oid AND a.attname = 'role'
         AND regexp_replace(pg_catalog.pg_get_expr(d.adbin, d.adrelid),
                            '[[:space:]]+', '', 'g') = '''user''::text'
     ) THEN
    RAISE EXCEPTION 'Final profile role NOT NULL/default/allowed-values postconditions failed';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_policy AS p
    WHERE p.polrelid = profiles_oid AND p.polcmd IN ('a', '*')
      AND p.polroles && ARRAY[0::oid, anon_oid, auth_oid, service_oid]::oid[]
  ) THEN
    RAISE EXCEPTION 'An INSERT/ALL policy still applies to PUBLIC or an API role on profiles';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS c
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) AS acl
    WHERE c.oid = profiles_oid AND acl.privilege_type = 'INSERT'
      AND acl.grantee IN (0, anon_oid, auth_oid, service_oid)
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute AS a
    CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) AS acl
    WHERE a.attrelid = profiles_oid AND a.attnum > 0 AND NOT a.attisdropped
      AND acl.privilege_type = 'INSERT'
      AND acl.grantee IN (0, anon_oid, auth_oid, service_oid)
  ) THEN
    RAISE EXCEPTION 'Direct PUBLIC/API table or column INSERT ACL remains on profiles';
  END IF;

  IF has_table_privilege(anon_oid, profiles_oid, 'INSERT')
     OR has_any_column_privilege(anon_oid, profiles_oid, 'INSERT')
     OR has_table_privilege(auth_oid, profiles_oid, 'INSERT')
     OR has_any_column_privilege(auth_oid, profiles_oid, 'INSERT')
     OR has_table_privilege(service_oid, profiles_oid, 'INSERT')
     OR has_any_column_privilege(service_oid, profiles_oid, 'INSERT') THEN
    RAISE EXCEPTION 'An API role retains effective profile INSERT privileges';
  END IF;

  -- Check roles available through every legal SET ROLE edge. For each
  -- reachable role, has_* also accounts for its INHERIT/effective privileges.
  FOR api_oid IN SELECT unnest(ARRAY[anon_oid, auth_oid, service_oid]) LOOP
    IF EXISTS (
      WITH RECURSIVE settable_roles(role_oid, role_path) AS (
        SELECT api_oid, ARRAY[api_oid]::oid[]
        UNION ALL
        SELECT m.roleid, s.role_path || m.roleid
        FROM settable_roles AS s
        JOIN pg_catalog.pg_auth_members AS m ON m.member = s.role_oid
        WHERE m.set_option AND NOT (m.roleid = ANY (s.role_path))
      )
      SELECT 1 FROM settable_roles AS s
      WHERE has_table_privilege(s.role_oid, profiles_oid, 'INSERT')
         OR has_any_column_privilege(s.role_oid, profiles_oid, 'INSERT')
    ) THEN
      RAISE EXCEPTION
        'An API role has a SET ROLE path to effective profile INSERT privileges';
    END IF;
  END LOOP;

  SELECT a.attnum INTO role_attnum
  FROM pg_catalog.pg_attribute AS a
  WHERE a.attrelid = profiles_oid AND a.attname = 'role'
    AND a.attnum > 0 AND NOT a.attisdropped;

  -- Reconfirm both existing triggers without changing either function or ACL.
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger AS t
    JOIN pg_catalog.pg_proc AS p ON p.oid = t.tgfoid
    WHERE t.tgrelid = 'auth.users'::regclass
      AND t.tgname = 'on_auth_user_created'
      AND t.tgfoid = 'public.handle_new_user()'::regprocedure
      AND t.tgtype = 5 AND t.tgqual IS NULL AND t.tgconstraint = 0
      AND NOT t.tgdeferrable AND NOT t.tginitdeferred
      AND t.tgenabled IN ('O', 'A') AND NOT t.tgisinternal
      AND p.prosecdef AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
      AND (COALESCE(p.proconfig @> ARRAY['search_path=""']::text[], false)
           OR COALESCE(p.proconfig @> ARRAY['search_path=public']::text[], false))
      AND btrim(p.prosrc) = btrim($signup_post_body$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$signup_post_body$)
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger AS t
    JOIN pg_catalog.pg_proc AS p ON p.oid = t.tgfoid
    WHERE t.tgrelid = profiles_oid
      AND t.tgname = 'prevent_profile_role_escalation'
      AND t.tgfoid = 'public.prevent_profile_role_escalation()'::regprocedure
      AND t.tgtype = 19 AND t.tgqual IS NULL AND t.tgconstraint = 0
      AND NOT t.tgdeferrable AND NOT t.tginitdeferred
      AND t.tgenabled IN ('O', 'A') AND NOT t.tgisinternal
      AND array_length(t.tgattr, 1) = 1
      AND role_attnum = ANY (t.tgattr)
      AND NOT p.prosecdef
      AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
      AND p.proconfig = ARRAY['search_path=""']::text[]
      AND btrim(p.prosrc) = btrim($role_guard_post_body$
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
$role_guard_post_body$)
  ) THEN
    RAISE EXCEPTION 'Existing Auth signup or profile role-update trigger was not preserved';
  END IF;

  -- Enforce the same profile write-trigger contract after the ACL/constraint
  -- changes. Copies of the expected role guard on inheritance descendants are allowed.
  IF EXISTS (
    WITH RECURSIVE profile_relations(relid, relation_path) AS (
      SELECT profiles_oid, ARRAY[profiles_oid]::oid[]
      UNION ALL
      SELECT i.inhrelid, r.relation_path || i.inhrelid
      FROM profile_relations AS r
      JOIN pg_catalog.pg_inherits AS i ON i.inhparent = r.relid
      WHERE NOT (i.inhrelid = ANY (r.relation_path))
    )
    SELECT 1
    FROM profile_relations AS part
    JOIN pg_catalog.pg_trigger AS t ON t.tgrelid = part.relid
    WHERE NOT t.tgisinternal
      AND t.tgenabled IN ('O', 'A', 'R')
      AND (t.tgtype & 20) <> 0
      AND NOT (
        t.tgname = 'prevent_profile_role_escalation'
        AND t.tgfoid = 'public.prevent_profile_role_escalation()'::regprocedure
        AND t.tgtype = 19
        AND t.tgqual IS NULL
        AND t.tgconstraint = 0
        AND NOT t.tgdeferrable
        AND NOT t.tginitdeferred
        AND t.tgenabled IN ('O', 'A')
        AND array_length(t.tgattr, 1) = 1
        AND role_attnum = ANY (t.tgattr)
      )
  ) THEN
    RAISE EXCEPTION
      'Final profile INSERT/UPDATE trigger contract failed';
  END IF;
END;
$postconditions$;

COMMIT;
