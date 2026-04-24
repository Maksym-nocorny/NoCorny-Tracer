import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db";
import { videos } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

// GET /api/videos/[slug]/status — public polling endpoint for processing state
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ slug: string }> }
) {
  const { slug } = await params;

  const [video] = await db
    .select({
      processingStatus: videos.processingStatus,
      title: videos.title,
      description: videos.description,
      transcriptSrt: videos.transcriptSrt,
      transcriptSegments: videos.transcriptSegments,
      thumbnailUrl: videos.thumbnailUrl,
      updatedAt: videos.updatedAt,
    })
    .from(videos)
    .where(eq(videos.slug, slug))
    .limit(1);

  if (!video) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  return NextResponse.json(video, {
    headers: { "Cache-Control": "no-store" },
  });
}
