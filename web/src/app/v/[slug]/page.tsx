import { notFound } from "next/navigation";
import { db } from "@/lib/db";
import { videos, users } from "@/lib/db/schema";
import { eq, sql } from "drizzle-orm";
import type { Metadata } from "next";
import Link from "next/link";
import { auth } from "@/lib/auth";
import { VideoPageShell } from "./video-page-shell";
import { relativeTime } from "@/lib/relative-time";

function displayName(name: string | null, email: string | null): string {
  if (name && name.trim()) return name;
  if (email) return email.split("@")[0];
  return "Unknown";
}

type Props = {
  params: Promise<{ slug: string }>;
};

async function getVideo(slug: string) {
  const result = await db
    .select({
      video: videos,
      userName: users.name,
      userEmail: users.email,
      userImage: users.image,
    })
    .from(videos)
    .innerJoin(users, eq(videos.userId, users.id))
    .where(eq(videos.slug, slug))
    .limit(1);

  if (!result.length || result[0].video.isDeleted) return null;

  await db
    .update(videos)
    .set({ viewCount: sql`${videos.viewCount} + 1` })
    .where(eq(videos.slug, slug));

  return {
    ...result[0].video,
    authorName: result[0].userName,
    authorEmail: result[0].userEmail,
    authorImage: result[0].userImage,
  };
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params;
  const video = await getVideo(slug);

  if (!video) {
    return { title: "Video not found" };
  }

  const directUrl = video.dropboxSharedUrl?.replace(
    "www.dropbox.com",
    "dl.dropboxusercontent.com"
  );

  return {
    title: `${video.title} — NoCorny Tracer`,
    description:
      video.description ??
      `Screen recording by ${displayName(video.authorName, video.authorEmail)}`,
    openGraph: {
      title: video.title,
      description:
        video.description ??
        `Screen recording by ${displayName(video.authorName, video.authorEmail)}`,
      type: "video.other",
      ...(directUrl && { videos: [{ url: directUrl }] }),
      ...(video.thumbnailUrl && { images: [{ url: video.thumbnailUrl }] }),
    },
  };
}

export default async function VideoPage({ params }: Props) {
  const { slug } = await params;
  const [video, session] = await Promise.all([getVideo(slug), auth()]);

  if (!video) {
    notFound();
  }

  const authorDisplay = displayName(video.authorName, video.authorEmail);
  const directUrl =
    video.dropboxSharedUrl?.replace(
      "www.dropbox.com",
      "dl.dropboxusercontent.com"
    ) ?? null;

  const views = (video.viewCount ?? 0) + 1;
  const stamp = video.recordedAt ?? video.createdAt;
  const ago = stamp ? relativeTime(stamp) : "";
  const isOwner = !!session?.user?.id && session.user.id === video.userId;

  return (
    <div className="min-h-screen bg-bg-primary flex flex-col">
      <header className="border-b border-[var(--card-border)]">
        <div className="max-w-[1400px] mx-auto px-6 flex items-center justify-between h-14">
          <Link
            href="/"
            className="font-heading text-lg font-bold gradient-text"
          >
            NoCorny Tracer
          </Link>
          {session ? (
            <Link
              href="/dashboard"
              className="text-sm font-medium text-text-secondary hover:text-text-primary transition-colors"
            >
              Open dashboard
            </Link>
          ) : (
            <Link
              href="/login"
              className="text-sm font-medium text-text-secondary hover:text-text-primary transition-colors"
            >
              Sign in
            </Link>
          )}
        </div>
      </header>

      <div className="flex-1 max-w-[1400px] mx-auto w-full px-6 py-8">
        <VideoPageShell
          slug={video.slug}
          directUrl={directUrl}
          processingStatus={video.processingStatus}
          initialTitle={video.title}
          initialDescription={video.description ?? null}
          initialTranscriptSegments={video.transcriptSegments ?? null}
          initialTranscriptSrt={video.transcriptSrt ?? null}
          initialThumbnailUrl={video.thumbnailUrl ?? null}
          transcriptLanguage={video.transcriptLanguage ?? null}
          isOwner={isOwner}
          authorDisplay={authorDisplay}
          authorImage={video.authorImage ?? null}
          ago={ago}
          views={views}
        />
      </div>

      <footer className="border-t border-[var(--card-border)] py-6">
        <div className="max-w-[1400px] mx-auto px-6 flex flex-wrap items-center justify-between gap-2 text-sm text-text-tertiary">
          <div>Made with NoCorny Tracer</div>
          <Link href="/" className="hover:text-text-primary transition-colors">
            Record your own
          </Link>
        </div>
      </footer>
    </div>
  );
}
