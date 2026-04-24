import { db } from "@/lib/db";
import { videos } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { generateText } from "@/lib/gemini";

const PROMPT_PREFIX = `Write a concise 2-3 sentence summary of this screen recording based on the transcript below. Use neutral present tense, no fluff, no emojis, no markdown. Do not reference "the video" or "the speaker" — describe what is happening.

Transcript:
`;

const MAX_TRANSCRIPT_CHARS = 30_000;

export async function generateDescriptionForVideo(
  videoId: string
): Promise<string | null> {
  const [row] = await db
    .select({ srt: videos.transcriptSrt })
    .from(videos)
    .where(eq(videos.id, videoId))
    .limit(1);

  if (!row?.srt) return null;

  const transcript = row.srt.slice(0, MAX_TRANSCRIPT_CHARS);
  const description = await generateText(PROMPT_PREFIX + transcript);

  await db
    .update(videos)
    .set({ description, updatedAt: new Date() })
    .where(eq(videos.id, videoId));

  return description;
}
