import { neon } from "@neondatabase/serverless";
import { drizzle } from "drizzle-orm/neon-http";
import * as schema from "./schema";

// Use a placeholder URL at build time so Next.js static analysis doesn't throw.
// Actual queries will fail with a clear error if DATABASE_URL is not set at runtime.
const sql = neon(
  process.env.DATABASE_URL ??
    "postgresql://none:none@none/none?sslmode=require"
);

export const db = drizzle(sql, { schema });
