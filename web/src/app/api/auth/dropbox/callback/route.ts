import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { dropboxConnections } from "@/lib/db/schema";
import { encrypt } from "@/lib/crypto";

// GET /api/auth/dropbox/callback — Dropbox OAuth2 callback
export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.redirect(new URL("/login", process.env.AUTH_URL));
  }

  const code = req.nextUrl.searchParams.get("code");
  const codeVerifier = req.cookies.get("dbx_verifier")?.value;

  if (!code || !codeVerifier) {
    return NextResponse.redirect(
      new URL("/dashboard/settings?error=missing_code", process.env.AUTH_URL)
    );
  }

  const redirectUri = `${process.env.AUTH_URL}/api/auth/dropbox/callback`;

  // Exchange code for tokens
  const tokenRes = await fetch("https://api.dropboxapi.com/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      grant_type: "authorization_code",
      client_id: process.env.DROPBOX_APP_KEY!,
      client_secret: process.env.DROPBOX_APP_SECRET!,
      redirect_uri: redirectUri,
      code_verifier: codeVerifier,
    }),
  });

  if (!tokenRes.ok) {
    return NextResponse.redirect(
      new URL("/dashboard/settings?error=token_exchange", process.env.AUTH_URL)
    );
  }

  const tokens = await tokenRes.json();

  // Get Dropbox account ID
  const accountRes = await fetch(
    "https://api.dropboxapi.com/2/users/get_current_account",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${tokens.access_token}`,
        "Content-Type": "application/json",
      },
      body: "null",
    }
  );

  const account = await accountRes.json();

  // Upsert connection
  await db
    .insert(dropboxConnections)
    .values({
      userId: session.user.id,
      dropboxAccountId: tokens.account_id || account.account_id,
      accessTokenEnc: encrypt(tokens.access_token),
      refreshTokenEnc: encrypt(tokens.refresh_token),
      tokenExpiresAt: new Date(Date.now() + tokens.expires_in * 1000),
    })
    .onConflictDoUpdate({
      target: dropboxConnections.userId,
      set: {
        dropboxAccountId: tokens.account_id || account.account_id,
        accessTokenEnc: encrypt(tokens.access_token),
        refreshTokenEnc: encrypt(tokens.refresh_token),
        tokenExpiresAt: new Date(Date.now() + tokens.expires_in * 1000),
      },
    });

  // Clear the verifier cookie
  const response = NextResponse.redirect(
    new URL("/dashboard/settings?dropbox=connected", process.env.AUTH_URL)
  );
  response.cookies.delete("dbx_verifier");

  return response;
}
