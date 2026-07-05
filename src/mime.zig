const std = @import("std");

const Entry = struct { ext: []const u8, mime: []const u8 };

const table = [_]Entry{
    .{ .ext = "html", .mime = "text/html; charset=utf-8" },
    .{ .ext = "htm", .mime = "text/html; charset=utf-8" },
    .{ .ext = "css", .mime = "text/css; charset=utf-8" },
    .{ .ext = "js", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = "mjs", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = "cjs", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = "ts", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "tsx", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "jsx", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "json", .mime = "application/json; charset=utf-8" },
    .{ .ext = "map", .mime = "application/json; charset=utf-8" },
    .{ .ext = "xml", .mime = "application/xml; charset=utf-8" },
    .{ .ext = "txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "md", .mime = "text/markdown; charset=utf-8" },
    .{ .ext = "csv", .mime = "text/csv; charset=utf-8" },
    .{ .ext = "svg", .mime = "image/svg+xml" },
    .{ .ext = "png", .mime = "image/png" },
    .{ .ext = "jpg", .mime = "image/jpeg" },
    .{ .ext = "jpeg", .mime = "image/jpeg" },
    .{ .ext = "gif", .mime = "image/gif" },
    .{ .ext = "webp", .mime = "image/webp" },
    .{ .ext = "avif", .mime = "image/avif" },
    .{ .ext = "ico", .mime = "image/x-icon" },
    .{ .ext = "bmp", .mime = "image/bmp" },
    .{ .ext = "woff", .mime = "font/woff" },
    .{ .ext = "woff2", .mime = "font/woff2" },
    .{ .ext = "ttf", .mime = "font/ttf" },
    .{ .ext = "otf", .mime = "font/otf" },
    .{ .ext = "eot", .mime = "application/vnd.ms-fontobject" },
    .{ .ext = "mp4", .mime = "video/mp4" },
    .{ .ext = "webm", .mime = "video/webm" },
    .{ .ext = "mov", .mime = "video/quicktime" },
    .{ .ext = "mp3", .mime = "audio/mpeg" },
    .{ .ext = "wav", .mime = "audio/wav" },
    .{ .ext = "ogg", .mime = "audio/ogg" },
    .{ .ext = "flac", .mime = "audio/flac" },
    .{ .ext = "wasm", .mime = "application/wasm" },
    .{ .ext = "pdf", .mime = "application/pdf" },
    .{ .ext = "zip", .mime = "application/zip" },
    .{ .ext = "gz", .mime = "application/gzip" },
    .{ .ext = "tar", .mime = "application/x-tar" },
    .{ .ext = "wat", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "zig", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "toml", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "yaml", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "yml", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "webmanifest", .mime = "application/manifest+json" },
};

/// Returns a MIME type string for a given file path based on its extension.
/// Falls back to "application/octet-stream" when unknown.
pub fn forPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len <= 1) return "application/octet-stream";
    const no_dot = ext[1..];
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.ext, no_dot)) return entry.mime;
    }
    return "application/octet-stream";
}
