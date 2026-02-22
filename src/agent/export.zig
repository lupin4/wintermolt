// Copyright The Fantastic Planet - By David Clabaugh
//
// export.zig — Export conversation history in standard formats
//
// Exports conversation history as JSONL for external consumption
// (fine-tuning, analysis, backup).
//
// Formats:
//   history  → JSONL (one message per line from SQLite)
//
// Called from REPL via /export <format> <path>

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const storage_mod = @import("storage.zig");

/// Export conversation history as JSONL.
/// Format: {"role":"user|assistant","content":"...","sequence":N}
pub fn exportHistory(
    alloc: Allocator,
    storage: *storage_mod.Storage,
    path: []const u8,
) !usize {
    // Get recent conversations
    const convos = try storage.listConversations(100);
    defer storage.freeConversations(convos);

    if (convos.len == 0) return 0;

    var buf: ArrayList(u8) = .{};
    const w = buf.writer(alloc);
    var total: usize = 0;

    for (convos) |convo| {
        const messages = storage.loadConversation(convo.id) catch continue;
        defer storage.freeMessages(messages);

        for (messages) |msg| {
            try std.fmt.format(w,
                \\{{"role":"{s}","content":{s},"sequence":{d}}}
            , .{
                msg.role,
                msg.content_json,
                msg.sequence_num,
            });
            try w.writeAll("\n");
            total += 1;
        }
    }

    const jsonl = try buf.toOwnedSlice(alloc);
    defer alloc.free(jsonl);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(jsonl);

    return total;
}
