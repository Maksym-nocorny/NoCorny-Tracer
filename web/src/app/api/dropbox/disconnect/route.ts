import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { verifyBearerToken } from "@/lib/tokens";
import { db } from "@/lib/db";
import { dropboxConnections } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

// DELETE /api/dropbox/disconnect
// Supports both session auth (web) and Bearer auth (macOS app).
// Removes the user's Dropbox connection from the database.
export async function DELETE(req: NextRequest) {
  let userId: string | undefined;

  const bearer = await verifyBearerToken(req);
  if (bearer) {
    userId = bearer.userId;
  } else {
    const session = await auth();
    userId = session?.user?.id;
  }

  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  await db
    .delete(dropboxConnections)
    .where(eq(dropboxConnections.userId, userId));

  return NextResponse.json({ disconnected: true });
}
