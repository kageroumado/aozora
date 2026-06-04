#!/usr/bin/env node
/**
 * Anthropic SDK Proxy — thin Node.js process that the Swift daemon calls
 * for API requests. Required because OAuth tokens (sk-ant-oat*) only work
 * through the @anthropic-ai/sdk library, not raw HTTP.
 *
 * Protocol:
 *   stdin  → JSON request: { body: {...}, stream: bool, token: string }
 *   stdout → JSON response lines:
 *     Non-streaming: { type: "response", data: {...} }
 *     Streaming:     { type: "delta", data: {...} } per event
 *                    { type: "done", data: {...} } at end
 *     Error:         { type: "error", message: "..." }
 *
 * The process exits after handling one request.
 */

import Anthropic from "@anthropic-ai/sdk";
import { readFileSync } from "fs";

// Read the full request from stdin
const input = readFileSync(0, "utf8");
let req;
try {
  req = JSON.parse(input);
} catch (e) {
  console.log(JSON.stringify({ type: "error", message: `Invalid JSON input: ${e.message}` }));
  process.exit(1);
}

const { body, stream, token } = req;

if (!token || !body) {
  console.log(JSON.stringify({ type: "error", message: "Missing 'token' or 'body' in request" }));
  process.exit(1);
}

// Create the SDK client with OAuth token support.
// The SDK internally handles the Bearer auth, beta headers, and whatever
// request construction magic makes OAuth tokens work.
const isOAuth = token.includes("sk-ant-oat");
const client = new Anthropic(
  isOAuth
    ? {
        apiKey: null,
        authToken: token,
        dangerouslyAllowBrowser: true,
        defaultHeaders: {
          accept: "application/json",
          "anthropic-dangerous-direct-browser-access": "true",
          "anthropic-beta":
            "claude-code-20250219,oauth-2025-04-20,prompt-caching-2024-07-31,fine-grained-tool-streaming-2025-05-14",
          "user-agent": "Aozora/1.0 (via anthropic-sdk-proxy)",
          "x-app": "cli",
        },
      }
    : { apiKey: token },
);

try {
  if (stream) {
    // Streaming mode: emit delta events line by line
    const response = await client.messages.create({ ...body, stream: true });

    for await (const event of response) {
      console.log(JSON.stringify({ type: "event", data: event }));
    }
    console.log(JSON.stringify({ type: "done" }));
  } else {
    // Non-streaming: single response
    const response = await client.messages.create({ ...body, stream: false });
    console.log(JSON.stringify({ type: "response", data: response }));
  }
} catch (e) {
  const errorData = {
    type: "error",
    message: e.message || String(e),
    status: e.status,
    error: e.error,
  };
  console.log(JSON.stringify(errorData));
  process.exit(1);
}
