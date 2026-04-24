"use client";

import { useMemo, useState } from "react";
import type { videos } from "@/lib/db/schema";
import type { InferSelectModel } from "drizzle-orm";
import { VideoGrid, type GridAuthor } from "./video-grid";

type Video = InferSelectModel<typeof videos>;

type DateFilter = "all" | "7" | "30" | "90";
type SortOrder = "newest" | "oldest";
type Tab = "videos" | "screenshots" | "archive";

const DATE_FILTERS: Array<{ value: DateFilter; label: string }> = [
  { value: "all", label: "All time" },
  { value: "7", label: "Last 7 days" },
  { value: "30", label: "Last 30 days" },
  { value: "90", label: "Last 90 days" },
];

const SORTS: Array<{ value: SortOrder; label: string }> = [
  { value: "newest", label: "Newest to oldest" },
  { value: "oldest", label: "Oldest to newest" },
];

function daysAgo(days: number): Date {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d;
}

export function LibraryClient({
  videos: allVideos,
  author,
}: {
  videos: Video[];
  author: GridAuthor;
}) {
  const [tab, setTab] = useState<Tab>("videos");
  const [query, setQuery] = useState("");
  const [dateFilter, setDateFilter] = useState<DateFilter>("all");
  const [sort, setSort] = useState<SortOrder>("newest");

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    const cutoff = dateFilter === "all" ? null : daysAgo(Number(dateFilter));

    const result = allVideos.filter((v) => {
      if (q && !v.title.toLowerCase().includes(q)) return false;
      if (cutoff) {
        const stamp = v.recordedAt ?? v.createdAt;
        if (!stamp || new Date(stamp) < cutoff) return false;
      }
      return true;
    });

    result.sort((a, b) => {
      const aStamp = new Date(a.recordedAt ?? a.createdAt ?? 0).getTime();
      const bStamp = new Date(b.recordedAt ?? b.createdAt ?? 0).getTime();
      return sort === "newest" ? bStamp - aStamp : aStamp - bStamp;
    });

    return result;
  }, [allVideos, query, dateFilter, sort]);

  return (
    <div>
      {/* Header row */}
      <div className="flex flex-col md:flex-row md:items-end md:justify-between gap-4 mb-6">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-text-tertiary mb-1">
            Library
          </div>
          <h1 className="font-heading text-3xl font-bold text-text-primary">
            Videos
          </h1>
        </div>
        <div className="flex items-center gap-3">
          <span className="chip">
            {allVideos.length} {allVideos.length === 1 ? "video" : "videos"}
          </span>
          <button
            className="btn-ghost opacity-60 cursor-not-allowed"
            title="Coming soon"
            disabled
          >
            New folder
          </button>
          <a
            href="https://github.com/Maksym-nocorny/NoCorny-Tracer/releases/latest"
            target="_blank"
            rel="noopener noreferrer"
            className="btn-gradient"
          >
            New video
          </a>
        </div>
      </div>

      {/* Tabs */}
      <div className="tabs mb-5">
        <button
          role="tab"
          aria-selected={tab === "videos"}
          className="tab"
          onClick={() => setTab("videos")}
        >
          Videos
        </button>
        <button
          role="tab"
          aria-selected={tab === "screenshots"}
          aria-disabled
          className="tab"
          title="Coming soon"
        >
          Screenshots
        </button>
        <button
          role="tab"
          aria-selected={tab === "archive"}
          aria-disabled
          className="tab"
          title="Coming soon"
        >
          Archive
        </button>
        <span className="ml-auto text-xs text-text-tertiary">
          {filtered.length} {filtered.length === 1 ? "video" : "videos"}
        </span>
      </div>

      {/* Sub-toolbar */}
      <div className="flex flex-col sm:flex-row sm:items-center gap-3 mb-6">
        <label className="toolbar-input flex-1 max-w-md">
          <SearchIcon />
          <input
            type="search"
            placeholder="Search your videos"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
        <div className="flex items-center gap-3 sm:ml-auto">
          <select
            className="toolbar-select"
            value={dateFilter}
            onChange={(e) => setDateFilter(e.target.value as DateFilter)}
            aria-label="Filter by upload date"
          >
            {DATE_FILTERS.map((f) => (
              <option key={f.value} value={f.value}>
                {f.label}
              </option>
            ))}
          </select>
          <select
            className="toolbar-select"
            value={sort}
            onChange={(e) => setSort(e.target.value as SortOrder)}
            aria-label="Sort order"
          >
            {SORTS.map((s) => (
              <option key={s.value} value={s.value}>
                {s.label}
              </option>
            ))}
          </select>
        </div>
      </div>

      {/* Grid / empty states */}
      {tab !== "videos" ? (
        <ComingSoon label={tab === "screenshots" ? "Screenshots" : "Archive"} />
      ) : filtered.length === 0 && allVideos.length > 0 ? (
        <div className="card text-center py-16">
          <div className="text-4xl mb-3">🔍</div>
          <h2 className="font-heading text-lg font-bold text-text-primary mb-1">
            No videos match your filters
          </h2>
          <p className="text-text-secondary text-sm">
            Try a different search or date range.
          </p>
        </div>
      ) : filtered.length === 0 ? (
        <div className="card text-center py-16">
          <div className="text-5xl mb-4">🎬</div>
          <h2 className="font-heading text-xl font-bold text-text-primary mb-2">
            No recordings yet
          </h2>
          <p className="text-text-secondary max-w-md mx-auto">
            Record your screen with the NoCorny Tracer app and connect Dropbox
            to see your videos here.
          </p>
        </div>
      ) : (
        <VideoGrid videos={filtered} author={author} />
      )}
    </div>
  );
}

function ComingSoon({ label }: { label: string }) {
  return (
    <div className="card text-center py-16">
      <div className="text-4xl mb-3">🚧</div>
      <h2 className="font-heading text-lg font-bold text-text-primary mb-1">
        {label} coming soon
      </h2>
      <p className="text-text-secondary text-sm">
        This tab isn&apos;t available yet.
      </p>
    </div>
  );
}

function SearchIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="text-text-tertiary shrink-0"
      aria-hidden
    >
      <circle cx="11" cy="11" r="8" />
      <path d="m21 21-4.3-4.3" />
    </svg>
  );
}
