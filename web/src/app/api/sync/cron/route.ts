import { NextResponse } from "next/server";
import { db } from "@/lib/db";
import { dropboxConnections } from "@/lib/db/schema";
import { syncUserDropbox } from "@/app/api/webhooks/dropbox/route";

// GET /api/sync/cron — Vercel cron job (every 15 min)
export async function GET() {
  const connections = await db.select().from(dropboxConnections);

  const results: { userId: string; ok: boolean; error?: string }[] = [];

  for (const conn of connections) {
    try {
      await syncUserDropbox(conn.userId);
      results.push({ userId: conn.userId, ok: true });
    } catch (e) {
      results.push({
        userId: conn.userId,
        ok: false,
        error: String(e),
      });
    }
  }

  return NextResponse.json({ synced: results.length, results });
}
