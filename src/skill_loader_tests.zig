// Copyright The Fantastic Planet - By David Clabaugh
//
// Test root for what goes into the prompt besides the conversation: skill
// manifests (src/agent/skill_loader.zig) and the workspace files
// (src/agent/workspace.zig). A module rooted inside src/agent/ cannot import
// ../fsio.zig, so the root sits here and pulls the files' tests in: a test
// block referencing an import is what makes Zig collect them.

test {
    _ = @import("agent/skill_loader.zig");
    _ = @import("agent/workspace.zig");
    _ = @import("agent/skill_md.zig");
}
