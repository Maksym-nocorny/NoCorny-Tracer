import { NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { apiTokens } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { generateToken, hashToken } from "@/lib/tokens";

// POST /api/tokens — issue a new API token for the signed-in user
// Returns the plaintext token ONCE. Old tokens for this user are revoked.
export async function POST() {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  // Revoke any existing tokens (single-token-per-user model for simplicity)
  await db.delete(apiTokens).where(eq(apiTokens.userId, session.user.id));

  const token = generateToken();
  const hash = hashToken(token);

  await db.insert(apiTokens).values({
    userId: session.user.id,
    tokenHash: hash,
    name: "macOS App",
  });

  return NextResponse.json({ token });
}
