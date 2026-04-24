import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { videos } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { generateDescriptionForVideo } from "@/lib/generate-description";

type Params = { params: Promise<{ slug: string }> };

export async function POST(_req: NextRequest, { params }: Params) {
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

  if (!video.transcriptSrt) {
    return NextResponse.json(
      { error: "No transcript available" },
      { status: 400 }
    );
  }

  try {
    const description = await generateDescriptionForVideo(video.id);
    return NextResponse.json({ description });
  } catch (err) {
    console.error("generate-description failed", err);
    return NextResponse.json(
      { error: "Failed to generate description" },
      { status: 500 }
    );
  }
}
