// Copyright The Fantastic Planet - By David Clabaugh
//
// google.zig — Google Workspace tool (Gmail, Calendar, Drive)
//
// Unified tool for interacting with Google APIs via OAuth2.
// Requires: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN
//
// Services:
//   gmail    — search, read, send, draft, labels
//   calendar — list events, create event, find free time
//   drive    — list, search, download, upload metadata

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const sse = @import("../api/sse.zig");
const google_auth = @import("google_auth.zig");

/// Execute the google_workspace tool.
/// Input: {"service": "gmail|calendar|drive", "operation": "...", ...}
pub fn executeTool(alloc: Allocator, input_json: []const u8) ![]u8 {
    var auth = google_auth.GoogleAuth.init(alloc);
    defer auth.deinit();

    if (!auth.isConfigured()) {
        return alloc.dupe(u8,
            \\Error: Google API not configured.
            \\
            \\Required environment variables:
            \\  GOOGLE_CLIENT_ID     — OAuth2 client ID
            \\  GOOGLE_CLIENT_SECRET — OAuth2 client secret
            \\  GOOGLE_REFRESH_TOKEN — OAuth2 refresh token
            \\
            \\Get credentials at: https://console.cloud.google.com/apis/credentials
            \\Enable APIs: Gmail, Calendar, Drive
        );
    }

    const service = sse.findJsonString(input_json, "service") orelse
        return alloc.dupe(u8, "Error: 'service' field required. Options: gmail, calendar, drive");

    if (std.mem.eql(u8, service, "gmail")) {
        return executeGmail(alloc, &auth, input_json);
    } else if (std.mem.eql(u8, service, "calendar")) {
        return executeCalendar(alloc, &auth, input_json);
    } else if (std.mem.eql(u8, service, "drive")) {
        return executeDrive(alloc, &auth, input_json);
    }

    return std.fmt.allocPrint(alloc, "Error: Unknown service '{s}'. Options: gmail, calendar, drive", .{service});
}

// ---------------------------------------------------------------------------
// Gmail
// ---------------------------------------------------------------------------

