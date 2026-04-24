import { NextRequest, NextResponse } from "next/server";
import { verifyBearerToken } from "@/lib/tokens";
import { getDropboxTokens } from "@/lib/dropbox";
import { db } from "@/lib/db";
import { dropboxConnections } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

// GET /api/dropbox/access-token
// Bearer auth. Returns a short-lived Dropbox access token sourced from the
// user's server-stored refresh token, so the macOS app doesn't need its own
// OAuth flow when the user is already signed into Tracer.
export async function GET(req: NextRequest) {
  const tokenUser = await verifyBearerToken(req);
  if (!tokenUser) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const [conn] = await db
    .select({ tokenExpiresAt: dropboxConnections.tokenExpiresAt })
    .from(dropboxConnections)
    .where(eq(dropboxConnections.userId, tokenUser.userId))
    .limit(1);

  if (!conn) {
    return NextResponse.json({ connected: false });
  }

  const tokens = await getDropboxTokens(tokenUser.userId);
  if (!tokens) {
    return NextResponse.json({ connected: false });
  }

  return NextResponse.json({
    connected: true,
    accessToken: tokens.accessToken,
    expiresAt: conn.tokenExpiresAt?.toISOString() ?? null,
  });
}
