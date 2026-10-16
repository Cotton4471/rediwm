//! Filename MIME classification only; the editor validates file contents in its worker.
const std = @import("std");
const mime_db = @import("../mime_db.zig");
pub fn candidate(path: []const u8) bool {
    // README, Makefile, dotfiles and other extensionless documents are common.
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return true;
    for ([_][]const u8{ ".zig", ".rs", ".go", ".py", ".js", ".ts", ".tsx", ".jsx", ".yaml", ".yml", ".toml", ".ini", ".conf", ".cfg", ".log", ".csv", ".sh" }) |ext| {
        if (std.ascii.eqlIgnoreCase(extension, ext)) return true;
    }
    const mime = mime_db.guess(path);
    return mime_db.isA(mime, "text/plain") or
        mime_db.isA(mime, "application/json") or
        mime_db.isA(mime, "application/xml") or
        mime_db.isA(mime, "application/toml") or
        std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".toml");
}
test "text preview candidates include config, source and extensionless files" {
    for ([_][]const u8{ "hello.txt", "README", ".bashrc", "notes.md", "main.c", "main.zig", "config.toml", "data.json" }) |name| try std.testing.expect(candidate(name));
    for ([_][]const u8{ "image.png", "archive.zip", "movie.mp4", "document.pdf" }) |name| try std.testing.expect(!candidate(name));
}
