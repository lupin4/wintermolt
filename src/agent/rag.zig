// Copyright The Fantastic Planet - By David Clabaugh
//
// rag.zig — Pinecone RAG (Retrieval-Augmented Generation) client
//
// Uses libcurl REST calls to Pinecone's integrated inference endpoints.
// Pinecone auto-embeds text using the model configured on the index
// (e.g., multilingual-e5-large, 1024D) — no separate embedding needed.
//
// Endpoints (integrated inference / records API):
//   POST {host}/records/namespaces/{ns}/search  — semantic search
//   POST {host}/records/namespaces/{ns}/upsert  — index records
//
// Headers: Api-Key, Content-Type: application/json, X-Pinecone-API-Version
//
// Record schema for Wintermolt conversations:
//   _id              — "{conv_id}-{seq}" unique per message
//   text             — message text content (auto-embedded by Pinecone)
//   conversation_id  — conversation UUID
//   role             — "user" or "assistant"
//   mode             — "repl", "chat", "single_shot"
//   timestamp        — Unix epoch seconds
//
// RAG failures never break the agentic loop — all public methods are
// designed for catch-and-ignore at the call site.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// ---------------------------------------------------------------------------
// libcurl extern declarations (same symbols as client.zig — single binary)
// ---------------------------------------------------------------------------

const CURL = opaque {};
const CurlSlist = opaque {};

extern fn curl_easy_init() ?*CURL;
extern fn curl_easy_cleanup(handle: *CURL) void;
extern fn curl_easy_perform(handle: *CURL) CurlCode;
extern fn curl_easy_getinfo(handle: *CURL, info: c_int, ...) CurlCode;
extern fn curl_easy_setopt(handle: *CURL, option: c_int, ...) CurlCode;
extern fn curl_slist_append(list: ?*CurlSlist, string: [*:0]const u8) ?*CurlSlist;
extern fn curl_slist_free_all(list: *CurlSlist) void;
extern fn curl_easy_strerror(code: CurlCode) [*:0]const u8;

const CurlCode = enum(c_int) { ok = 0, _ };

const CURLOPT_URL: c_int = 10002;
const CURLOPT_HTTPHEADER: c_int = 10023;
const CURLOPT_POSTFIELDS: c_int = 10015;
const CURLOPT_POSTFIELDSIZE: c_int = 60;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_POST: c_int = 47;
const CURLINFO_RESPONSE_CODE: c_int = 0x200002;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const SearchHit = struct {
    id: []const u8,
    text: []const u8,
    conversation_id: []const u8,
    role: []const u8,
    score: f64,
};

// ---------------------------------------------------------------------------
// RAG Client
// ---------------------------------------------------------------------------

