import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { apiTokens } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { generateToken, hashToken } from "@/lib/tokens";

const ALLOWED_REDIRECT_PREFIX = "nocornytracer://";

/**
 * POST /api/auth/device/approve
 *
 * Called by /auth/device after the user clicks "Approve".
 * Issues a fresh API token for the signed-in user (revoking any existing ones)
 * and returns a callback URL the browser can redirect to, carrying the token
 * to the desktop app via its custom URL scheme.
 */
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { state, redirect } = await req.json();
  if (typeof state !== "string" || !state) {
    return NextResponse.json({ error: "Missing state" }, { status: 400 });
  }
  if (typeof redirect !== "string" || !redirect.startsWith(ALLOWED_REDIRECT_PREFIX)) {
    return NextResponse.json({ error: "Invalid redirect" }, { status: 400 });
  }

  await db.delete(apiTokens).where(eq(apiTokens.userId, session.user.id));

  const token = generateToken();
  await db.insert(apiTokens).values({
    userId: session.user.id,
    tokenHash: hashToken(token),
    name: "macOS App",
  });

  const callback = new URL(redirect);
  callback.searchParams.set("token", token);
  callback.searchParams.set("state", state);

  return NextResponse.json({ redirectUrl: callback.toString() });
}
