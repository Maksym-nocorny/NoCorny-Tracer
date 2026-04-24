import { db } from "@/lib/db";
import { dropboxConnections } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { encrypt, decrypt } from "@/lib/crypto";

const DROPBOX_API = "https://api.dropboxapi.com";
const DROPBOX_CONTENT_API = "https://content.dropboxapi.com";

export async function getDropboxTokens(userId: string) {
  const [conn] = await db
    .select()
    .from(dropboxConnections)
    .where(eq(dropboxConnections.userId, userId))
    .limit(1);

  if (!conn) return null;

  let accessToken = decrypt(conn.accessTokenEnc);

  // Refresh if expired
  if (conn.tokenExpiresAt && conn.tokenExpiresAt < new Date()) {
    const refreshToken = decrypt(conn.refreshTokenEnc);
    const refreshed = await refreshDropboxToken(refreshToken);

    accessToken = refreshed.access_token;

    await db
      .update(dropboxConnections)
      .set({
        accessTokenEnc: encrypt(refreshed.access_token),
        tokenExpiresAt: new Date(Date.now() + refreshed.expires_in * 1000),
      })
      .where(eq(dropboxConnections.userId, userId));
  }

  return { accessToken, cursor: conn.cursor };
}

async function refreshDropboxToken(refreshToken: string) {
  const res = await fetch("https://api.dropboxapi.com/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: process.env.DROPBOX_APP_KEY!,
      client_secret: process.env.DROPBOX_APP_SECRET!,
    }),
  });

  if (!res.ok) throw new Error("Failed to refresh Dropbox token");
  return res.json();
}

export async function dropboxListFolder(
  accessToken: string,
  cursor?: string | null
) {
  const url = cursor
    ? `${DROPBOX_API}/2/files/list_folder/continue`
    : `${DROPBOX_API}/2/files/list_folder`;

  const body = cursor
    ? { cursor }
    : { path: "", include_media_info: true };

  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) throw new Error(`Dropbox list_folder failed: ${res.status}`);
  return res.json();
}

export async function dropboxListSharedLinks(accessToken: string) {
  const links: Record<string, string> = {};
  let cursor: string | undefined;

  do {
    const body: Record<string, unknown> = cursor
      ? { cursor }
      : { direct_only: true };

    const res = await fetch(`${DROPBOX_API}/2/sharing/list_shared_links`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) break;
    const data = await res.json();

    for (const link of data.links || []) {
      links[link.path_lower] = link.url;
    }

    cursor = data.has_more ? data.cursor : undefined;
  } while (cursor);

  return links;
}

export async function dropboxMove(
  accessToken: string,
  fromPath: string,
  toPath: string
) {
  const res = await fetch(`${DROPBOX_API}/2/files/move_v2`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from_path: fromPath,
      to_path: toPath,
      autorename: true,
    }),
  });

  if (!res.ok) throw new Error(`Dropbox move failed: ${res.status}`);
  return res.json();
}

export async function dropboxDelete(accessToken: string, path: string) {
  const res = await fetch(`${DROPBOX_API}/2/files/delete_v2`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ path }),
  });

  if (!res.ok) throw new Error(`Dropbox delete failed: ${res.status}`);
  return res.json();
}

export async function dropboxGetThumbnail(
  accessToken: string,
  path: string
): Promise<string | null> {
  const arg = JSON.stringify({
    resource: { ".tag": "path", path },
    format: "jpeg",
    size: "w256h256",
    mode: "bestfit",
  });

  const res = await fetch(
    `${DROPBOX_CONTENT_API}/2/files/get_thumbnail_v2`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Dropbox-API-Arg": arg,
      },
    }
  );

  if (!res.ok) return null;

  const buffer = await res.arrayBuffer();
  const base64 = Buffer.from(buffer).toString("base64");
  return `data:image/jpeg;base64,${base64}`;
}
