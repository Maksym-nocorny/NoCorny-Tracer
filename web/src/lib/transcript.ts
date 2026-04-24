import type { TranscriptSegment } from "@/lib/db/schema";

function parseTimestamp(ts: string): number {
  const m = ts.trim().match(/^(\d+):(\d+):(\d+)[,.](\d+)$/);
  if (!m) return 0;
  const [, h, min, s, ms] = m;
  return (
    Number(h) * 3600 +
    Number(min) * 60 +
    Number(s) +
    Number(ms.padEnd(3, "0").slice(0, 3)) / 1000
  );
}

export function parseSrt(srt: string): TranscriptSegment[] {
  const normalized = srt.replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim();
  if (!normalized) return [];

  const blocks = normalized.split(/\n\s*\n/);
  const segments: TranscriptSegment[] = [];

  for (const block of blocks) {
    const lines = block.split("\n").filter((l) => l.trim().length > 0);
    if (lines.length < 2) continue;

    const timeLineIdx = lines[0].includes("-->") ? 0 : 1;
    const timeLine = lines[timeLineIdx];
    const timeMatch = timeLine.match(/([\d:,.]+)\s*-->\s*([\d:,.]+)/);
    if (!timeMatch) continue;

    const start = parseTimestamp(timeMatch[1]);
    const end = parseTimestamp(timeMatch[2]);
    const text = lines
      .slice(timeLineIdx + 1)
      .join(" ")
      .replace(/\s+/g, " ")
      .trim();
    if (!text) continue;

    segments.push({ start, end, text });
  }

  return segments;
}

function formatVttTimestamp(seconds: number): string {
  const safe = Math.max(0, seconds);
  const h = Math.floor(safe / 3600);
  const m = Math.floor((safe % 3600) / 60);
  const s = Math.floor(safe % 60);
  const ms = Math.round((safe - Math.floor(safe)) * 1000);
  const pad = (n: number, len = 2) => String(n).padStart(len, "0");
  return `${pad(h)}:${pad(m)}:${pad(s)}.${pad(ms, 3)}`;
}

export function segmentsToVtt(segments: TranscriptSegment[]): string {
  const parts = ["WEBVTT", ""];
  for (const seg of segments) {
    parts.push(
      `${formatVttTimestamp(seg.start)} --> ${formatVttTimestamp(seg.end)}`
    );
    parts.push(seg.text);
    parts.push("");
  }
  return parts.join("\n");
}