fn executeGmail(alloc: Allocator, auth: *google_auth.GoogleAuth, input_json: []const u8) ![]u8 {
    const operation = sse.findJsonString(input_json, "operation") orelse "list";

    if (std.mem.eql(u8, operation, "search") or std.mem.eql(u8, operation, "list")) {
        const query = sse.findJsonString(input_json, "query") orelse "in:inbox is:unread";
        const max_str = sse.findJsonString(input_json, "max_results") orelse "10";

        const url = try std.fmt.allocPrint(alloc,
            "https://gmail.googleapis.com/gmail/v1/users/me/messages?q={s}&maxResults={s}", .{ query, max_str });
        defer alloc.free(url);

        const resp = google_auth.googleGet(alloc, auth, url) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Gmail API failed: {s}", .{@errorName(e)});
        defer alloc.free(resp);

        return formatGmailList(alloc, auth, resp);
    }

    if (std.mem.eql(u8, operation, "read")) {
        const msg_id = sse.findJsonString(input_json, "message_id") orelse
            return alloc.dupe(u8, "Error: 'message_id' required for read operation.");

        const url = try std.fmt.allocPrint(alloc,
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/{s}?format=full", .{msg_id});
        defer alloc.free(url);

        const resp = google_auth.googleGet(alloc, auth, url) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Gmail API failed: {s}", .{@errorName(e)});
        return resp;
    }

    if (std.mem.eql(u8, operation, "send")) {
        const to = sse.findJsonString(input_json, "to") orelse
            return alloc.dupe(u8, "Error: 'to' field required.");
        const subject = sse.findJsonString(input_json, "subject") orelse "(no subject)";
        const body_text = sse.findJsonString(input_json, "body") orelse "";

        // Build RFC 2822 message and base64url encode
        const raw_msg = try std.fmt.allocPrint(alloc,
            "To: {s}\r\nSubject: {s}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n{s}", .{ to, subject, body_text });
        defer alloc.free(raw_msg);

        const b64 = std.base64.url_safe_no_pad.Encoder;
        const encoded_len = b64.calcSize(raw_msg.len);
        const encoded = try alloc.alloc(u8, encoded_len);
        defer alloc.free(encoded);
        _ = b64.encode(encoded, raw_msg);

        const send_body = try std.fmt.allocPrint(alloc, "{{\"raw\":\"{s}\"}}", .{encoded});
        defer alloc.free(send_body);

        const resp = google_auth.googlePost(alloc, auth,
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/send", send_body) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Gmail send failed: {s}", .{@errorName(e)});
        defer alloc.free(resp);

        const sent_id = sse.findJsonString(resp, "id") orelse "unknown";
        return std.fmt.allocPrint(alloc, "Email sent successfully.\n  To: {s}\n  Subject: {s}\n  Message ID: {s}", .{ to, subject, sent_id });
    }

    if (std.mem.eql(u8, operation, "labels")) {
        const resp = google_auth.googleGet(alloc, auth,
            "https://gmail.googleapis.com/gmail/v1/users/me/labels") catch |e|
            return std.fmt.allocPrint(alloc, "Error: Gmail API failed: {s}", .{@errorName(e)});
        return resp;
    }

    return std.fmt.allocPrint(alloc, "Error: Unknown Gmail operation '{s}'. Options: search, list, read, send, labels", .{operation});
}

fn formatGmailList(alloc: Allocator, auth: *google_auth.GoogleAuth, list_json: []const u8) ![]u8 {
    var buf: ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.writeAll("=== Gmail Messages ===\n\n");

    // Extract message IDs and fetch snippets
    var count: usize = 0;
    var pos: usize = 0;
    const id_needle = "\"id\":\"";

    while (std.mem.indexOfPos(u8, list_json, pos, id_needle)) |id_start| {
        const val_start = id_start + id_needle.len;
        const val_end = std.mem.indexOfPos(u8, list_json, val_start, "\"") orelse break;
        const msg_id = list_json[val_start..val_end];
        pos = val_end + 1;

        // Skip "threadId" entries (they follow "id" in the same object)
        if (count > 0 and std.mem.indexOfPos(u8, list_json[id_start -| 10 .. id_start], 0, "thread") != null) continue;

        // Fetch message metadata
        const meta_url = std.fmt.allocPrint(alloc,
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/{s}?format=metadata&metadataHeaders=Subject&metadataHeaders=From", .{msg_id}) catch continue;
        defer alloc.free(meta_url);

        const meta = google_auth.googleGet(alloc, auth, meta_url) catch continue;
        defer alloc.free(meta);

        const snippet = sse.findJsonString(meta, "snippet") orelse "";
        const from = sse.findJsonString(meta, "value") orelse "unknown";

        try std.fmt.format(w, "  [{s}] From: {s}\n    {s}\n\n", .{
            msg_id[0..@min(12, msg_id.len)],
            from[0..@min(40, from.len)],
            snippet[0..@min(80, snippet.len)],
        });

        count += 1;
        if (count >= 10) break;
    }

    if (count == 0) try w.writeAll("  No messages found.\n");

    return buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Calendar
// ---------------------------------------------------------------------------

fn executeCalendar(alloc: Allocator, auth: *google_auth.GoogleAuth, input_json: []const u8) ![]u8 {
    const operation = sse.findJsonString(input_json, "operation") orelse "list";

    if (std.mem.eql(u8, operation, "list")) {
        const time_min = sse.findJsonString(input_json, "time_min") orelse blk: {
            // Default: today
            break :blk "2024-01-01T00:00:00Z"; // Placeholder — ideally compute today's date
        };
        const time_max = sse.findJsonString(input_json, "time_max") orelse "";
        const max_results = sse.findJsonString(input_json, "max_results") orelse "10";

        var url_buf: ArrayList(u8) = .{};
        const uw = url_buf.writer(alloc);
        try uw.writeAll("https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&orderBy=startTime");
        try std.fmt.format(uw, "&timeMin={s}&maxResults={s}", .{ time_min, max_results });
        if (time_max.len > 0) try std.fmt.format(uw, "&timeMax={s}", .{time_max});

        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);

        const resp = google_auth.googleGet(alloc, auth, url) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Calendar API failed: {s}", .{@errorName(e)});
        return resp;
    }

    if (std.mem.eql(u8, operation, "create")) {
        const summary = sse.findJsonString(input_json, "summary") orelse
            return alloc.dupe(u8, "Error: 'summary' required for create.");
        const start_time = sse.findJsonString(input_json, "start") orelse
            return alloc.dupe(u8, "Error: 'start' required (ISO 8601 datetime).");
        const end_time = sse.findJsonString(input_json, "end") orelse
            return alloc.dupe(u8, "Error: 'end' required (ISO 8601 datetime).");
        const description = sse.findJsonString(input_json, "description") orelse "";
        const location = sse.findJsonString(input_json, "location") orelse "";

        const body = try std.fmt.allocPrint(alloc,
            \\{{"summary":"{s}","description":"{s}","location":"{s}","start":{{"dateTime":"{s}"}},"end":{{"dateTime":"{s}"}}}}
        , .{ summary, description, location, start_time, end_time });
        defer alloc.free(body);

        const resp = google_auth.googlePost(alloc, auth,
            "https://www.googleapis.com/calendar/v3/calendars/primary/events", body) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Calendar create failed: {s}", .{@errorName(e)});
        defer alloc.free(resp);

        const event_id = sse.findJsonString(resp, "id") orelse "unknown";
        const html_link = sse.findJsonString(resp, "htmlLink") orelse "";

        return std.fmt.allocPrint(alloc,
            \\Event created successfully.
            \\  Summary: {s}
            \\  Start: {s}
            \\  End: {s}
            \\  ID: {s}
            \\  Link: {s}
        , .{ summary, start_time, end_time, event_id, html_link });
    }

    if (std.mem.eql(u8, operation, "free_time") or std.mem.eql(u8, operation, "freebusy")) {
        const time_min = sse.findJsonString(input_json, "time_min") orelse
            return alloc.dupe(u8, "Error: 'time_min' required (ISO 8601).");
        const time_max = sse.findJsonString(input_json, "time_max") orelse
            return alloc.dupe(u8, "Error: 'time_max' required (ISO 8601).");

        const body = try std.fmt.allocPrint(alloc,
            \\{{"timeMin":"{s}","timeMax":"{s}","items":[{{"id":"primary"}}]}}
        , .{ time_min, time_max });
        defer alloc.free(body);

        const resp = google_auth.googlePost(alloc, auth,
            "https://www.googleapis.com/calendar/v3/freeBusy", body) catch |e|
            return std.fmt.allocPrint(alloc, "Error: FreeBusy query failed: {s}", .{@errorName(e)});
        return resp;
    }

    return std.fmt.allocPrint(alloc, "Error: Unknown Calendar operation '{s}'. Options: list, create, free_time", .{operation});
}

// ---------------------------------------------------------------------------
// Drive
// ---------------------------------------------------------------------------

fn executeDrive(alloc: Allocator, auth: *google_auth.GoogleAuth, input_json: []const u8) ![]u8 {
    const operation = sse.findJsonString(input_json, "operation") orelse "list";

    if (std.mem.eql(u8, operation, "list")) {
        const query = sse.findJsonString(input_json, "query") orelse "";
        const max_results = sse.findJsonString(input_json, "max_results") orelse "20";

        var url_buf: ArrayList(u8) = .{};
        const uw = url_buf.writer(alloc);
        try uw.writeAll("https://www.googleapis.com/drive/v3/files?fields=files(id,name,mimeType,modifiedTime,size)");
        try std.fmt.format(uw, "&pageSize={s}", .{max_results});
        if (query.len > 0) try std.fmt.format(uw, "&q={s}", .{query});

        const url = try url_buf.toOwnedSlice(alloc);
        defer alloc.free(url);

        const resp = google_auth.googleGet(alloc, auth, url) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Drive API failed: {s}", .{@errorName(e)});
        return resp;
    }

    if (std.mem.eql(u8, operation, "search")) {
        const name = sse.findJsonString(input_json, "name") orelse
            return alloc.dupe(u8, "Error: 'name' required for search.");

        const url = try std.fmt.allocPrint(alloc,
            "https://www.googleapis.com/drive/v3/files?q=name%20contains%20%27{s}%27&fields=files(id,name,mimeType,modifiedTime,size)", .{name});
        defer alloc.free(url);

        const resp = google_auth.googleGet(alloc, auth, url) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Drive search failed: {s}", .{@errorName(e)});
        return resp;
    }

    if (std.mem.eql(u8, operation, "download")) {
        const file_id = sse.findJsonString(input_json, "file_id") orelse
            return alloc.dupe(u8, "Error: 'file_id' required for download.");

        const url = try std.fmt.allocPrint(alloc,
            "https://www.googleapis.com/drive/v3/files/{s}?alt=media", .{file_id});
        defer alloc.free(url);

        const data = google_auth.googleGet(alloc, auth, url) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Drive download failed: {s}", .{@errorName(e)});
        defer alloc.free(data);

        // Save to temp file
        const output_path = try std.fmt.allocPrint(alloc, "/tmp/wintermolt_drive_{s}", .{file_id});
        defer alloc.free(output_path);

        const path_z = try alloc.dupeZ(u8, output_path);
        defer alloc.free(path_z);

        const file = std.fs.createFileAbsolute(path_z, .{}) catch
            return std.fmt.allocPrint(alloc, "Error: Could not create output file.", .{});
        defer file.close();
        file.writeAll(data) catch {};

        return std.fmt.allocPrint(alloc, "Downloaded to: {s} ({d} bytes)", .{ output_path, data.len });
    }

    if (std.mem.eql(u8, operation, "get_info")) {
        const file_id = sse.findJsonString(input_json, "file_id") orelse
            return alloc.dupe(u8, "Error: 'file_id' required.");

        const url = try std.fmt.allocPrint(alloc,
            "https://www.googleapis.com/drive/v3/files/{s}?fields=id,name,mimeType,modifiedTime,size,webViewLink,owners", .{file_id});
        defer alloc.free(url);

        const resp = google_auth.googleGet(alloc, auth, url) catch |e|
            return std.fmt.allocPrint(alloc, "Error: Drive API failed: {s}", .{@errorName(e)});
        return resp;
    }

    return std.fmt.allocPrint(alloc, "Error: Unknown Drive operation '{s}'. Options: list, search, download, get_info", .{operation});
}
