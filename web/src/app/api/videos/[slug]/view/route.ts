import { NextRequest, NextResponse } from "next/server";
import { createHash } from "crypto";
import { db } from "@/lib/db";
import { videos, videoViews } from "@/lib/db/schema";
import { eq, and, gt, sql } from "drizzle-orm";

type Params = { params: Promise<{ slug: string }> };

export async function POST(req: NextRequest, { params }: Params) {
  const { slug } = await params;

  const [video] = await db
    .select({ id: videos.id })
    .from(videos)
    .where(and(eq(videos.slug, slug), eq(videos.isDeleted, false)))
    .limit(1);

  if (!video) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  const ip =
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "unknown";
  const ua = req.headers.get("user-agent") ?? "";
  const fingerprint = createHash("sha256").update(`${ip}:${ua}`).digest("hex");

  const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000);

  const [existing] = await db
    .select({ id: videoViews.id })
    .from(videoViews)
    .where(
      and(
        eq(videoViews.videoId, video.id),
        eq(videoViews.fingerprint, fingerprint),
        gt(videoViews.viewedAt, cutoff)
      )
    )
    .limit(1);

  if (existing) {
    return NextResponse.json({ ok: true, counted: false });
  }

  await db.insert(videoViews).values({ videoId: video.id, fingerprint });
  await db
    .update(videos)
    .set({ viewCount: sql`${videos.viewCount} + 1` })
    .where(eq(videos.id, video.id));

  return NextResponse.json({ ok: true, counted: true });
}
