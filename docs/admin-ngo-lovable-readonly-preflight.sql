-- AI HealthBot Admin/NGO read-only deployment preflight.
-- Run as project owner in Lovable Cloud -> View Backend -> SQL Editor.
-- One SELECT statement returns one result set and one statement snapshot.
-- No application rows, credentials, password hashes, or secrets are queried.
-- A failed/incomplete/truncated result is UNKNOWN; do not proceed on that basis.

WITH
expected_migrations(version) AS (
  VALUES ('20261018213000'::text), ('20261018220000'::text),
         ('20261019090000'::text), ('20261101120000'::text)
),
ledger_meta AS (
  SELECT to_regclass('supabase_migrations.schema_migrations') AS relid,
         EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = to_regclass('supabase_migrations.schema_migrations')
                   AND a.attname = 'version' AND a.attnum > 0 AND NOT a.attisdropped) AS has_version,
         EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = to_regclass('supabase_migrations.schema_migrations')
                   AND a.attname = 'name' AND a.attnum > 0 AND NOT a.attisdropped) AS has_name
),
ledger_xml AS (
  SELECT lm.*,
    CASE WHEN lm.relid IS NOT NULL AND lm.has_version THEN
      pg_catalog.query_to_xml(
        pg_catalog.format(
          'SELECT version::text AS version, %s AS migration_name FROM supabase_migrations.schema_migrations WHERE version::text = ANY (ARRAY[''20261018213000'', ''20261018220000'', ''20261019090000'', ''20261101120000'']::text[]) ORDER BY version::text',
          CASE WHEN lm.has_name THEN 'name::text' ELSE 'NULL::text' END
        ), true, false, ''
      )
    ELSE NULL::xml END AS entries_xml
  FROM ledger_meta lm
),
ledger_entries AS (
  SELECT x.version, x.migration_name
  FROM ledger_xml lx
  CROSS JOIN LATERAL XMLTABLE(
    '/table/row' PASSING lx.entries_xml
    COLUMNS version text PATH 'version', migration_name text PATH 'migration_name'
  ) AS x
),
expected_roles(role_name) AS (
  VALUES ('anon'::text), ('authenticated'::text), ('service_role'::text),
         ('postgres'::text), ('supabase_admin'::text),
         (session_user::text), (current_user::text)
),
role_rows AS (
  SELECT DISTINCT e.role_name, r.oid, r.rolsuper, r.rolinherit, r.rolbypassrls,
         r.rolcanlogin, r.rolcreaterole, r.rolcreatedb, r.rolreplication
  FROM expected_roles e
  LEFT JOIN pg_catalog.pg_roles r ON r.rolname::text = e.role_name
),
relation_specs(relation_name, relid) AS (
  VALUES ('public.user_roles'::text, to_regclass('public.user_roles')),
         ('public.ngo_applications'::text, to_regclass('public.ngo_applications')),
         ('public.admin_audit_log'::text, to_regclass('public.admin_audit_log')),
         ('public.profiles'::text, to_regclass('public.profiles'))
),
function_specs(function_name, signature) AS (
  VALUES ('public.submit_ngo_application'::text,
          'public.submit_ngo_application(uuid,text,text,text,text,text,jsonb)'::text),
         ('public.review_ngo_application'::text,
          'public.review_ngo_application(uuid,uuid,text,text)'::text),
         ('public.handle_new_user'::text,
          'public.handle_new_user()'::text),
         ('public.prevent_profile_role_escalation'::text,
          'public.prevent_profile_role_escalation()'::text),
         ('public.get_ngo_dashboard_stats'::text,
          'public.get_ngo_dashboard_stats()'::text)
),
function_rows AS (
  SELECT s.function_name, s.signature, to_regprocedure(s.signature) AS oid
  FROM function_specs s
),
privilege_roles AS (
  SELECT DISTINCT r.oid, r.rolname::text AS role_name
  FROM pg_catalog.pg_roles r
  WHERE r.rolname::text IN ('anon','authenticated','service_role','postgres',
                            'supabase_admin',session_user::text,current_user::text)
     OR r.oid IN (SELECT c.relowner FROM pg_catalog.pg_class c
                  WHERE c.oid IN (SELECT relid FROM relation_specs WHERE relid IS NOT NULL))
     OR r.oid IN (SELECT p.proowner FROM pg_catalog.pg_proc p
                  WHERE p.oid IN (SELECT oid FROM function_rows WHERE oid IS NOT NULL))
),
evidence(section_order, section, item, status, details) AS (
  -- Migration ledger rows. query_to_xml runs only a fixed SELECT and only if
  -- the ledger and version column exist; it performs no writes.
  SELECT 10, 'Migration history', 'ledger_relation',
         CASE WHEN lm.relid IS NULL OR NOT lm.has_version THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
         jsonb_build_object('relation_exists', lm.relid IS NOT NULL,
           'version_column_exists', lm.has_version, 'name_column_exists', lm.has_name,
           'note', CASE WHEN lm.relid IS NULL THEN 'Ledger relation is missing'
                        WHEN NOT lm.has_version THEN 'Ledger version column is missing'
                        ELSE 'Only requested migration versions are selected' END)
  FROM ledger_meta lm
  UNION ALL
  SELECT 11, 'Migration history', e.version,
         CASE WHEN lm.relid IS NULL OR NOT lm.has_version THEN 'UNKNOWN'
              WHEN le.version IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
         jsonb_build_object('version',e.version,'recorded_name',le.migration_name)
  FROM expected_migrations e CROSS JOIN ledger_meta lm
  LEFT JOIN ledger_entries le ON le.version=e.version

  UNION ALL
  SELECT 20, 'Roles and execution identity', rr.role_name,
         CASE WHEN rr.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
         CASE WHEN rr.oid IS NULL THEN jsonb_build_object('role_exists',false)
              ELSE jsonb_build_object('role_exists',true,
                'is_session_user',rr.role_name=session_user::text,
                'is_current_user',rr.role_name=current_user::text,
                'rolsuper',rr.rolsuper,'rolinherit',rr.rolinherit,
                'rolbypassrls',rr.rolbypassrls,'rolcanlogin',rr.rolcanlogin,
                'rolcreaterole',rr.rolcreaterole,'rolcreatedb',rr.rolcreatedb,
                'rolreplication',rr.rolreplication) END
  FROM role_rows rr
  UNION ALL
  SELECT 21, 'Roles and execution identity', 'session_and_current_user', 'OBSERVED',
         jsonb_build_object('session_user',session_user::text,'current_user',current_user::text)

  UNION ALL
  SELECT 22, 'Database identity', current_database(), 'OBSERVED',
         jsonb_build_object('database',current_database(),
           'server_version_num',current_setting('server_version_num'),
           'server_version',version())

  UNION ALL
  SELECT 23, 'Role memberships',
         pg_catalog.format('%s -> %s',member_role.rolname,granted_role.rolname), 'PRESENT',
         jsonb_build_object('member',member_role.rolname::text,
           'granted_role',granted_role.rolname::text,
           'grantor',grantor_role.rolname::text,'admin_option',m.admin_option,
           'inherit_option',m.inherit_option,'set_option',m.set_option)
  FROM pg_catalog.pg_auth_members m
  JOIN pg_catalog.pg_roles member_role ON member_role.oid=m.member
  JOIN pg_catalog.pg_roles granted_role ON granted_role.oid=m.roleid
  JOIN pg_catalog.pg_roles grantor_role ON grantor_role.oid=m.grantor
  UNION ALL
  SELECT 24, 'Role memberships', 'no_membership_edges', 'EMPTY',
         jsonb_build_object('note','pg_auth_members contains no visible edges')
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members)

  UNION ALL
  -- Table structures include columns, defaults, constraints, indexes, RLS,
  -- and policies. Empty arrays mean none; MISSING means relation absent.
  SELECT 30, 'Relations', rs.relation_name,
         CASE WHEN c.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
         CASE WHEN c.oid IS NULL THEN jsonb_build_object('relation_exists',false)
         ELSE jsonb_build_object(
           'owner',pg_catalog.pg_get_userbyid(c.relowner),'relation_kind',c.relkind::text,
           'rls_enabled',c.relrowsecurity,'rls_forced',c.relforcerowsecurity,
           'columns',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'name',a.attname::text,'type',pg_catalog.format_type(a.atttypid,a.atttypmod),
             'not_null',a.attnotnull,'default',pg_catalog.pg_get_expr(d.adbin,d.adrelid),
             'identity',a.attidentity::text,'generated',a.attgenerated::text) ORDER BY a.attnum)
             FROM pg_catalog.pg_attribute a LEFT JOIN pg_catalog.pg_attrdef d
               ON d.adrelid=a.attrelid AND d.adnum=a.attnum
             WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),'[]'::jsonb),
           'constraints',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'name',con.conname::text,'type',con.contype::text,'validated',con.convalidated,
             'definition',pg_catalog.pg_get_constraintdef(con.oid,true)) ORDER BY con.conname)
             FROM pg_catalog.pg_constraint con WHERE con.conrelid=c.oid),'[]'::jsonb),
           'indexes',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'name',idx.relname::text,'definition',pg_catalog.pg_get_indexdef(i.indexrelid),
             'primary',i.indisprimary,'unique',i.indisunique,'valid',i.indisvalid) ORDER BY idx.relname)
             FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class idx ON idx.oid=i.indexrelid
             WHERE i.indrelid=c.oid),'[]'::jsonb),
           'policies',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'name',pol.polname::text,'command',pol.polcmd::text,'permissive',pol.polpermissive,
             'roles',ARRAY(SELECT CASE WHEN role_oid=0 THEN 'PUBLIC'
                                       ELSE pg_catalog.pg_get_userbyid(role_oid) END
                           FROM unnest(pol.polroles) AS roles(role_oid) ORDER BY role_oid),
             'using',pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),
             'with_check',pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid)) ORDER BY pol.polname)
             FROM pg_catalog.pg_policy pol WHERE pol.polrelid=c.oid),'[]'::jsonb)
         ) END
  FROM relation_specs rs LEFT JOIN pg_catalog.pg_class c ON c.oid=rs.relid

  UNION ALL
  SELECT 31, 'Direct relation ACLs', rs.relation_name,
         CASE WHEN c.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
         CASE WHEN c.oid IS NULL THEN jsonb_build_object('relation_exists',false,'acl',NULL)
         ELSE jsonb_build_object('relation_owner',pg_catalog.pg_get_userbyid(c.relowner),
           'acl_explicitly_stored',c.relacl IS NOT NULL,
           'acl_entries',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'grantee',CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
             'grantor',pg_catalog.pg_get_userbyid(acl.grantor),'privilege',acl.privilege_type,
             'grant_option',acl.is_grantable) ORDER BY acl.grantee,acl.privilege_type,acl.grantor)
             FROM pg_catalog.aclexplode(COALESCE(c.relacl,pg_catalog.acldefault('r',c.relowner))) acl),
             '[]'::jsonb)) END
  FROM relation_specs rs LEFT JOIN pg_catalog.pg_class c ON c.oid=rs.relid

  UNION ALL
  SELECT 32, 'Effective relation privileges',pg_catalog.format('%s / %s',rs.relation_name,pr.role_name),
         CASE WHEN c.oid IS NULL OR pr.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
         CASE WHEN c.oid IS NULL OR pr.oid IS NULL
              THEN jsonb_build_object('relation_exists',c.oid IS NOT NULL,'role_exists',pr.oid IS NOT NULL,'privileges',NULL)
         ELSE jsonb_build_object('owner',pg_catalog.pg_get_userbyid(c.relowner),'role',pr.role_name,
           'select',has_table_privilege(pr.oid,c.oid,'SELECT'),
           'insert',has_table_privilege(pr.oid,c.oid,'INSERT'),
           'update',has_table_privilege(pr.oid,c.oid,'UPDATE'),
           'delete',has_table_privilege(pr.oid,c.oid,'DELETE'),
           'references',has_table_privilege(pr.oid,c.oid,'REFERENCES'),
           'trigger',has_table_privilege(pr.oid,c.oid,'TRIGGER'),
           'truncate',has_table_privilege(pr.oid,c.oid,'TRUNCATE'),
           'maintain',CASE WHEN current_setting('server_version_num')::integer>=170000
                           THEN has_table_privilege(pr.oid,c.oid,'MAINTAIN') ELSE NULL END)
         END
  FROM relation_specs rs CROSS JOIN privilege_roles pr
  LEFT JOIN pg_catalog.pg_class c ON c.oid=rs.relid

  UNION ALL
  SELECT 34, 'Direct column ACLs',rs.relation_name,
         CASE WHEN c.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
         CASE WHEN c.oid IS NULL THEN jsonb_build_object('relation_exists',false,'columns',NULL)
         ELSE jsonb_build_object('columns',COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
             'column',a.attname::text,
             'acl_explicitly_stored',a.attacl IS NOT NULL,
             'direct_acl_entries',COALESCE((SELECT jsonb_agg(jsonb_build_object(
               'grantee',CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
               'grantor',pg_catalog.pg_get_userbyid(acl.grantor),'privilege',acl.privilege_type,
               'grant_option',acl.is_grantable) ORDER BY acl.grantee,acl.privilege_type,acl.grantor)
               FROM pg_catalog.aclexplode(a.attacl) acl),'[]'::jsonb),
             'note','Effective column privileges may also include table-level grants') ORDER BY a.attnum)
           FROM pg_catalog.pg_attribute a
           WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
         ),'[]'::jsonb)) END
  FROM relation_specs rs LEFT JOIN pg_catalog.pg_class c ON c.oid=rs.relid

  UNION ALL
  SELECT 35, 'Effective user_roles.role column privileges',pr.role_name,
         CASE WHEN c.oid IS NULL OR a.attnum IS NULL OR pr.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
         CASE WHEN c.oid IS NULL OR a.attnum IS NULL OR pr.oid IS NULL
              THEN jsonb_build_object('table_exists',c.oid IS NOT NULL,'column_exists',a.attnum IS NOT NULL,
                                      'role_exists',pr.oid IS NOT NULL,'privileges',NULL)
         ELSE jsonb_build_object(
           'select',has_column_privilege(pr.oid,c.oid,a.attname,'SELECT'),
           'insert',has_column_privilege(pr.oid,c.oid,a.attname,'INSERT'),
           'update',has_column_privilege(pr.oid,c.oid,a.attname,'UPDATE'),
           'references',has_column_privilege(pr.oid,c.oid,a.attname,'REFERENCES')) END
  FROM privilege_roles pr
  LEFT JOIN pg_catalog.pg_class c ON c.oid=to_regclass('public.user_roles')
  LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attname='role'
    AND a.attnum>0 AND NOT a.attisdropped

  UNION ALL
  SELECT 33, 'Admin SQL Editor INSERT privilege evidence','session_and_current_user',
         CASE WHEN c.oid IS NULL THEN 'UNKNOWN' ELSE 'OBSERVED' END,
         jsonb_build_object('relation_exists',c.oid IS NOT NULL,
           'table_owner',CASE WHEN c.oid IS NULL THEN NULL ELSE pg_catalog.pg_get_userbyid(c.relowner) END,
           'public_schema_exists',to_regnamespace('public') IS NOT NULL,
           'session_user',session_user::text,
           'session_user_is_superuser',(SELECT r.rolsuper FROM pg_catalog.pg_roles r WHERE r.rolname=session_user),
           'session_user_has_public_usage',CASE WHEN to_regnamespace('public') IS NULL THEN NULL
             ELSE has_schema_privilege(session_user::text,'public','USAGE') END,
           'session_user_table_insert_privilege',CASE WHEN c.oid IS NULL THEN NULL
             ELSE has_table_privilege(session_user::text,c.oid,'INSERT') END,
           'session_user_approved_column_insert_privileges',CASE
             WHEN c.oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
               WHERE a.attrelid=c.oid AND a.attname='user_id' AND a.attnum>0 AND NOT a.attisdropped)
               OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
               WHERE a.attrelid=c.oid AND a.attname='role' AND a.attnum>0 AND NOT a.attisdropped)
             THEN NULL
             ELSE has_table_privilege(session_user::text,c.oid,'INSERT') OR
               (has_column_privilege(session_user::text,c.oid,'user_id','INSERT') AND
                has_column_privilege(session_user::text,c.oid,'role','INSERT')) END,
           'session_user_rls_enabled',c.relrowsecurity,
           'session_user_rls_forced',c.relforcerowsecurity,
           'current_user',current_user::text,
           'current_user_is_superuser',(SELECT r.rolsuper FROM pg_catalog.pg_roles r WHERE r.rolname=current_user),
           'current_user_has_public_usage',CASE WHEN to_regnamespace('public') IS NULL THEN NULL
             ELSE has_schema_privilege(current_user::text,'public','USAGE') END,
           'current_user_table_insert_privilege',CASE WHEN c.oid IS NULL THEN NULL
             ELSE has_table_privilege(current_user::text,c.oid,'INSERT') END,
           'current_user_approved_column_insert_privileges',CASE
             WHEN c.oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
               WHERE a.attrelid=c.oid AND a.attname='user_id' AND a.attnum>0 AND NOT a.attisdropped)
               OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
               WHERE a.attrelid=c.oid AND a.attname='role' AND a.attnum>0 AND NOT a.attisdropped)
             THEN NULL
             ELSE has_table_privilege(current_user::text,c.oid,'INSERT') OR
               (has_column_privilege(current_user::text,c.oid,'user_id','INSERT') AND
                has_column_privilege(current_user::text,c.oid,'role','INSERT')) END,
           'current_user_rls_enabled',c.relrowsecurity,
           'current_user_rls_forced',c.relforcerowsecurity,
           'interpretation','Privilege and RLS evidence only; this does not execute the approved INSERT')
  FROM (SELECT relid FROM relation_specs WHERE relation_name='public.user_roles') ur
  LEFT JOIN pg_catalog.pg_class c ON c.oid=ur.relid

  UNION ALL
  -- Exact function definitions are returned only for the four named workflow
  -- functions. Direct ACLs and effective EXECUTE are separate evidence rows.
  SELECT 40, 'Function definitions and direct ACLs',fr.function_name,
         CASE WHEN p.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
         CASE WHEN p.oid IS NULL THEN jsonb_build_object('function_exists',false,'signature',fr.signature)
         ELSE jsonb_build_object('function_exists',true,'signature',fr.signature,
           'return_type',pg_catalog.format_type(p.prorettype,NULL),
           'owner',pg_catalog.pg_get_userbyid(p.proowner),'language',l.lanname,
           'security_definer',p.prosecdef,'volatility',p.provolatile::text,'configuration',p.proconfig,
           'acl_explicitly_stored',p.proacl IS NOT NULL,
           'definition',pg_catalog.pg_get_functiondef(p.oid),
           'direct_acl_entries',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'grantee',CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
             'grantor',pg_catalog.pg_get_userbyid(acl.grantor),'privilege',acl.privilege_type,
             'grant_option',acl.is_grantable) ORDER BY acl.grantee,acl.privilege_type,acl.grantor)
             FROM pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) acl),'[]'::jsonb)) END
  FROM function_rows fr LEFT JOIN pg_catalog.pg_proc p ON p.oid=fr.oid
  LEFT JOIN pg_catalog.pg_language l ON l.oid=p.prolang

  UNION ALL
  SELECT 41, 'Effective function EXECUTE',pg_catalog.format('%s / %s',fr.function_name,pr.role_name),
         CASE WHEN p.oid IS NULL OR pr.oid IS NULL THEN 'UNKNOWN' ELSE 'AVAILABLE' END,
         jsonb_build_object('function_exists',p.oid IS NOT NULL,'role_exists',pr.oid IS NOT NULL,
           'role',pr.role_name,'can_execute',CASE WHEN p.oid IS NULL OR pr.oid IS NULL THEN NULL
                                                 ELSE has_function_privilege(pr.oid,p.oid,'EXECUTE') END)
  FROM function_rows fr CROSS JOIN privilege_roles pr
  LEFT JOIN pg_catalog.pg_proc p ON p.oid=fr.oid

  UNION ALL
  SELECT 42, 'Other functions referencing user_roles',p.oid::regprocedure::text,'REVIEW',
         jsonb_build_object('owner',pg_catalog.pg_get_userbyid(p.proowner),'language',l.lanname,
           'security_definer',p.prosecdef,'configuration',p.proconfig,'definition_returned',false,
           'note','Function source is omitted; review the named definition through an approved source review process')
  FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
  JOIN pg_catalog.pg_language l ON l.oid=p.prolang
  WHERE n.nspname='public' AND p.prokind='f' AND position('user_roles' IN p.prosrc)>0
    AND p.oid NOT IN (SELECT oid FROM function_rows WHERE oid IS NOT NULL)
  UNION ALL
  SELECT 43, 'Other functions referencing user_roles','none found','EMPTY',
         jsonb_build_object('note','No other public function source references user_roles')
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prokind='f' AND position('user_roles' IN p.prosrc)>0
      AND p.oid NOT IN (SELECT oid FROM function_rows WHERE oid IS NOT NULL))

  UNION ALL
  -- Detect role-specific audit tables without reading their records.
  SELECT 50, 'Role audit infrastructure',n.nspname||'.'||c.relname,'PRESENT',
         jsonb_build_object('owner',pg_catalog.pg_get_userbyid(c.relowner),
           'relation_kind',c.relkind::text,'rls_enabled',c.relrowsecurity,'rls_forced',c.relforcerowsecurity,
           'columns',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',a.attname::text,
             'type',pg_catalog.format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull) ORDER BY a.attnum)
             FROM pg_catalog.pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),'[]'::jsonb),
           'constraints',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',con.conname::text,
             'type',con.contype::text,'definition',pg_catalog.pg_get_constraintdef(con.oid,true)) ORDER BY con.conname)
             FROM pg_catalog.pg_constraint con WHERE con.conrelid=c.oid),'[]'::jsonb),
           'policies',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',pol.polname::text,
             'command',pol.polcmd::text,'permissive',pol.polpermissive,
             'roles',ARRAY(SELECT CASE WHEN role_oid=0 THEN 'PUBLIC'
                                       ELSE pg_catalog.pg_get_userbyid(role_oid) END
                           FROM unnest(pol.polroles) AS roles(role_oid) ORDER BY role_oid),
             'using',pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),
             'with_check',pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid)) ORDER BY pol.polname)
             FROM pg_catalog.pg_policy pol WHERE pol.polrelid=c.oid),'[]'::jsonb),
           'direct_acl_entries',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'grantee',CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
             'grantor',pg_catalog.pg_get_userbyid(acl.grantor),'privilege',acl.privilege_type,
             'grant_option',acl.is_grantable) ORDER BY acl.grantee,acl.privilege_type,acl.grantor)
             FROM pg_catalog.aclexplode(COALESCE(c.relacl,pg_catalog.acldefault('r',c.relowner))) acl),'[]'::jsonb))
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'
    AND c.relkind IN ('r','p') AND (c.relname ILIKE '%role%audit%' OR c.relname ILIKE '%audit%role%')
  UNION ALL
  SELECT 51, 'Role audit infrastructure','no role-related audit table found','EMPTY',
         jsonb_build_object('note','No non-system table name matched role/audit')
  WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'
      AND c.relkind IN ('r','p') AND (c.relname ILIKE '%role%audit%' OR c.relname ILIKE '%audit%role%'))

  UNION ALL
  -- Trigger state for target tables plus auth.users; no trigger is altered.
  SELECT 60, 'Relevant triggers',t.tgrelid::regclass::text||'.'||t.tgname,'PRESENT',
         jsonb_build_object('relation',t.tgrelid::regclass::text,'name',t.tgname::text,
           'internal',t.tgisinternal,'enabled_code',t.tgenabled::text,
           'definition',pg_catalog.pg_get_triggerdef(t.oid,true),
           'function',t.tgfoid::regprocedure::text,'function_owner',pg_catalog.pg_get_userbyid(p.proowner),
           'function_security_definer',p.prosecdef,'function_configuration',p.proconfig)
  FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
  WHERE NOT t.tgisinternal AND (
    t.tgrelid IN (SELECT relid FROM relation_specs WHERE relid IS NOT NULL
      UNION SELECT to_regclass('auth.users') WHERE to_regclass('auth.users') IS NOT NULL)
    OR EXISTS (
      SELECT 1 FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE c.oid=t.tgrelid AND n.nspname NOT IN ('pg_catalog','information_schema')
        AND n.nspname !~ '^pg_toast' AND c.relkind IN ('r','p')
        AND (c.relname ILIKE '%role%audit%' OR c.relname ILIKE '%audit%role%')
    )
  )
  UNION ALL
  SELECT 59, 'Auth schema dependency', 'auth.users',
         CASE WHEN to_regclass('auth.users') IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
         jsonb_build_object('relation_exists',to_regclass('auth.users') IS NOT NULL,
           'owner',CASE WHEN to_regclass('auth.users') IS NULL THEN NULL
                        ELSE pg_catalog.pg_get_userbyid((SELECT c.relowner FROM pg_catalog.pg_class c
                                                         WHERE c.oid=to_regclass('auth.users'))) END)
  UNION ALL
  SELECT 61, 'Profile role-protection trigger','prevent_profile_role_escalation',
         CASE WHEN to_regclass('public.profiles') IS NULL THEN 'UNKNOWN'
              WHEN (SELECT count(*) FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid=to_regclass('public.profiles')
                      AND t.tgname='prevent_profile_role_escalation'
                      AND NOT t.tgisinternal)=0 THEN 'MISSING' ELSE 'PRESENT' END,
         jsonb_build_object('profiles_exists',to_regclass('public.profiles') IS NOT NULL,
           'matching_trigger_count',CASE WHEN to_regclass('public.profiles') IS NULL THEN NULL
             ELSE (SELECT count(*) FROM pg_catalog.pg_trigger t
                   WHERE t.tgrelid=to_regclass('public.profiles')
                     AND t.tgname='prevent_profile_role_escalation'
                     AND NOT t.tgisinternal) END)
  FROM (SELECT 1) seed

  UNION ALL
  SELECT 62, 'Auth signup trigger','on_auth_user_created',
         CASE WHEN to_regclass('auth.users') IS NULL THEN 'UNKNOWN'
              WHEN (SELECT count(*) FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid=to_regclass('auth.users')
                      AND t.tgname='on_auth_user_created' AND NOT t.tgisinternal)=0
                   THEN 'MISSING' ELSE 'PRESENT' END,
         CASE WHEN to_regclass('auth.users') IS NULL
              THEN jsonb_build_object('auth_users_exists',false,'matching_trigger_count',NULL)
         ELSE jsonb_build_object('auth_users_exists',true,
           'matching_trigger_count',(SELECT count(*) FROM pg_catalog.pg_trigger t
             WHERE t.tgrelid=to_regclass('auth.users')
               AND t.tgname='on_auth_user_created' AND NOT t.tgisinternal),
           'matching_definitions',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'definition',pg_catalog.pg_get_triggerdef(t.oid,true),'enabled_code',t.tgenabled::text,
             'function',t.tgfoid::regprocedure::text) ORDER BY t.oid)
             FROM pg_catalog.pg_trigger t WHERE t.tgrelid=to_regclass('auth.users')
               AND t.tgname='on_auth_user_created' AND NOT t.tgisinternal),'[]'::jsonb)) END
  FROM (SELECT 1) seed

  UNION ALL
  SELECT 70, 'Profile role contract','public.profiles.role',
         CASE WHEN pr.relid IS NULL THEN 'UNKNOWN' WHEN a.attnum IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
         CASE WHEN pr.relid IS NULL OR a.attnum IS NULL
              THEN jsonb_build_object('profiles_exists',pr.relid IS NOT NULL,'role_column_exists',a.attnum IS NOT NULL)
         ELSE jsonb_build_object('type',pg_catalog.format_type(a.atttypid,a.atttypmod),
           'not_null',a.attnotnull,'default',pg_catalog.pg_get_expr(d.adbin,d.adrelid),
           'check_constraints',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',con.conname::text,
             'definition',pg_catalog.pg_get_constraintdef(con.oid,true),'validated',con.convalidated) ORDER BY con.conname)
             FROM pg_catalog.pg_constraint con WHERE con.conrelid=a.attrelid AND con.contype='c'),'[]'::jsonb)) END
  FROM (SELECT to_regclass('public.profiles') AS relid) pr
  LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=pr.relid AND a.attname='role'
    AND a.attnum>0 AND NOT a.attisdropped
  LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum

  UNION ALL
  SELECT 71, 'Role protection function',fr.function_name,
         CASE WHEN p.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
         CASE WHEN p.oid IS NULL THEN jsonb_build_object('function_exists',false)
         ELSE jsonb_build_object('owner',pg_catalog.pg_get_userbyid(p.proowner),
           'language',l.lanname,'security_definer',p.prosecdef,'configuration',p.proconfig,
           'definition',pg_catalog.pg_get_functiondef(p.oid)) END
  FROM function_rows fr LEFT JOIN pg_catalog.pg_proc p ON p.oid=fr.oid
  LEFT JOIN pg_catalog.pg_language l ON l.oid=p.prolang
  WHERE fr.function_name='public.prevent_profile_role_escalation'

  UNION ALL
  SELECT 80, 'NGO analytics','public.get_ngo_dashboard_stats',
         CASE WHEN p.oid IS NULL THEN 'MISSING' ELSE 'PRESENT' END,
         CASE WHEN p.oid IS NULL THEN jsonb_build_object('function_exists',false)
         ELSE jsonb_build_object('owner',pg_catalog.pg_get_userbyid(p.proowner),
           'language',l.lanname,'security_definer',p.prosecdef,'configuration',p.proconfig,
           'definition',pg_catalog.pg_get_functiondef(p.oid),
           'direct_acl_entries',COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'grantee',CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
             'grantor',pg_catalog.pg_get_userbyid(acl.grantor),'privilege',acl.privilege_type,
             'grant_option',acl.is_grantable) ORDER BY acl.grantee,acl.privilege_type,acl.grantor)
             FROM pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) acl),'[]'::jsonb)) END
  FROM function_rows fr LEFT JOIN pg_catalog.pg_proc p ON p.oid=fr.oid
  LEFT JOIN pg_catalog.pg_language l ON l.oid=p.prolang
  WHERE fr.function_name='public.get_ngo_dashboard_stats'
)
SELECT section, item, status, details
FROM evidence
ORDER BY section_order, section, item;
