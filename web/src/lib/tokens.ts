import { createHash, randomBytes } from "crypto";
import { db } from "./db";
import { apiTokens, users } from "./db/schema";
import { eq } from "drizzle-orm";

export function generateToken(): string {
  return "tra_" + randomBytes(32).toString("base64url");
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export async function verifyBearerToken(req: Request): Promise<{
  userId: string;
  email: string;
  name: string | null;
  image: string | null;
} | null> {
  const authHeader = req.headers.get("authorization");
  if (!authHeader?.startsWith("Bearer ")) return null;

  const token = authHeader.slice(7).trim();
  if (!token) return null;

  const hash = hashToken(token);

  const [row] = await db
    .select({
      userId: apiTokens.userId,
      email: users.email,
      name: users.name,
      image: users.image,
    })
    .from(apiTokens)
    .innerJoin(users, eq(apiTokens.userId, users.id))
    .where(eq(apiTokens.tokenHash, hash))
    .limit(1);

  if (!row) return null;

  // Fire-and-forget update of last_used_at
  db.update(apiTokens)
    .set({ lastUsedAt: new Date() })
    .where(eq(apiTokens.tokenHash, hash))
    .catch(() => {});

  return row;
}
