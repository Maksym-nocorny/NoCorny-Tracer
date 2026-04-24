"use client";

import Link from "next/link";
import type { videos } from "@/lib/db/schema";
import type { InferSelectModel } from "drizzle-orm";
import { relativeTime } from "@/lib/relative-time";

type Video = InferSelectModel<typeof videos>;

export type GridAuthor = {
  name: string;
  image: string | null;
};

function formatDuration(seconds: number | null): string | null {
  if (!seconds) return null;
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export function VideoGrid({
  videos,
  author,
}: {
  videos: Video[];
  author: GridAuthor;
}) {
  const userName = author.name;
  const userImage = author.image;
  const firstLetter = (userName || "?").slice(0, 1).toUpperCase();

  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-5">
      {videos.map((video) => {
        const duration = formatDuration(video.duration);
        const stamp = video.recordedAt ?? video.createdAt;
        const ago = stamp ? relativeTime(stamp) : "";
        const views = video.viewCount ?? 0;
        return (
          <Link key={video.id} href={`/v/${video.slug}`} className="group">
            <article className="card card-interactive p-3">
              <div className="relative aspect-video bg-bg-secondary rounded-md overflow-hidden">
                {video.thumbnailUrl ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={video.thumbnailUrl}
                    alt={video.title}
                    className="w-full h-full object-cover"
                    loading="lazy"
                  />
                ) : (
                  <div className="w-full h-full flex items-center justify-center text-text-tertiary">
                    <svg
                      className="w-10 h-10"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                      strokeWidth={1.5}
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        d="m15.75 10.5 4.72-4.72a.75.75 0 0 1 1.28.53v11.38a.75.75 0 0 1-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 0 0 2.25-2.25v-9a2.25 2.25 0 0 0-2.25-2.25h-9A2.25 2.25 0 0 0 2.25 7.5v9a2.25 2.25 0 0 0 2.25 2.25z"
                      />
                    </svg>
                  </div>
                )}

                {duration && <span className="duration-badge">{duration}</span>}

                <div className="absolute inset-0 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity bg-black/20">
                  <div className="w-12 h-12 rounded-full bg-white/90 flex items-center justify-center shadow-md">
                    <svg
                      className="w-5 h-5 text-[color:var(--brand-purple)] ml-0.5"
                      viewBox="0 0 24 24"
                      fill="currentColor"
                    >
                      <path d="M8 5v14l11-7z" />
                    </svg>
                  </div>
                </div>
              </div>

              <div className="px-1 pt-3 pb-1">
                <h3 className="font-heading font-bold text-text-primary line-clamp-2 leading-snug text-sm">
                  {video.title}
                </h3>

                <div className="flex items-center gap-2 mt-2">
                  {userImage ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img
                      src={userImage}
                      alt=""
                      className="w-5 h-5 rounded-full shrink-0"
                    />
                  ) : (
                    <div className="w-5 h-5 rounded-full bg-brand text-text-alt flex items-center justify-center text-[10px] font-bold shrink-0">
                      {firstLetter}
                    </div>
                  )}
                  <span className="text-xs text-text-secondary truncate">
                    {userName}
                  </span>
                  <span className="text-xs text-text-tertiary shrink-0">·</span>
                  <span className="text-xs text-text-tertiary shrink-0">
                    {ago}
                  </span>
                </div>

                <div className="flex items-center gap-3 mt-2 text-xs text-text-tertiary">
                  <StatIcon kind="views" count={views} />
                  <StatIcon kind="comments" count={0} />
                  <StatIcon kind="reactions" count={0} />
                </div>
              </div>
            </article>
          </Link>
        );
      })}
    </div>
  );
}

function StatIcon({
  kind,
  count,
}: {
  kind: "views" | "comments" | "reactions";
  count: number;
}) {
  const dim = count === 0;
  return (
    <span
      className={
        "flex items-center gap-1 " + (dim ? "opacity-50" : "")
      }
    >
      {kind === "views" && (
        <svg
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden
        >
          <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z" />
          <circle cx="12" cy="12" r="3" />
        </svg>
      )}
      {kind === "comments" && (
        <svg
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden
        >
          <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2Z" />
        </svg>
      )}
      {kind === "reactions" && (
        <svg
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden
        >
          <circle cx="12" cy="12" r="10" />
          <path d="M8 14s1.5 2 4 2 4-2 4-2" />
          <line x1="9" y1="9" x2="9.01" y2="9" />
          <line x1="15" y1="9" x2="15.01" y2="9" />
        </svg>
      )}
      <span>{count}</span>
    </span>
  );
}
