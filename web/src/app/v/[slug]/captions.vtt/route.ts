import { NextResponse } from "next/server";
import { db } from "@/lib/db";
import { videos } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { segmentsToVtt } from "@/lib/transcript";

type Params = { params: Promise<{ slug: string }> };

export async function GET(_req: Request, { params }: Params) {
  const { slug } = await params;

  const [video] = await db
    .select({
      isDeleted: videos.isDeleted,
      segments: videos.transcriptSegments,
    })
    .from(videos)
    .where(eq(videos.slug, slug))
    .limit(1);

  if (!video || video.isDeleted || !video.segments?.length) {
    return new NextResponse("WEBVTT\n\n", {
      status: 200,
      headers: { "Content-Type": "text/vtt; charset=utf-8" },
    });
  }

  return new NextResponse(segmentsToVtt(video.segments), {
    status: 200,
    headers: {
      "Content-Type": "text/vtt; charset=utf-8",
      "Cache-Control": "public, max-age=60, stale-while-revalidate=300",
    },
  });
}
