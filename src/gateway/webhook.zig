// Copyright The Fantastic Planet - By David Clabaugh
//
// webhook.zig — Inbound webhook handler
//
// Receives HTTP POST payloads from external services (GitHub, CI/CD, custom
// integrations) and converts them to agent messages. Runs inside the gateway
// sidecar context.
//
// Authentication: HMAC-SHA256 signature verification via WINTERMOLT_WEBHOOK_SECRET
//
// Protocol:
//   POST /webhook
//   Headers:
//     X-Webhook-Signature: sha256=<hex-digest>
//     Content-Type: application/json
//   Body: {"event": "...", "data": {...}}
//
// The webhook converts the payload into a chat message and routes it to the
// appropriate agent via the standard IPC bridge.

const std = @import("std");
const compat = @import("../compat.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Parsed webhook payload.
pub const WebhookPayload = struct {
    event: []const u8,
    source: []const u8,
    data_json: []const u8, // Raw JSON body
    signature_valid: bool,
};

/// Verify HMAC-SHA256 signature.
/// Expected format: "sha256=<hex-digest>"
pub fn verifySignature(body: []const u8, signature_header: []const u8, secret: []const u8) bool {
    if (!std.mem.startsWith(u8, signature_header, "sha256=")) return false;
    const provided_hex = signature_header["sha256=".len..];
    if (provided_hex.len != 64) return false; // SHA-256 = 32 bytes = 64 hex chars

    // Compute HMAC-SHA256
    var mac: [32]u8 = undefined;
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    HmacSha256.create(&mac, body, secret);

    // Convert to hex and compare
    const hex = "0123456789abcdef";
    var expected: [64]u8 = undefined;
    for (mac, 0..) |b, i| {
        expected[i * 2] = hex[b >> 4];
        expected[i * 2 + 1] = hex[b & 0x0f];
    }

    return std.mem.eql(u8, &expected, provided_hex);
}

/// Parse a webhook payload from raw JSON body.
pub fn parsePayload(alloc: Allocator, body: []const u8, signature: ?[]const u8) !WebhookPayload {
    const secret = compat.getenv("WINTERMOLT_WEBHOOK_SECRET");

    const sig_valid = if (signature) |sig| blk: {
        if (secret) |s| {
            break :blk verifySignature(body, sig, s);
        }
        break :blk false;
    } else blk: {
        // No signature provided — valid only if no secret configured
        break :blk secret == null;
    };

    // Extract event type from JSON
    const sse = @import("../api/sse.zig");
    const event = sse.findJsonString(body, "event") orelse
        sse.findJsonString(body, "action") orelse "webhook";
    const source = sse.findJsonString(body, "source") orelse
        sse.findJsonString(body, "repository") orelse "external";

    return WebhookPayload{
        .event = event,
        .source = source,
        .data_json = try alloc.dupe(u8, body),
        .signature_valid = sig_valid,
    };
}

/// Format a webhook payload as a message for the agent.
pub fn formatAsMessage(alloc: Allocator, payload: *const WebhookPayload) ![]u8 {
    const verified = if (payload.signature_valid) " (verified)" else " (UNVERIFIED)";
    const preview = if (payload.data_json.len > 500) payload.data_json[0..500] else payload.data_json;

    return std.fmt.allocPrint(alloc,
        \\[Webhook{s}] Event: {s} | Source: {s}
        \\Payload:
        \\{s}
    , .{ verified, payload.event, payload.source, preview });
}
