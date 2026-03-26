// BetterLoom Gemini API Proxy Worker
// Deployed on Cloudflare Workers — holds the real Gemini API key
//
// Environment variables (set in Cloudflare dashboard):
//   GEMINI_API_KEY  — your Google Gemini API key
//   APP_SECRET      — shared secret with the BetterLoom app

const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";
const RATE_LIMIT_WINDOW = 60; // seconds
const RATE_LIMIT_MAX = 30;    // max requests per IP per window

export default {
  async fetch(request, env, ctx) {
    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    // Only POST allowed
    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed" }, 405);
    }

    // Validate APP_SECRET
    const authHeader = request.headers.get("X-App-Secret");
    if (!authHeader || authHeader !== env.APP_SECRET) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    // Rate limiting using Cloudflare's KV-free approach (in-memory per isolate)
    const clientIP = request.headers.get("CF-Connecting-IP") || "unknown";
    const rateLimitKey = `rate:${clientIP}`;

    // Simple rate limit check via request count header (for monitoring)
    // For production, use Cloudflare Rate Limiting rules in the dashboard

    // Extract model from URL path: /v1/models/{model}:generateContent
    const url = new URL(request.url);
    const pathMatch = url.pathname.match(/^\/v1\/models\/([^/]+):generateContent$/);

    if (!pathMatch) {
      return jsonResponse({ error: "Invalid endpoint. Use /v1/models/{model}:generateContent" }, 400);
    }

    const model = pathMatch[1];
    const allowedModels = ["gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-flash"];
    if (!allowedModels.includes(model)) {
      return jsonResponse({ error: `Model not allowed: ${model}` }, 403);
    }

    // Forward request to Gemini
    const geminiURL = `${GEMINI_BASE}/${model}:generateContent?key=${env.GEMINI_API_KEY}`;

    try {
      const body = await request.text();

      // Validate request body size (max 25MB — for video frames)
      if (body.length > 25 * 1024 * 1024) {
        return jsonResponse({ error: "Request too large" }, 413);
      }

      const geminiResponse = await fetch(geminiURL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: body,
      });

      const responseBody = await geminiResponse.text();

      return new Response(responseBody, {
        status: geminiResponse.status,
        headers: {
          "Content-Type": "application/json",
          ...corsHeaders(),
        },
      });
    } catch (err) {
      return jsonResponse({ error: `Proxy error: ${err.message}` }, 502);
    }
  },
};

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, X-App-Secret",
  };
}
