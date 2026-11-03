-- AI HealthBot supplementary migration-drift inspection.
-- Run once in Lovable Cloud -> View Backend -> SQL Editor.
-- This is one read-only SELECT statement; it does not assume a session identity.
-- If an object is missing, its row reports MISSING or UNKNOWN where applicable.
-- Do not treat errors or truncated results as a successful preflight.

WITH
role_specs(role_name) AS (
  VALUES ('anon'::text), ('authenticated'::text), ('service_role'::text),
         ('postgres'::text), ('supabase_admin'::text),
         (session_user::text), (current_user::text)
),
role_rows AS (
  SELECT DISTINCT s.role_name, r.oid, r.rolsuper, r.rolinherit, r.rolbypassrls,
         r.rolcanlogin, r.rolcreaterole, r.rolcreatedb, r.rolreplication
  FROM role_specs s LEFT JOIN pg_catalog.pg_roles r ON r.rolname::text=s.role_name
),
profiles AS (
  SELECT to_regclass('public.profiles') AS oid
),
profile_role_column AS (
  SELECT a.attnum, a.atttypid, a.atttypmod, a.attnotnull, a.attisdropped,
         d.adbin, d.adrelid
  FROM profiles p JOIN pg_catalog.pg_attribute a ON a.attrelid=p.oid
  LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
  WHERE a.attname='role' AND a.attnum>0 AND NOT a.attisdropped
),
role_guard AS (
  SELECT to_regprocedure('public.prevent_profile_role_escalation()') AS oid
),
signup_function AS (
  SELECT to_regprocedure('public.handle_new_user()') AS oid
),
review_function AS (
  SELECT to_regprocedure('public.review_ngo_application(uuid,uuid,text,text)') AS oid
),
expected_role_guard(body) AS (
  VALUES ($expected$
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
$expected$::text)
),
expected_signup(body) AS (
  VALUES ($expected$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$expected$::text)
),
profile_role_counts_xml AS (
  SELECT CASE WHEN p.oid IS NOT NULL AND EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid=p.oid
      AND a.attname='role' AND a.attnum>0 AND NOT a.attisdropped
  ) THEN pg_catalog.query_to_xml(
    'SELECT CASE WHEN role IS NULL THEN ''[NULL]'' WHEN role IN (''user'',''ngo'') THEN role::text ELSE ''[UNSUPPORTED]'' END AS role_category, count(*)::bigint AS row_count, false AS empty_marker FROM public.profiles GROUP BY CASE WHEN role IS NULL THEN ''[NULL]'' WHEN role IN (''user'',''ngo'') THEN role::text ELSE ''[UNSUPPORTED]'' END UNION ALL SELECT NULL::text AS role_category, 0::bigint AS row_count, true AS empty_marker WHERE NOT EXISTS (SELECT 1 FROM public.profiles)',
    true, false, ''
  ) ELSE NULL::xml END AS payload
  FROM profiles p
),
role_count_rows AS (
  SELECT x.role_category, x.row_count, x.empty_marker
  FROM profile_role_counts_xml p
  CROSS JOIN LATERAL XMLTABLE(
    '/table/row' PASSING p.payload
    COLUMNS role_category text PATH 'role_category',
            row_count bigint PATH 'row_count',
            empty_marker boolean PATH 'empty_marker'
  ) AS x
),
function_specs(label, signature) AS (
  VALUES ('prevent_profile_role_escalation'::text,
          'public.prevent_profile_role_escalation()'::text),
         ('handle_new_user'::text,'public.handle_new_user()'::text),
         ('submit_ngo_application'::text,
          'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'::text),
         ('review_ngo_application'::text,
          'public.review_ngo_application(uuid,uuid,text,text)'::text),
         ('get_ngo_dashboard_stats'::text,'public.get_ngo_dashboard_stats()'::text)
),
function_oids AS (
  SELECT s.label,s.signature,to_regprocedure(s.signature) AS oid
  FROM function_specs s
),
relations(label, oid) AS (
  VALUES ('public.profiles'::text,to_regclass('public.profiles')),
         ('auth.users'::text,to_regclass('auth.users')),
         ('public.user_roles'::text,to_regclass('public.user_roles')),
         ('public.ngo_applications'::text,to_regclass('public.ngo_applications')),
         ('public.admin_audit_log'::text,to_regclass('public.admin_audit_log'))
),
items(section_order,section,item,status,details) AS (
  -- Current session identity and executor permissions.
  SELECT 10,'Execution identity','session_and_current_user','OBSERVED',
    jsonb_build_object('session_user',session_user::text,'current_user',current_user::text,
      'session_user_exists',sr.oid IS NOT NULL,'session_user_is_superuser',sr.rolsuper,
      'current_user_exists',cr.oid IS NOT NULL,'current_user_is_superuser',cr.rolsuper,
      'public_schema_exists',to_regnamespace('public') IS NOT NULL,
      'current_user_public_usage',CASE WHEN to_regnamespace('public') IS NULL THEN NULL
        ELSE has_schema_privilege(current_user::text,'public','USAGE') END,
      'current_user_public_create',CASE WHEN to_regnamespace('public') IS NULL THEN NULL
        ELSE has_schema_privilege(current_user::text,'public','CREATE') END)
  FROM (SELECT oid,rolsuper FROM role_rows WHERE role_name=session_user::text) sr
  CROSS JOIN (SELECT oid,rolsuper FROM role_rows WHERE role_name=current_user::text) cr

  UNION ALL
  SELECT 11,'Role attributes',r.role_name,
    CASE WHEN r.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
    CASE WHEN r.oid IS NULL THEN jsonb_build_object('role_exists',false)
    ELSE jsonb_build_object('role_exists',true,'rolsuper',r.rolsuper,
      'rolinherit',r.rolinherit,'rolbypassrls',r.rolbypassrls,
      'rolcanlogin',r.rolcanlogin,'rolcreaterole',r.rolcreaterole,
      'rolcreatedb',r.rolcreatedb,'rolreplication',r.rolreplication) END
  FROM role_rows r

  UNION ALL
  SELECT 20,'Profile role-protection function','public.prevent_profile_role_escalation()',
    CASE WHEN p.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
    CASE WHEN p.oid IS NULL THEN jsonb_build_object('function_exists',false)
    ELSE jsonb_build_object('function_exists',true,'owner',pg_catalog.pg_get_userbyid(p.proowner),
      'language',l.lanname,'security_definer',p.prosecdef,'security_mode',
      CASE WHEN p.prosecdef THEN 'DEFINER' ELSE 'INVOKER' END,
      'search_path_configuration',p.proconfig,'body',p.prosrc,
      'body_matches_october_18_source_after_outer_trim',
        btrim(p.prosrc)=btrim(e.body),
      'direct_execute_acl_explicit',p.proacl IS NOT NULL,
      'direct_execute_acl',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'grantee',CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(a.grantee) END,
        'grantor',pg_catalog.pg_get_userbyid(a.grantor),'privilege',a.privilege_type,
        'grant_option',a.is_grantable) ORDER BY a.grantee,a.privilege_type,a.grantor)
        FROM pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) a),'[]'::jsonb)) END
  FROM role_guard rg LEFT JOIN pg_catalog.pg_proc p ON p.oid=rg.oid
  LEFT JOIN pg_catalog.pg_language l ON l.oid=p.prolang CROSS JOIN expected_role_guard e

  UNION ALL
  SELECT 21,'Profile role-protection effective EXECUTE',r.role_name,
    CASE WHEN rg.oid IS NULL OR r.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
    jsonb_build_object('function_exists',rg.oid IS NOT NULL,'role_exists',r.oid IS NOT NULL,
      'can_execute',CASE WHEN rg.oid IS NULL OR r.oid IS NULL THEN NULL
                         ELSE has_function_privilege(r.oid,rg.oid,'EXECUTE') END)
  FROM role_rows r CROSS JOIN role_guard rg

  UNION ALL
  SELECT 22,'public.profiles triggers',
    COALESCE(t.tgname,'no non-internal trigger'),
    CASE WHEN pr.oid IS NULL THEN 'UNKNOWN' WHEN t.oid IS NULL THEN 'EMPTY' ELSE 'PRESENT' END,
    CASE WHEN pr.oid IS NULL THEN jsonb_build_object('profiles_exists',false,'trigger',NULL)
    WHEN t.oid IS NULL THEN jsonb_build_object('profiles_exists',true,'trigger',NULL)
    ELSE jsonb_build_object('profiles_exists',true,'name',t.tgname,
      'definition',pg_catalog.pg_get_triggerdef(t.oid,true),'trigger_type_bits',t.tgtype,
      'enabled_code',t.tgenabled::text,'internal',t.tgisinternal,
      'constraint_oid',t.tgconstraint,'deferrable',t.tgdeferrable,
      'initially_deferred',t.tginitdeferred,'when_condition_is_null',t.tgqual IS NULL,
      'function',t.tgfoid::regprocedure::text,'function_owner',pg_catalog.pg_get_userbyid(p.proowner),
      'expected_guard_name',t.tgname='prevent_profile_role_escalation',
      'expected_function_binding',t.tgfoid=rg.oid,
      'expected_before_row_update_role',t.tgtype=19 AND t.tgattr::text<>
        '' AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid=pr.oid
          AND a.attname='role' AND a.attnum>0 AND NOT a.attisdropped
          AND a.attnum::text = ANY (string_to_array(t.tgattr::text,' ')))) END
  FROM profiles pr CROSS JOIN role_guard rg
  LEFT JOIN pg_catalog.pg_trigger t ON t.tgrelid=pr.oid AND NOT t.tgisinternal
  LEFT JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
  UNION ALL
  SELECT 23,'Profile role-protection trigger summary','expected_trigger_count',
    CASE WHEN pr.oid IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,
    jsonb_build_object('profiles_exists',pr.oid IS NOT NULL,
      'expected_named_trigger_count',CASE WHEN pr.oid IS NULL THEN NULL ELSE
        (SELECT count(*) FROM pg_catalog.pg_trigger t WHERE t.tgrelid=pr.oid
          AND t.tgname='prevent_profile_role_escalation' AND NOT t.tgisinternal) END,
      'all_non_internal_trigger_count',CASE WHEN pr.oid IS NULL THEN NULL ELSE
        (SELECT count(*) FROM pg_catalog.pg_trigger t WHERE t.tgrelid=pr.oid AND NOT t.tgisinternal) END)
  FROM profiles pr

  UNION ALL
  SELECT 30,'Profile role schema','public.profiles.role',
    CASE WHEN pr.oid IS NULL THEN 'UNKNOWN' WHEN a.attnum IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
    CASE WHEN pr.oid IS NULL OR a.attnum IS NULL THEN jsonb_build_object(
      'profiles_exists',pr.oid IS NOT NULL,'role_column_exists',a.attnum IS NOT NULL)
    ELSE jsonb_build_object('table_owner',pg_catalog.pg_get_userbyid(c.relowner),
      'rls_enabled',c.relrowsecurity,'rls_forced',c.relforcerowsecurity,
      'role_type',pg_catalog.format_type(a.atttypid,a.atttypmod),
      'role_not_null',a.attnotnull,'role_default',pg_catalog.pg_get_expr(d.adbin,d.adrelid),
      'profiles_role_allowed_values_constraint_exists',EXISTS (SELECT 1 FROM pg_catalog.pg_constraint co
        WHERE co.conrelid=pr.oid AND co.conname='profiles_role_allowed_values'),
      'role_related_check_constraints',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'name',co.conname::text,'validated',co.convalidated,
        'definition',pg_catalog.pg_get_constraintdef(co.oid,true)) ORDER BY co.conname)
        FROM pg_catalog.pg_constraint co WHERE co.conrelid=pr.oid AND co.contype='c'
          AND (co.conname ILIKE '%role%' OR pg_catalog.pg_get_constraintdef(co.oid,true) ILIKE '%role%')),'[]'::jsonb),
      'role_counts_available',true,
      'role_counts',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'role_category',rc.role_category,'row_count',rc.row_count,'empty_marker',rc.empty_marker)
        ORDER BY rc.empty_marker,rc.role_category NULLS FIRST) FROM role_count_rows rc),'[]'::jsonb)) END
  FROM profiles pr LEFT JOIN pg_catalog.pg_class c ON c.oid=pr.oid
  LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=pr.oid AND a.attname='role'
    AND a.attnum>0 AND NOT a.attisdropped
  LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum

  UNION ALL
  SELECT 31,'Profile INSERT policy',COALESCE(pol.polname,'no INSERT policy'),
    CASE WHEN pr.oid IS NULL THEN 'UNKNOWN' WHEN pol.oid IS NULL THEN 'EMPTY' ELSE 'PRESENT' END,
    CASE WHEN pr.oid IS NULL THEN jsonb_build_object('profiles_exists',false,'policy',NULL)
    WHEN pol.oid IS NULL THEN jsonb_build_object('profiles_exists',true,'policy',NULL)
    ELSE jsonb_build_object('policy',pol.polname,'permissive',pol.polpermissive,
      'roles',ARRAY(SELECT CASE WHEN x=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(x) END
        FROM unnest(pol.polroles) q(x) ORDER BY x),'command',pol.polcmd::text,
      'using',pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),
      'with_check',pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid)) END
  FROM profiles pr LEFT JOIN pg_catalog.pg_policy pol ON pol.polrelid=pr.oid AND pol.polcmd IN ('a','*')
  UNION ALL
  SELECT 32,'Profile INSERT authority',r.role_name,
    CASE WHEN pr.oid IS NULL OR r.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
    CASE WHEN pr.oid IS NULL OR r.oid IS NULL THEN jsonb_build_object(
      'profiles_exists',pr.oid IS NOT NULL,'role_exists',r.oid IS NOT NULL,
      'table_insert',NULL,'rls_enabled',NULL)
    ELSE jsonb_build_object('role_exists',true,'schema_usage',
        CASE WHEN to_regnamespace('public') IS NULL THEN NULL ELSE has_schema_privilege(r.oid,'public','USAGE') END,
      'table_insert',has_table_privilege(r.oid,pr.oid,'INSERT'),
      'id_column_insert',CASE WHEN idc.attnum IS NULL THEN NULL ELSE has_column_privilege(r.oid,pr.oid,'id','INSERT') END,
      'full_name_column_insert',CASE WHEN fnc.attnum IS NULL THEN NULL ELSE has_column_privilege(r.oid,pr.oid,'full_name','INSERT') END,
      'role_column_insert',CASE WHEN rc.attnum IS NULL THEN NULL ELSE has_column_privilege(r.oid,pr.oid,'role','INSERT') END,
      'rls_enabled',c.relrowsecurity,'rls_forced',c.relforcerowsecurity,
      'is_table_owner',c.relowner=r.oid,'is_superuser',r.rolsuper,'bypassrls',r.rolbypassrls,
      'note','Privilege and RLS policy evidence; no INSERT is attempted') END
  FROM profiles pr CROSS JOIN role_rows r
  LEFT JOIN pg_catalog.pg_class c ON c.oid=pr.oid
  LEFT JOIN pg_catalog.pg_attribute idc ON idc.attrelid=pr.oid AND idc.attname='id' AND idc.attnum>0 AND NOT idc.attisdropped
  LEFT JOIN pg_catalog.pg_attribute fnc ON fnc.attrelid=pr.oid AND fnc.attname='full_name' AND fnc.attnum>0 AND NOT fnc.attisdropped
  LEFT JOIN pg_catalog.pg_attribute rc ON rc.attrelid=pr.oid AND rc.attname='role' AND rc.attnum>0 AND NOT rc.attisdropped

  UNION ALL
  SELECT 33,'user_roles effective privileges',r.role_name,
    CASE WHEN ur.oid IS NULL OR r.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
    CASE WHEN ur.oid IS NULL OR r.oid IS NULL THEN jsonb_build_object(
      'user_roles_exists',ur.oid IS NOT NULL,'role_exists',r.oid IS NOT NULL,'privileges',NULL)
    ELSE jsonb_build_object('user_roles_exists',true,'role_exists',true,
      'schema_usage',CASE WHEN to_regnamespace('public') IS NULL THEN NULL
        ELSE has_schema_privilege(r.oid,'public','USAGE') END,
      'select',has_table_privilege(r.oid,ur.oid,'SELECT'),
      'insert',has_table_privilege(r.oid,ur.oid,'INSERT'),
      'update',has_table_privilege(r.oid,ur.oid,'UPDATE'),
      'delete',has_table_privilege(r.oid,ur.oid,'DELETE'),
      'rls_enabled',c.relrowsecurity,'rls_forced',c.relforcerowsecurity,
      'is_owner',c.relowner=r.oid,'is_superuser',r.rolsuper,'bypassrls',r.rolbypassrls) END
  FROM (SELECT to_regclass('public.user_roles') AS oid) ur
  CROSS JOIN role_rows r LEFT JOIN pg_catalog.pg_class c ON c.oid=ur.oid

  UNION ALL
  SELECT 34,'user_roles SQL Editor INSERT privilege evidence',i.identity_name,
    CASE WHEN ur.oid IS NULL OR rr.oid IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,
    jsonb_build_object('user_roles_exists',ur.oid IS NOT NULL,
      'identity',i.identity_name,'role_exists',rr.oid IS NOT NULL,
      'is_superuser',rr.rolsuper,'is_table_owner',CASE WHEN ur.oid IS NULL OR rr.oid IS NULL THEN NULL ELSE c.relowner=rr.oid END,
      'public_schema_usage',CASE WHEN to_regnamespace('public') IS NULL OR rr.oid IS NULL THEN NULL
        ELSE has_schema_privilege(rr.oid,'public','USAGE') END,
      'table_insert',CASE WHEN ur.oid IS NULL OR rr.oid IS NULL THEN NULL
        ELSE has_table_privilege(rr.oid,ur.oid,'INSERT') END,
      'user_id_column_insert',CASE WHEN idc.attnum IS NULL OR rr.oid IS NULL THEN NULL
        ELSE has_column_privilege(rr.oid,ur.oid,'user_id','INSERT') END,
      'role_column_insert',CASE WHEN rolec.attnum IS NULL OR rr.oid IS NULL THEN NULL
        ELSE has_column_privilege(rr.oid,ur.oid,'role','INSERT') END,
      'rls_enabled',c.relrowsecurity,'rls_forced',c.relforcerowsecurity,
      'note','Reports privileges and RLS metadata only; no role row is inserted')
  FROM (VALUES ('session_user'::text,session_user::text),('current_user'::text,current_user::text)) i(identity_name,role_name)
  LEFT JOIN role_rows rr ON rr.role_name=i.role_name
  CROSS JOIN (SELECT to_regclass('public.user_roles') AS oid) ur
  LEFT JOIN pg_catalog.pg_class c ON c.oid=ur.oid
  LEFT JOIN pg_catalog.pg_attribute idc ON idc.attrelid=ur.oid AND idc.attname='user_id' AND idc.attnum>0 AND NOT idc.attisdropped
  LEFT JOIN pg_catalog.pg_attribute rolec ON rolec.attrelid=ur.oid AND rolec.attname='role' AND rolec.attnum>0 AND NOT rolec.attisdropped

  UNION ALL
  SELECT 40,'Auth signup function','public.handle_new_user()',
    CASE WHEN f.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
    CASE WHEN f.oid IS NULL THEN jsonb_build_object('function_exists',false,'signature','public.handle_new_user()')
    ELSE jsonb_build_object('function_exists',true,'owner',pg_catalog.pg_get_userbyid(p.proowner),
      'language',l.lanname,'security_definer',p.prosecdef,'security_mode',
        CASE WHEN p.prosecdef THEN 'DEFINER' ELSE 'INVOKER' END,
      'search_path_configuration',p.proconfig,'body',p.prosrc,
      'body_matches_expected_hardened_signup_after_outer_trim',btrim(p.prosrc)=btrim(e.body),
      'direct_execute_acl_explicit',p.proacl IS NOT NULL,
      'direct_execute_acl',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'grantee',CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(x.grantee) END,
        'grantor',pg_catalog.pg_get_userbyid(x.grantor),'privilege',x.privilege_type,
        'grant_option',x.is_grantable) ORDER BY x.grantee,x.privilege_type,x.grantor)
        FROM pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) x),'[]'::jsonb),
      'owner_public_usage',has_schema_privilege(p.proowner,'public','USAGE'),
      'owner_profiles_id_insert',CASE WHEN to_regclass('public.profiles') IS NULL THEN NULL
        ELSE has_column_privilege(p.proowner,'public.profiles','id','INSERT') END,
      'owner_profiles_full_name_insert',CASE WHEN to_regclass('public.profiles') IS NULL THEN NULL
        ELSE has_column_privilege(p.proowner,'public.profiles','full_name','INSERT') END,
      'auth_schema_exists',to_regnamespace('auth') IS NOT NULL,
      'owner_auth_usage',CASE WHEN to_regnamespace('auth') IS NULL THEN NULL
        ELSE has_schema_privilege(p.proowner,'auth','USAGE') END,
      'auth_role_function_exists',to_regprocedure('auth.role()') IS NOT NULL,
      'owner_can_execute_auth_role',CASE WHEN to_regprocedure('auth.role()') IS NULL THEN NULL
        ELSE has_function_privilege(p.proowner,to_regprocedure('auth.role()'),'EXECUTE') END) END
  FROM signup_function f CROSS JOIN expected_signup e
  LEFT JOIN pg_catalog.pg_proc p ON p.oid=f.oid
  LEFT JOIN pg_catalog.pg_language l ON l.oid=p.prolang

  UNION ALL
  SELECT 41,'Auth users triggers',COALESCE(t.tgname,'no non-internal trigger'),
    CASE WHEN au.oid IS NULL THEN 'UNKNOWN' WHEN t.oid IS NULL THEN 'EMPTY' ELSE 'PRESENT' END,
    CASE WHEN au.oid IS NULL THEN jsonb_build_object('auth_users_exists',false,'trigger',NULL)
    WHEN t.oid IS NULL THEN jsonb_build_object('auth_users_exists',true,'trigger',NULL)
    ELSE jsonb_build_object('name',t.tgname,'definition',pg_catalog.pg_get_triggerdef(t.oid,true),
      'trigger_type_bits',t.tgtype,'enabled_code',t.tgenabled::text,'internal',t.tgisinternal,
      'constraint_oid',t.tgconstraint,'deferrable',t.tgdeferrable,'initially_deferred',t.tginitdeferred,
      'when_condition_is_null',t.tgqual IS NULL,'function',t.tgfoid::regprocedure::text,
      'function_owner',pg_catalog.pg_get_userbyid(p.proowner),'function_security_definer',p.prosecdef,
      'function_search_path_configuration',p.proconfig,
      'matches_expected_auth_signup_trigger',t.tgname='on_auth_user_created'
        AND t.tgfoid=sf.oid AND t.tgtype=5 AND t.tgconstraint=0
        AND NOT t.tgdeferrable AND NOT t.tginitdeferred AND t.tgenabled IN ('O','A')) END
  FROM (SELECT to_regclass('auth.users') AS oid) au CROSS JOIN signup_function sf
  LEFT JOIN pg_catalog.pg_trigger t ON t.tgrelid=au.oid AND NOT t.tgisinternal
  LEFT JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid

  UNION ALL
  SELECT 50,'Workflow relation collision',r.label,
    CASE WHEN r.oid IS NULL THEN 'ABSENT' ELSE 'PRESENT' END,
    CASE WHEN r.oid IS NULL THEN jsonb_build_object('exists',false)
    ELSE jsonb_build_object('exists',true,'owner',pg_catalog.pg_get_userbyid(c.relowner),
      'kind',c.relkind::text,'rls_enabled',c.relrowsecurity,'rls_forced',c.relforcerowsecurity,
      'columns',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',a.attname::text,
        'type',pg_catalog.format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull) ORDER BY a.attnum)
        FROM pg_catalog.pg_attribute a WHERE a.attrelid=r.oid AND a.attnum>0 AND NOT a.attisdropped),'[]'::jsonb),
      'constraints',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',co.conname::text,
        'type',co.contype::text,'definition',pg_catalog.pg_get_constraintdef(co.oid,true)) ORDER BY co.conname)
        FROM pg_catalog.pg_constraint co WHERE co.conrelid=r.oid),'[]'::jsonb),
      'indexes',COALESCE((SELECT jsonb_agg(pg_catalog.pg_get_indexdef(i.indexrelid) ORDER BY ic.relname)
        FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class ic ON ic.oid=i.indexrelid
        WHERE i.indrelid=r.oid),'[]'::jsonb),
      'policies',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',pol.polname::text,
        'command',pol.polcmd::text,'permissive',pol.polpermissive,
        'roles',ARRAY(SELECT CASE WHEN x=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(x) END
          FROM unnest(pol.polroles) q(x) ORDER BY x),
        'using',pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),
        'with_check',pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid)) ORDER BY pol.polname)
        FROM pg_catalog.pg_policy pol WHERE pol.polrelid=r.oid),'[]'::jsonb),
      'direct_acl',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'grantee',CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(x.grantee) END,
        'grantor',pg_catalog.pg_get_userbyid(x.grantor),'privilege',x.privilege_type,
        'grant_option',x.is_grantable) ORDER BY x.grantee,x.privilege_type,x.grantor)
        FROM pg_catalog.aclexplode(COALESCE(c.relacl,pg_catalog.acldefault('r',c.relowner))) x),'[]'::jsonb),
      'effective_privileges_by_role',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'role',rr.role_name,'role_exists',rr.oid IS NOT NULL,
        'select',CASE WHEN rr.oid IS NULL THEN NULL ELSE has_table_privilege(rr.oid,c.oid,'SELECT') END,
        'insert',CASE WHEN rr.oid IS NULL THEN NULL ELSE has_table_privilege(rr.oid,c.oid,'INSERT') END,
        'update',CASE WHEN rr.oid IS NULL THEN NULL ELSE has_table_privilege(rr.oid,c.oid,'UPDATE') END,
        'delete',CASE WHEN rr.oid IS NULL THEN NULL ELSE has_table_privilege(rr.oid,c.oid,'DELETE') END)
        ORDER BY rr.role_name) FROM role_rows rr),'[]'::jsonb)) END
  FROM relations r LEFT JOIN pg_catalog.pg_class c ON c.oid=r.oid

  UNION ALL
  SELECT 51,'Workflow index collision',i.index_name,
    CASE WHEN c.oid IS NULL THEN 'ABSENT' ELSE 'PRESENT' END,
    jsonb_build_object('exists',c.oid IS NOT NULL,
      'definition',CASE WHEN c.oid IS NULL THEN NULL ELSE pg_catalog.pg_get_indexdef(c.oid) END)
  FROM (VALUES ('ngo_applications_status_created_idx'::text),
               ('ngo_applications_registration_idx'::text),
               ('ngo_applications_one_pending_per_user_idx'::text),
               ('admin_audit_log_application_idx'::text)) i(index_name)
  LEFT JOIN pg_catalog.pg_class c ON c.relname=i.index_name

  UNION ALL
  SELECT 52,'Workflow function collision',f.label,
    CASE WHEN f.oid IS NULL THEN 'ABSENT' ELSE 'PRESENT' END,
    CASE WHEN f.oid IS NULL THEN jsonb_build_object('exists',false,'signature',f.signature)
    ELSE jsonb_build_object('exists',true,'signature',f.signature,
      'owner',pg_catalog.pg_get_userbyid(p.proowner),'language',l.lanname,
      'security_definer',p.prosecdef,'configuration',p.proconfig,
      'definition',pg_catalog.pg_get_functiondef(p.oid),
      'direct_acl',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'grantee',CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(x.grantee) END,
        'grantor',pg_catalog.pg_get_userbyid(x.grantor),'privilege',x.privilege_type,
        'grant_option',x.is_grantable) ORDER BY x.grantee,x.privilege_type,x.grantor)
        FROM pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) x),'[]'::jsonb)) END
  FROM function_oids f LEFT JOIN pg_catalog.pg_proc p ON p.oid=f.oid
  LEFT JOIN pg_catalog.pg_language l ON l.oid=p.prolang
  WHERE f.label IN ('submit_ngo_application','review_ngo_application','get_ngo_dashboard_stats')

  UNION ALL
  SELECT 53,'Relevant workflow function effective EXECUTE',f.label||' / '||r.role_name,
    CASE WHEN f.oid IS NULL OR r.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
    jsonb_build_object('function_exists',f.oid IS NOT NULL,'role_exists',r.oid IS NOT NULL,
      'can_execute',CASE WHEN f.oid IS NULL OR r.oid IS NULL THEN NULL
                         ELSE has_function_privilege(r.oid,f.oid,'EXECUTE') END)
  FROM function_oids f CROSS JOIN role_rows r

  UNION ALL
  SELECT 60,'Migration 4 runner precondition','review_ngo_application',
    CASE WHEN to_regclass('public.user_roles') IS NULL
           OR to_regclass('public.ngo_applications') IS NULL
           OR to_regclass('public.profiles') IS NULL
           OR to_regclass('public.admin_audit_log') IS NULL
           THEN 'BLOCKED_MISSING_OBJECTS'
         WHEN rf.oid IS NULL THEN 'BLOCKED_MISSING_FUNCTION'
         WHEN NOT p.prosecdef OR l.lanname IS DISTINCT FROM 'plpgsql'
           OR p.prorettype <> 'pg_catalog.void'::regtype
           OR p.proconfig IS DISTINCT FROM ARRAY['search_path=""']::text[]
           THEN 'PRECONDITION_FAIL'
         WHEN NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
           WHERE a.attrelid=to_regclass('public.ngo_applications')
             AND a.attname='applicant_user_id' AND a.attnum>0 AND NOT a.attisdropped)
           THEN 'PRECONDITION_FAIL'
         WHEN NOT (COALESCE((SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname=current_user),false)
                   OR p.proowner=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user))
           THEN 'PRECONDITION_FAIL'
         ELSE 'PRECONDITIONS_OBSERVED' END,
    jsonb_build_object('function_exists',rf.oid IS NOT NULL,
      'required_objects_exist',to_regclass('public.user_roles') IS NOT NULL
        AND to_regclass('public.ngo_applications') IS NOT NULL
        AND to_regclass('public.profiles') IS NOT NULL
        AND to_regclass('public.admin_audit_log') IS NOT NULL,
      'runner_current_user',current_user::text,
      'runner_is_superuser',(SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname=current_user),
      'runner_owns_review_function',CASE WHEN rf.oid IS NULL THEN NULL ELSE p.proowner=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user) END,
      'review_is_security_definer',p.prosecdef,'review_language',l.lanname,
      'review_return_type',CASE WHEN p.oid IS NULL THEN NULL ELSE pg_catalog.format_type(p.prorettype,NULL) END,
      'review_configuration',p.proconfig,
      'applicant_user_id_exists',CASE WHEN to_regclass('public.ngo_applications') IS NULL THEN NULL ELSE EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid=to_regclass('public.ngo_applications')
          AND a.attname='applicant_user_id' AND a.attnum>0 AND NOT a.attisdropped) END)
  FROM review_function rf LEFT JOIN pg_catalog.pg_proc p ON p.oid=rf.oid
  LEFT JOIN pg_catalog.pg_language l ON l.oid=p.prolang

  UNION ALL
  SELECT 61,'Migration 3 schema authority','public',
    CASE WHEN to_regnamespace('public') IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,
    jsonb_build_object('schema_exists',to_regnamespace('public') IS NOT NULL,
      'schema_owner',CASE WHEN n.oid IS NULL THEN NULL ELSE pg_catalog.pg_get_userbyid(n.nspowner) END,
      'current_user_usage',CASE WHEN n.oid IS NULL THEN NULL ELSE has_schema_privilege(current_user,n.oid,'USAGE') END,
      'current_user_create',CASE WHEN n.oid IS NULL THEN NULL ELSE has_schema_privilege(current_user,n.oid,'CREATE') END,
      'profiles_exists',pr.oid IS NOT NULL,
      'current_user_profiles_references',CASE WHEN pr.oid IS NULL THEN NULL ELSE has_table_privilege(current_user,pr.oid,'REFERENCES') END)
  FROM (SELECT to_regnamespace('public') AS oid) ns
  LEFT JOIN pg_catalog.pg_namespace n ON n.oid=ns.oid
  CROSS JOIN profiles pr

  UNION ALL
  SELECT 62,'Existing profile and Auth object owners',r.label,
    CASE WHEN r.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
    CASE WHEN r.oid IS NULL THEN jsonb_build_object('relation_exists',false)
    ELSE jsonb_build_object('relation_exists',true,'owner',pg_catalog.pg_get_userbyid(c.relowner),
      'current_user_is_owner',c.relowner=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user),
      'current_user_is_superuser',(SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname=current_user)) END
  FROM relations r LEFT JOIN pg_catalog.pg_class c ON c.oid=r.oid
  WHERE r.label IN ('public.profiles','auth.users')

  UNION ALL
  SELECT 63,'Existing relevant function owners',f.label,
    CASE WHEN f.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
    CASE WHEN f.oid IS NULL THEN jsonb_build_object('function_exists',false)
    ELSE jsonb_build_object('owner',pg_catalog.pg_get_userbyid(p.proowner),
      'current_user_is_owner',p.proowner=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user),
      'current_user_is_superuser',(SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname=current_user)) END
  FROM function_oids f LEFT JOIN pg_catalog.pg_proc p ON p.oid=f.oid
)
SELECT section,item,status,details
FROM items
ORDER BY section_order,section,item;
