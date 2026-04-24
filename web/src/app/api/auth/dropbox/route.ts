import { NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { randomBytes, createHash } from "crypto";

// GET /api/auth/dropbox — initiate Dropbox OAuth2 PKCE
export async function GET() {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.redirect(new URL("/login", process.env.AUTH_URL));
  }

  const codeVerifier = randomBytes(32).toString("base64url");
  const codeChallenge = createHash("sha256")
    .update(codeVerifier)
    .digest("base64url");

  // Store code_verifier in a short-lived cookie
  const redirectUri = `${process.env.AUTH_URL}/api/auth/dropbox/callback`;

  const params = new URLSearchParams({
    client_id: process.env.DROPBOX_APP_KEY!,
    redirect_uri: redirectUri,
    response_type: "code",
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
    token_access_type: "offline",
    state: session.user.id,
  });

  const authUrl = `https://www.dropbox.com/oauth2/authorize?${params}`;

  const response = NextResponse.redirect(authUrl);
  response.cookies.set("dbx_verifier", codeVerifier, {
    httpOnly: true,
    secure: true,
    sameSite: "lax",
    maxAge: 600, // 10 minutes
    path: "/api/auth/dropbox",
  });

  return response;
}
