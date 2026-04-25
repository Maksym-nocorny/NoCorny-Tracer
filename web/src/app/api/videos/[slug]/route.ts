import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { videos } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { verifyBearerToken } from "@/lib/tokens";
import { parseSrt } from "@/lib/transcript";
import { generateDescriptionForVideo } from "@/lib/generate-description";
import { getDropboxTokens, dropboxMove } from "@/lib/dropbox";

type Params = { params: Promise<{ slug: string }> };

async function resolveUserId(req: NextRequest): Promise<string | null> {
  const session = await auth();
  if (session?.user?.id) return session.user.id;
  const tokenUser = await verifyBearerToken(req);
  return tokenUser?.userId ?? null;
}

// PATCH /api/videos/[slug] — rename video or update AI metadata
export async function PATCH(req: NextRequest, { params }: Params) {
  const userId = await resolveUserId(req);
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { slug } = await params;
  const body = await req.json();
  const { title, description, transcriptSrt, processingStatus, thumbnailUrl, dropboxPath } = body as {
    title?: string;
    description?: string | null;
    transcriptSrt?: string;
    processingStatus?: string;
    thumbnailUrl?: string;
    dropboxPath?: string;
  };

  if (
    title === undefined &&
    description === undefined &&
    transcriptSrt === undefined &&
    processingStatus === undefined &&
    thumbnailUrl === undefined &&
    dropboxPath === undefined
  ) {
    return NextResponse.json(
      { error: "No updatable fields provided" },
      { status: 400 }
    );
  }

  const [video] = await db
    .select()
    .from(videos)
    .where(and(eq(videos.slug, slug), eq(videos.userId, userId)))
    .limit(1);

  if (!video) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  const patch: Record<string, unknown> = { updatedAt: new Date() };
  if (title !== undefined) patch.title = title;
  if (description !== undefined) patch.description = description;
  if (processingStatus !== undefined) patch.processingStatus = processingStatus;
  if (thumbnailUrl !== undefined) patch.thumbnailUrl = thumbnailUrl;
  if (dropboxPath !== undefined) patch.dropboxPath = dropboxPath;

  // Rename files on Dropbox when the title changes
  if (title !== undefined && video.dropboxPath) {
    try {
      const tokens = await getDropboxTokens(userId);
      if (tokens?.accessToken) {
        const oldPath = video.dropboxPath;
        const dir = oldPath.substring(0, oldPath.lastIndexOf("/"));
        const ext = oldPath.substring(oldPath.lastIndexOf("."));
        const baseName = oldPath.substring(
          oldPath.lastIndexOf("/") + 1,
          oldPath.lastIndexOf(".")
        );
        const newVideoPath = `${dir}/${title}${ext}`;

        const moved = await dropboxMove(tokens.accessToken, oldPath, newVideoPath);
        patch.dropboxPath =
          (moved.metadata?.path_display as string | undefined) ?? newVideoPath;

        for (const suffix of [".srt", ".thumb.jpg"]) {
          try {
            await dropboxMove(
              tokens.accessToken,
              `${dir}/${baseName}${suffix}`,
              `${dir}/${title}${suffix}`
            );
          } catch {
            // file may not exist — ignore
          }
        }
      }
    } catch (err) {
      console.error("Dropbox rename failed, continuing:", err);
    }
  }

  let triggerDescriptionGen = false;
  if (transcriptSrt !== undefined) {
    const segments = parseSrt(transcriptSrt);
    if (segments.length > 0) {
      patch.transcriptSrt = transcriptSrt;
      patch.transcriptSegments = segments;
      triggerDescriptionGen = true;
    }
  }

  await db.update(videos).set(patch).where(eq(videos.id, video.id));

  // Await description generation synchronously so processingStatus:"ready"
  // only lands in the DB after the description is also written. This ensures
  // the polling watcher receives the description on the same tick it sees "ready".
  if (triggerDescriptionGen) {
    try {
      await generateDescriptionForVideo(video.id);
    } catch (err) {
      console.error("Failed to generate description on PATCH", err);
    }
  }

  // Return a fresh record so the response includes any description just written
  const [fresh] = await db
    .select()
    .from(videos)
    .where(eq(videos.id, video.id))
    .limit(1);

  return NextResponse.json(fresh);
}

// DELETE /api/videos/[slug] — soft delete video
export async function DELETE(_req: NextRequest, { params }: Params) {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { slug } = await params;

  const [video] = await db
    .select()
    .from(videos)
    .where(and(eq(videos.slug, slug), eq(videos.userId, session.user.id)))
    .limit(1);

  if (!video) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  // TODO: Delete from Dropbox via delete_v2 API

  await db
    .update(videos)
    .set({ isDeleted: true, updatedAt: new Date() })
    .where(eq(videos.id, video.id));

  return NextResponse.json({ ok: true });
}
