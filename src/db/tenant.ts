import { sql } from "drizzle-orm";
import { z } from "zod";
import type { Database, Tx } from "./client";

export const TENANT_ROLE = "app_tenant";

export interface TenantContext {
  orgId: string;
  userId?: string | null;
}

const uuid = z.uuid();

/**
 * Runs `fn` in a transaction scoped to one organization. The transaction
 * switches to the unprivileged tenant role and pins `app.current_org`, so
 * Postgres row-level security filters every read and rejects every write
 * that targets another org, regardless of what the query itself says.
 */
export async function withTenant<T>(
  db: Database,
  ctx: TenantContext,
  fn: (tx: Tx) => Promise<T>,
): Promise<T> {
  const orgId = uuid.parse(ctx.orgId);
  const userId = ctx.userId ? uuid.parse(ctx.userId) : "";
  return db.transaction(async (tx) => {
    await tx.execute(
      sql`select set_config('app.current_org', ${orgId}, true), set_config('app.current_user', ${userId}, true)`,
    );
    await tx.execute(sql.raw(`set local role ${TENANT_ROLE}`));
    return fn(tx);
  });
}
