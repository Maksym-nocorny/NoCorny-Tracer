import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db";
import { dropboxConnections, videos } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { getDropboxTokens, dropboxListFolder, dropboxListSharedLinks } from "@/lib/dropbox";
import { nanoid } from "nanoid";

// GET /api/webhooks/dropbox — Dropbox verification challenge
export async function GET(req: NextRequest) {
  const challenge = req.nextUrl.searchParams.get("challenge");
  if (challenge) {
    return new NextResponse(challenge, {
      headers: {
        "Content-Type": "text/plain",
        "X-Content-Type-Options": "nosniff",
      },
    });
  }
  return NextResponse.json({ ok: true });
}

// POST /api/webhooks/dropbox — Dropbox notification
export async function POST(req: NextRequest) {
  const body = await req.json();
  const accountIds: string[] =
    body?.list_folder?.accounts || [];

  for (const accountId of accountIds) {
    // Find user with this Dropbox account
    const [conn] = await db
      .select()
      .from(dropboxConnections)
      .where(eq(dropboxConnections.dropboxAccountId, accountId))
      .limit(1);

    if (!conn) continue;

    try {
      await syncUserDropbox(conn.userId);
    } catch (e) {
      console.error(`Webhook sync failed for user ${conn.userId}:`, e);
    }
  }

  return NextResponse.json({ ok: true });
}

export async function syncUserDropbox(userId: string) {
  const tokens = await getDropboxTokens(userId);
  if (!tokens) return;

  // Get changes since last cursor
  const data = await dropboxListFolder(tokens.accessToken, tokens.cursor);

  // Get shared links
  const sharedLinks = await dropboxListSharedLinks(tokens.accessToken);

  // Process entries
  for (const entry of data.entries || []) {
    if (entry[".tag"] === "deleted") {
      // Soft-delete matching video
      await db
        .update(videos)
        .set({ isDeleted: true, updatedAt: new Date() })
        .where(eq(videos.dropboxPath, entry.path_display));
      continue;
    }

    if (entry[".tag"] !== "file") continue;
    if (!entry.name.match(/\.(mp4|mov|webm)$/i)) continue;

    // Check if video already exists
    const existing = await db
      .select()
      .from(videos)
      .where(eq(videos.dropboxPath, entry.path_display))
      .limit(1);

    const sharedUrl = sharedLinks[entry.path_lower] || null;
    const duration =
      entry.media_info?.metadata?.duration != null
        ? entry.media_info.metadata.duration / 1000
        : null;

    if (existing.length > 0) {
      // Update existing
      await db
        .update(videos)
        .set({
          title: entry.name.replace(/\.\w+$/, ""),
          dropboxSharedUrl: sharedUrl,
          fileSize: entry.size,
          duration,
          isDeleted: false,
          updatedAt: new Date(),
        })
        .where(eq(videos.id, existing[0].id));
    } else {
      // Create new video record
      await db.insert(videos).values({
        userId,
        slug: nanoid(7),
        title: entry.name.replace(/\.\w+$/, ""),
        dropboxPath: entry.path_display,
        dropboxSharedUrl: sharedUrl,
        fileSize: entry.size,
        duration,
        recordedAt: entry.client_modified
          ? new Date(entry.client_modified)
          : new Date(),
      });
    }
  }

  // Save new cursor
  if (data.cursor) {
    await db
      .update(dropboxConnections)
      .set({ cursor: data.cursor, lastSyncedAt: new Date() })
      .where(eq(dropboxConnections.userId, userId));
  }
}