pub const RagClient = struct {
    alloc: Allocator,
    api_key: []const u8,
    host: []const u8,
    namespace: []const u8,

    pub fn init(
        alloc: Allocator,
        api_key: []const u8,
        host: []const u8,
    ) RagClient {
        return .{
            .alloc = alloc,
            .api_key = api_key,
            .host = host,
            .namespace = "conversations",
        };
    }

    /// Search for semantically similar past messages.
    /// Returns top-k hits sorted by relevance score.
    /// Caller owns the returned slice — free with freeHits().
    pub fn search(self: *const RagClient, query_text: []const u8, top_k: usize) ![]SearchHit {
        // Build URL: {host}/records/namespaces/conversations/search
        const url = try std.fmt.allocPrint(
            self.alloc,
            "{s}/records/namespaces/{s}/search",
            .{ self.host, self.namespace },
        );
        defer self.alloc.free(url);

        // Build request body
        var body_buf: ArrayList(u8) = .{};
        const w = body_buf.writer(self.alloc);
        try w.writeAll("{\"query\":{\"inputs\":{\"text\":");
        try writeJsonQuoted(w, query_text);
        try w.writeAll("},\"top_k\":");
        try std.fmt.format(w, "{d}", .{top_k});
        try w.writeAll("}}");
        const body = try body_buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(body);

        // POST to Pinecone (search uses application/json)
        const response = try self.doPost(url, body, "application/json");
        defer self.alloc.free(response);

        // Parse hits from response JSON
        return self.parseSearchResponse(response);
    }

    /// Index a single message into Pinecone for future RAG retrieval.
    /// The text field is auto-embedded by Pinecone's integrated inference model.
    pub fn indexMessage(
        self: *const RagClient,
        conv_id: []const u8,
        role: []const u8,
        seq: usize,
        text: []const u8,
        mode: []const u8,
        timestamp: i64,
    ) !void {
        // Build URL: {host}/records/namespaces/conversations/upsert
        const url = try std.fmt.allocPrint(
            self.alloc,
            "{s}/records/namespaces/{s}/upsert",
            .{ self.host, self.namespace },
        );
        defer self.alloc.free(url);

        // Record ID: "{conv_id}-{seq}" — unique per message
        const record_id = try std.fmt.allocPrint(self.alloc, "{s}-{d}", .{ conv_id, seq });
        defer self.alloc.free(record_id);

        // Build NDJSON body: flat record (Pinecone records API uses application/x-ndjson)
        var body_buf: ArrayList(u8) = .{};
        const w = body_buf.writer(self.alloc);
        try w.writeAll("{\"_id\":");
        try writeJsonQuoted(w, record_id);
        try w.writeAll(",\"text\":");
        try writeJsonQuoted(w, text);
        try w.writeAll(",\"conversation_id\":");
        try writeJsonQuoted(w, conv_id);
        try w.writeAll(",\"role\":");
        try writeJsonQuoted(w, role);
        try w.writeAll(",\"mode\":");
        try writeJsonQuoted(w, mode);
        try w.writeAll(",\"timestamp\":");
        try std.fmt.format(w, "{d}", .{timestamp});
        try w.writeAll("}");
        const body = try body_buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(body);

        const response = try self.doPost(url, body, "application/x-ndjson");
        self.alloc.free(response);
    }

    /// Batch upsert multiple message records. Used by the --index command
    /// to backfill Pinecone from SQLite history.
    pub fn indexBatch(
        self: *const RagClient,
        records_json: []const u8,
    ) !void {
        const url = try std.fmt.allocPrint(
            self.alloc,
            "{s}/records/namespaces/{s}/upsert",
            .{ self.host, self.namespace },
        );
        defer self.alloc.free(url);

        const response = try self.doPost(url, records_json, "application/x-ndjson");
        self.alloc.free(response);
    }

    /// Build RAG context string from search hits for system prompt injection.
    /// Formats hits into a readable block that gets appended to the system prompt.
    /// Returns empty string if no hits. Caller owns returned slice.
    pub fn buildRagContext(self: *const RagClient, hits: []const SearchHit) ![]u8 {
        if (hits.len == 0) return self.alloc.dupe(u8, "");

        var buf: ArrayList(u8) = .{};
        const w = buf.writer(self.alloc);

        try w.writeAll(
            \\
            \\--- Relevant past conversations ---
            \\The following are semantically similar messages from previous conversations.
            \\Use this context to personalize your response and remember past interactions.
            \\
        );

        for (hits, 0..) |hit, i| {
            try std.fmt.format(w, "\n[{d}] ({s}):\n{s}\n", .{
                i + 1,
                hit.role,
                hit.text,
            });
        }

        try w.writeAll(
            \\
            \\--- End of past context ---
            \\
        );

        return buf.toOwnedSlice(self.alloc);
    }

    /// Build knowledge context from domain-specific namespace hits.
    /// Unlike buildRagContext (conversations), this formats hits as reference documentation.
    /// domain_label: human-readable name like "Blender API" or "forKernels Docs".
    pub fn buildKnowledgeContext(self: *const RagClient, hits: []const SearchHit, domain_label: []const u8) ![]u8 {
        if (hits.len == 0) return self.alloc.dupe(u8, "");

        var buf: ArrayList(u8) = .{};
        const w = buf.writer(self.alloc);

        try std.fmt.format(w,
            "\n\n--- {s} Reference ---\n" ++
            "The following are relevant documentation entries from the {s} knowledge base.\n" ++
            "Use this reference data to generate accurate, version-correct code.\n",
            .{ domain_label, domain_label },
        );

        for (hits, 0..) |hit, i| {
            try std.fmt.format(w, "\n[{d}] (score: {d:.2}):\n{s}\n", .{
                i + 1,
                hit.score,
                hit.text,
            });
        }

        try std.fmt.format(w, "\n--- End {s} Reference ---\n", .{domain_label});

        return buf.toOwnedSlice(self.alloc);
    }

    /// Search with an explicit namespace override (e.g., "core_memory").
    pub fn searchInNamespace(self: *const RagClient, query_text: []const u8, top_k: usize, ns: []const u8) ![]SearchHit {
        const url = try std.fmt.allocPrint(
            self.alloc,
            "{s}/records/namespaces/{s}/search",
            .{ self.host, ns },
        );
        defer self.alloc.free(url);

        var body_buf: ArrayList(u8) = .{};
        const w = body_buf.writer(self.alloc);
        try w.writeAll("{\"query\":{\"inputs\":{\"text\":");
        try writeJsonQuoted(w, query_text);
        try w.writeAll("},\"top_k\":");
        try std.fmt.format(w, "{d}", .{top_k});
        try w.writeAll("}}");
        const body = try body_buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(body);

        const response = try self.doPost(url, body, "application/json");
        defer self.alloc.free(response);
        return self.parseSearchResponse(response);
    }

    /// Upsert a single record into an explicit namespace.
    /// body should be a single NDJSON line (flat JSON object with _id and text fields).
    pub fn upsertInNamespace(self: *const RagClient, body: []const u8, ns: []const u8) !void {
        const url = try std.fmt.allocPrint(
            self.alloc,
            "{s}/records/namespaces/{s}/upsert",
            .{ self.host, ns },
        );
        defer self.alloc.free(url);
        const response = try self.doPost(url, body, "application/x-ndjson");
        self.alloc.free(response);
    }

    /// Free a SearchHit slice returned by search().
    pub fn freeHits(self: *const RagClient, hits: []SearchHit) void {
        for (hits) |hit| {
            self.alloc.free(hit.id);
            self.alloc.free(hit.text);
            self.alloc.free(hit.conversation_id);
            self.alloc.free(hit.role);
        }
        self.alloc.free(hits);
    }

    // -----------------------------------------------------------------------
    // Private: HTTP POST via libcurl
    // -----------------------------------------------------------------------

    fn doPost(self: *const RagClient, url: []const u8, body: []const u8, content_type: []const u8) ![]u8 {
        const handle = curl_easy_init() orelse return error.CurlInitFailed;
        defer curl_easy_cleanup(handle);

        // URL (null-terminate for curl)
        const url_z = try self.alloc.dupeZ(u8, url);
        defer self.alloc.free(url_z);
        _ = curl_easy_setopt(handle, CURLOPT_URL, url_z.ptr);

        // Headers
        var headers: ?*CurlSlist = null;
        defer if (headers) |h| curl_slist_free_all(h);

        // Content-Type: application/json for search, application/x-ndjson for upsert
        var ct_buf: [128]u8 = undefined;
        const ct_header = std.fmt.bufPrintZ(&ct_buf, "Content-Type: {s}", .{content_type}) catch return error.ContentTypeTooLong;
        headers = curl_slist_append(headers, ct_header);
        headers = curl_slist_append(headers, "X-Pinecone-API-Version: 2025-04");

        var key_header_buf: [512]u8 = undefined;
        const key_header = std.fmt.bufPrintZ(
            &key_header_buf,
            "Api-Key: {s}",
            .{self.api_key},
        ) catch return error.ApiKeyTooLong;
        headers = curl_slist_append(headers, key_header);

        _ = curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);

        // POST body
        _ = curl_easy_setopt(handle, CURLOPT_POST, @as(c_long, 1));
        const body_z = try self.alloc.dupeZ(u8, body);
        defer self.alloc.free(body_z);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body_z.ptr);
        _ = curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));

        // Response buffer (wraps ArrayList + allocator for the callback)
        var resp = ResponseBuffer{ .alloc = self.alloc };
        defer resp.buf.deinit(self.alloc); // safety net if we error before toOwnedSlice

        _ = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, &writeCallback);
        _ = curl_easy_setopt(handle, CURLOPT_WRITEDATA, &resp);

        // Perform request
        const result = curl_easy_perform(handle);
        if (result != .ok) {
            const err_msg = curl_easy_strerror(result);
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[rag] curl error: {s}\n", .{err_msg}) catch {};
            return error.CurlRequestFailed;
        }

        // Check HTTP status
        var http_code: c_long = 0;
        _ = curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);
        if (http_code < 200 or http_code >= 300) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("[rag] HTTP {d}\n", .{http_code}) catch {};
            // Log first 500 chars of response body for debugging
            if (resp.buf.items.len > 0) {
                const preview_len = @min(resp.buf.items.len, 500);
                stderr.print("[rag] Response: {s}\n", .{resp.buf.items[0..preview_len]}) catch {};
            }
            return error.PineconeHttpError;
        }

        // Transfer ownership of the buffer contents
        const owned = try resp.buf.toOwnedSlice(self.alloc);
        return owned;
    }

    // -----------------------------------------------------------------------
    // Private: JSON response parsing
    // -----------------------------------------------------------------------

    /// Parse Pinecone search response to extract hits.
    /// Response format:
    ///   {"result":{"hits":[{"_id":"...","fields":{"text":"...","conversation_id":"...","role":"..."},"_score":0.95}]}}
    fn parseSearchResponse(self: *const RagClient, json: []const u8) ![]SearchHit {
        var hits: ArrayList(SearchHit) = .{};
        errdefer {
            for (hits.items) |hit| {
                self.alloc.free(hit.id);
                self.alloc.free(hit.text);
                self.alloc.free(hit.conversation_id);
                self.alloc.free(hit.role);
            }
            hits.deinit(self.alloc);
        }

        // Find "hits" array
        const hits_key = std.mem.indexOf(u8, json, "\"hits\"") orelse
            return hits.toOwnedSlice(self.alloc);
        const bracket_start = std.mem.indexOfPos(u8, json, hits_key, "[") orelse
            return hits.toOwnedSlice(self.alloc);

        var pos = bracket_start + 1;

        // Iterate over hit objects in the array
        while (pos < json.len) {
            // Skip whitespace and commas
            while (pos < json.len and (json[pos] == ' ' or json[pos] == ',' or
                json[pos] == '\n' or json[pos] == '\r' or json[pos] == '\t')) : (pos += 1)
            {}

            // Check for array end
            if (pos >= json.len or json[pos] == ']') break;

            // Expect opening brace
            if (json[pos] != '{') break;

            // Find matching closing brace (handles nested "fields" object)
            const obj_end = findMatchingBrace(json, pos) orelse break;
            const hit_json = json[pos .. obj_end + 1];

            // Extract _id and _score from top level
            const id = extractJsonString(hit_json, "\"_id\"") orelse "";
            const score = extractJsonNumber(hit_json, "\"_score\"");

            // Extract fields from nested "fields" object
            var text: []const u8 = "";
            var conv_id: []const u8 = "";
            var role: []const u8 = "";

            if (std.mem.indexOf(u8, hit_json, "\"fields\"")) |fields_key| {
                if (std.mem.indexOfPos(u8, hit_json, fields_key, "{")) |fb| {
                    if (findMatchingBrace(hit_json, fb)) |fe| {
                        const fields_json = hit_json[fb .. fe + 1];
                        text = extractJsonString(fields_json, "\"text\"") orelse "";
                        conv_id = extractJsonString(fields_json, "\"conversation_id\"") orelse "";
                        role = extractJsonString(fields_json, "\"role\"") orelse "";
                    }
                }
            }

            try hits.append(self.alloc, .{
                .id = try self.alloc.dupe(u8, id),
                .text = try self.alloc.dupe(u8, text),
                .conversation_id = try self.alloc.dupe(u8, conv_id),
                .role = try self.alloc.dupe(u8, role),
                .score = score,
            });

            pos = obj_end + 1;
        }

        return hits.toOwnedSlice(self.alloc);
    }
};

