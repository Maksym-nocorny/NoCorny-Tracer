import { NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { syncUserDropbox } from "@/app/api/webhooks/dropbox/route";

// POST /api/sync/dropbox — manual sync trigger
export async function POST() {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  try {
    await syncUserDropbox(session.user.id);
    return NextResponse.json({ ok: true });
  } catch (e) {
    console.error("Manual sync failed:", e);
    return NextResponse.json({ error: "Sync failed" }, { status: 500 });
  }
}
