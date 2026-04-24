import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { getDropboxTokens } from "@/lib/dropbox";

const MAX_BYTES = 5 * 1024 * 1024; // 5 MB

// POST /api/user/avatar — multipart/form-data { file: <image> }
// Uploads the image to the user's Dropbox at a fixed path (/avatar.<ext>),
// overwriting any previous avatar. Returns a raw Dropbox share URL with a
// cache-busting version token, and stores it as users.image.
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const form = await req.formData().catch(() => null);
  const file = form?.get("file");
  if (!(file instanceof File)) {
    return NextResponse.json({ error: "file is required" }, { status: 400 });
  }
  if (!file.type.startsWith("image/")) {
    return NextResponse.json({ error: "file must be an image" }, { status: 400 });
  }
  if (file.size > MAX_BYTES) {
    return NextResponse.json({ error: "image is too large (max 5 MB)" }, { status: 413 });
  }

  const tokens = await getDropboxTokens(session.user.id);
  if (!tokens) {
    return NextResponse.json(
      { error: "Connect Dropbox first to upload avatar" },
      { status: 409 }
    );
  }

  // Fixed filename per user's Dropbox — subsequent uploads overwrite it.
  // Each user has their own Dropbox, so no cross-user collision.
  const ext = (file.type.split("/")[1] || "jpg").toLowerCase().replace("jpeg", "jpg");
  const path = `/avatar.${ext}`;
  const bytes = Buffer.from(await file.arrayBuffer());

  const uploadRes = await fetch("https://content.dropboxapi.com/2/files/upload", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${tokens.accessToken}`,
      "Content-Type": "application/octet-stream",
      "Dropbox-API-Arg": JSON.stringify({
        path,
        mode: "overwrite",
        autorename: false,
        mute: true,
      }),
    },
    body: new Uint8Array(bytes),
  });
  if (!uploadRes.ok) {
    const text = await uploadRes.text().catch(() => "");
    return NextResponse.json(
      { error: `Dropbox upload failed (${uploadRes.status})`, detail: text },
      { status: 502 }
    );
  }

  const sharedUrl = await createOrGetSharedLink(tokens.accessToken, path);
  if (!sharedUrl) {
    return NextResponse.json({ error: "Failed to create share link" }, { status: 502 });
  }

  // Dropbox share URLs render an HTML landing page by default — `raw=1` makes
  // the response the actual bytes so <img src> works. We also bust the cache
  // because overwrite keeps the same URL.
  const versioned = toRawWithVersion(sharedUrl);

  const [updated] = await db
    .update(users)
    .set({ image: versioned, updatedAt: new Date() })
    .where(eq(users.id, session.user.id))
    .returning({
      id: users.id,
      name: users.name,
      email: users.email,
      image: users.image,
    });

  return NextResponse.json(updated);
}

export const runtime = "nodejs";
export const maxDuration = 30;

async function createOrGetSharedLink(
  accessToken: string,
  path: string
): Promise<string | null> {
  // Try create. If already shared, fall back to listing.
  const createRes = await fetch(
    "https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        path,
        settings: { requested_visibility: "public" },
      }),
    }
  );

  let url: string | undefined;
  if (createRes.ok) {
    url = (await createRes.json()).url;
  } else {
    const listRes = await fetch(
      "https://api.dropboxapi.com/2/sharing/list_shared_links",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ path, direct_only: true }),
      }
    );
    if (!listRes.ok) return null;
    const data = await listRes.json();
    url = data.links?.[0]?.url;
  }

  return url ?? null;
}

function toRawWithVersion(shareUrl: string): string {
  try {
    const u = new URL(shareUrl);
    u.searchParams.delete("dl");
    u.searchParams.set("raw", "1");
    u.searchParams.set("v", String(Date.now()));
    return u.toString();
  } catch {
    return shareUrl;
  }
}
