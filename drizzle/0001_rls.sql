-- Tenant isolation. The application connects as the schema owner and drops to
-- the app_tenant role inside withTenant(); RLS applies to that role, so a
-- tenant transaction can only see and write rows for app.current_org.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_tenant') THEN
    CREATE ROLE app_tenant NOLOGIN;
  END IF;
END
$$;
--> statement-breakpoint
-- Postgres 16 gives a CREATEROLE creator ADMIN on the new role but not SET,
-- so grant SET explicitly; older servers only need plain membership.
DO $$
BEGIN
  IF current_setting('server_version_num')::int >= 160000 THEN
    EXECUTE format('GRANT app_tenant TO %I WITH INHERIT FALSE, SET TRUE', current_user);
  ELSIF NOT pg_has_role(current_user, 'app_tenant', 'MEMBER') THEN
    EXECUTE format('GRANT app_tenant TO %I', current_user);
  END IF;
END
$$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION app_current_org() RETURNS uuid
  LANGUAGE sql STABLE
  AS $$ SELECT nullif(current_setting('app.current_org', true), '')::uuid $$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION app_current_user() RETURNS uuid
  LANGUAGE sql STABLE
  AS $$ SELECT nullif(current_setting('app.current_user', true), '')::uuid $$;
--> statement-breakpoint
GRANT USAGE ON SCHEMA public TO app_tenant;
--> statement-breakpoint
GRANT SELECT, UPDATE, DELETE ON organizations TO app_tenant;
--> statement-breakpoint
GRANT SELECT, INSERT, UPDATE, DELETE ON memberships, invitations, subscriptions, api_keys, projects TO app_tenant;
--> statement-breakpoint
GRANT SELECT, INSERT ON audit_logs TO app_tenant;
--> statement-breakpoint
GRANT SELECT ON users TO app_tenant;
--> statement-breakpoint
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY tenant_isolation ON organizations TO app_tenant
  USING (id = app_current_org()) WITH CHECK (id = app_current_org());
--> statement-breakpoint
-- A signed-in user may list the organizations they belong to before any org is selected.
CREATE POLICY member_directory ON organizations FOR SELECT TO app_tenant
  USING (EXISTS (
    SELECT 1 FROM memberships m WHERE m.org_id = organizations.id AND m.user_id = app_current_user()
  ));
--> statement-breakpoint
ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY tenant_isolation ON memberships TO app_tenant
  USING (org_id = app_current_org()) WITH CHECK (org_id = app_current_org());
--> statement-breakpoint
CREATE POLICY member_self ON memberships FOR SELECT TO app_tenant
  USING (user_id = app_current_user());
--> statement-breakpoint
ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY tenant_isolation ON invitations TO app_tenant
  USING (org_id = app_current_org()) WITH CHECK (org_id = app_current_org());
--> statement-breakpoint
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY tenant_isolation ON subscriptions TO app_tenant
  USING (org_id = app_current_org()) WITH CHECK (org_id = app_current_org());
--> statement-breakpoint
ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY tenant_isolation ON api_keys TO app_tenant
  USING (org_id = app_current_org()) WITH CHECK (org_id = app_current_org());
--> statement-breakpoint
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY tenant_isolation ON projects TO app_tenant
  USING (org_id = app_current_org()) WITH CHECK (org_id = app_current_org());
--> statement-breakpoint
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY tenant_read ON audit_logs FOR SELECT TO app_tenant
  USING (org_id = app_current_org());
--> statement-breakpoint
CREATE POLICY tenant_append ON audit_logs FOR INSERT TO app_tenant
  WITH CHECK (org_id = app_current_org());
--> statement-breakpoint
-- Identity rows are global, but a tenant may only see itself and people in the current org.
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
--> statement-breakpoint
CREATE POLICY visible_users ON users FOR SELECT TO app_tenant
  USING (
    id = app_current_user()
    OR EXISTS (SELECT 1 FROM memberships m WHERE m.user_id = users.id AND m.org_id = app_current_org())
  );
