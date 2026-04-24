import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { videos } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";
import { nanoid } from "nanoid";
import { verifyBearerToken } from "@/lib/tokens";
import { parseSrt } from "@/lib/transcript";
import { generateDescriptionForVideo } from "@/lib/generate-description";

// GET /api/videos — list user's videos. Accepts session cookie OR Bearer token.
export async function GET(req: NextRequest) {
  let userId: string | null = null;

  const session = await auth();
  if (session?.user?.id) {
    userId = session.user.id;
  } else {
    const tokenUser = await verifyBearerToken(req);
    if (tokenUser) userId = tokenUser.userId;
  }

  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userVideos = await db
    .select()
    .from(videos)
    .where(and(eq(videos.userId, userId), eq(videos.isDeleted, false)))
    .orderBy(desc(videos.createdAt));

  return NextResponse.json(userVideos);
}

// POST /api/videos — register a new video (called by macOS app after upload)
// Accepts either a web session cookie or a Bearer API token.
export async function POST(req: NextRequest) {
  let userId: string | null = null;

  const session = await auth();
  if (session?.user?.id) {
    userId = session.user.id;
  } else {
    const tokenUser = await verifyBearerToken(req);
    if (tokenUser) userId = tokenUser.userId;
  }

  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = await req.json();
  const {
    dropboxPath,
    dropboxSharedUrl,
    title,
    duration,
    fileSize,
    recordedAt,
    thumbnailUrl,
    transcriptSrt,
    processingStatus,
  } = body as {
    dropboxPath?: string;
    dropboxSharedUrl?: string;
    title?: string;
    duration?: number;
    fileSize?: number;
    recordedAt?: string;
    thumbnailUrl?: string;
    transcriptSrt?: string;
    processingStatus?: string;
  };

  if (!dropboxPath) {
    return NextResponse.json(
      { error: "dropboxPath is required" },
      { status: 400 }
    );
  }

  const effectiveTitle = title ?? (() => {
    const d = recordedAt ? new Date(recordedAt) : new Date();
    const pad = (n: number) => String(n).padStart(2, "0");
    return `Recording · ${pad(d.getDate())} ${d.toLocaleString("en-US", { month: "short" })} ${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  })();

  const slug = nanoid(7);

  const segments = transcriptSrt ? parseSrt(transcriptSrt) : [];
  const hasTranscript = segments.length > 0;

  const [video] = await db
    .insert(videos)
    .values({
      userId,
      slug,
      title: effectiveTitle,
      processingStatus: processingStatus ?? "ready",
      dropboxPath,
      dropboxSharedUrl: dropboxSharedUrl ?? null,
      duration: duration ?? null,
      fileSize: fileSize ?? null,
      thumbnailUrl: thumbnailUrl ?? null,
      recordedAt: recordedAt ? new Date(recordedAt) : new Date(),
      transcriptSrt: hasTranscript ? transcriptSrt : null,
      transcriptSegments: hasTranscript ? segments : null,
    })
    .returning();

  if (hasTranscript) {
    generateDescriptionForVideo(video.id).catch((err) => {
      console.error("Failed to generate description", err);
    });
  }

  return NextResponse.json({
    id: video.id,
    slug: video.slug,
    url: `${process.env.AUTH_URL || "https://tracer.nocorny.com"}/v/${video.slug}`,
  });
}