// ---------------------------------------------------------------------------
// Response buffer for curl callback (holds ArrayList + Allocator together)
// ---------------------------------------------------------------------------

const ResponseBuffer = struct {
    buf: ArrayList(u8) = .{},
    alloc: Allocator,
};

/// curl write callback — captures response body into ResponseBuffer.
fn writeCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *ResponseBuffer,
) callconv(.c) usize {
    const total = size * nmemb;
    userdata.buf.appendSlice(userdata.alloc, ptr[0..total]) catch return 0;
    return total;
}

// ---------------------------------------------------------------------------
// JSON helpers (minimal extraction for Pinecone response parsing)
// ---------------------------------------------------------------------------

/// Write a JSON-escaped string with surrounding quotes.
pub fn writeJsonQuoted(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(w, "\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Extract a JSON string value after a key like `"_id"`.
/// Returns a slice into the input json (not allocated).
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = key_pos + key.len;

    // Skip whitespace and colon
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or
        json[pos] == '\t' or json[pos] == '\n' or json[pos] == '\r')) : (pos += 1)
    {}

    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1; // skip opening quote

    const start = pos;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            pos += 1; // skip escaped char
            continue;
        }
        if (json[pos] == '"') {
            return json[start..pos];
        }
    }
    return null;
}

/// Extract a numeric value (f64) after a JSON key.
fn extractJsonNumber(json: []const u8, key: []const u8) f64 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return 0;
    var pos = key_pos + key.len;

    // Skip whitespace and colon
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or
        json[pos] == '\t' or json[pos] == '\n' or json[pos] == '\r')) : (pos += 1)
    {}

    const start = pos;
    while (pos < json.len) : (pos += 1) {
        const c = json[pos];
        if ((c >= '0' and c <= '9') or c == '.' or c == '-' or
            c == 'e' or c == 'E' or c == '+') continue;
        break;
    }

    if (pos == start) return 0;
    return std.fmt.parseFloat(f64, json[start..pos]) catch 0;
}

/// Find the matching closing brace for an opening '{' at the given position.
/// Correctly handles nested braces and JSON string escapes.
fn findMatchingBrace(json: []const u8, open_pos: usize) ?usize {
    var depth: usize = 0;
    var pos = open_pos;
    var in_string = false;

    while (pos < json.len) : (pos += 1) {
        if (in_string) {
            if (json[pos] == '\\') {
                pos += 1; // skip escaped character
                continue;
            }
            if (json[pos] == '"') in_string = false;
            continue;
        }

        switch (json[pos]) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return pos;
            },
            else => {},
        }
    }
    return null;
}
