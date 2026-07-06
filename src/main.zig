const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Dir = std.Io.Dir;
const File = std.Io.File;

const mime = @import("mime.zig");

const Options = struct {
    port: u16 = 8080,
    root: []const u8 = ".",
    bind: []const u8 = "0.0.0.0",
    verbose: bool = true,
};

fn printUsage() void {
    std.debug.print(
        \\httpservz - a tiny, fast static file server 
        \\
        \\Usage:
        \\  httpservz [DIR] [options]
        \\
        \\Options:
        \\  -p, --port <PORT>     Port to listen on (default: 8080)
        \\  -b, --bind <ADDR>     Address to bind to (default: 0.0.0.0)
        \\  -q, --quiet           Suppress request logging
        \\  -h, --help            Show this help
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var opts: Options = .{};
    var positional_set = false;

    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next(); // skip argv0

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse {
                std.debug.print("error: {s} requires a value\n", .{arg});
                return error.InvalidArgument;
            };
            opts.port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("error: invalid port '{s}'\n", .{val});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bind")) {
            opts.bind = args.next() orelse {
                std.debug.print("error: {s} requires a value\n", .{arg});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            opts.verbose = false;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("error: unknown option '{s}'\n", .{arg});
            printUsage();
            return error.InvalidArgument;
        } else if (!positional_set) {
            opts.root = arg;
            positional_set = true;
        }
    }

    var root_dir = Dir.cwd().openDir(io, opts.root, .{ .iterate = true }) catch |err| {
        std.debug.print("error: cannot open directory '{s}': {t}\n", .{ opts.root, err });
        return err;
    };
    defer root_dir.close(io);

    var root_path_buf: [Dir.max_path_bytes]u8 = undefined;
    const root_abs_len = root_dir.realPath(io, &root_path_buf) catch 0;
    const root_abs: []const u8 = if (root_abs_len > 0) root_path_buf[0..root_abs_len] else opts.root;

    const address: net.IpAddress = .{ .ip4 = net.Ip4Address.parse(opts.bind, opts.port) catch
        net.Ip4Address.unspecified(opts.port) };

    var server = address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 512,
    }) catch |err| {
        std.debug.print("error: failed to bind {f}: {t}\n", .{ address, err });
        return err;
    };
    defer server.deinit(io);

    std.debug.print("httpservzing  \"{s}\" at http://{s}:{d}/\n", .{ root_abs, if (std.mem.eql(u8, opts.bind, "0.0.0.0")) "127.0.0.1" else opts.bind, opts.port });

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept error: {t}\n", .{err});
            continue;
        };

        const conn_ctx = gpa.create(ConnCtx) catch {
            stream.close(io);
            continue;
        };
        conn_ctx.* = .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .root_dir = root_dir,
            .verbose = opts.verbose,
        };

        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{conn_ctx}) catch |err| {
            std.debug.print("spawn error: {t}\n", .{err});
            stream.close(io);
            gpa.destroy(conn_ctx);
            continue;
        };
        thread.detach();
    }
}

const ConnCtx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    stream: net.Stream,
    root_dir: Dir,
    verbose: bool,
};

fn handleConnectionThread(ctx: *ConnCtx) void {
    defer ctx.gpa.destroy(ctx);
    defer ctx.stream.close(ctx.io);
    handleConnection(ctx) catch |err| {
        if (ctx.verbose) std.debug.print("connection closed: {t}\n", .{err});
    };
}

fn handleConnection(ctx: *ConnCtx) !void {
    const io = ctx.io;

    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var stream_reader = ctx.stream.reader(io, &in_buf);
    var stream_writer = ctx.stream.writer(io, &out_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return,
        };
        try serve(ctx, &request);
        if (!request.head.keep_alive) return;
        if (http_server.reader.state != .ready) return;
    }
}

fn logLine(ctx: *ConnCtx, method: std.http.Method, path: []const u8, status: std.http.Status) void {
    if (!ctx.verbose) return;
    std.debug.print("{t} {s} -> {d}\n", .{ method, path, @intFromEnum(status) });
}

fn respondError(ctx: *ConnCtx, request: *std.http.Server.Request, status: std.http.Status, msg: []const u8) void {
    request.respond(msg, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    }) catch {};
    logLine(ctx, request.head.method, request.head.target, status);
}

fn serve(ctx: *ConnCtx, request: *std.http.Server.Request) !void {
    const method = request.head.method;
    if (method != .GET and method != .HEAD) {
        respondError(ctx, request, .method_not_allowed, "405 Method Not Allowed\n");
        return;
    }

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const target = request.head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const raw_path = target[0..query_start];

    if (raw_path.len == 0 or raw_path.len > path_buf.len) {
        respondError(ctx, request, .bad_request, "400 Bad Request\n");
        return;
    }
    @memcpy(path_buf[0..raw_path.len], raw_path);
    const decoded = std.Uri.percentDecodeInPlace(path_buf[0..raw_path.len]);

    // Reject path traversal / null bytes.
    if (std.mem.indexOfScalar(u8, decoded, 0) != null) {
        respondError(ctx, request, .bad_request, "400 Bad Request\n");
        return;
    }
    var it = std.mem.splitScalar(u8, decoded, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) {
            respondError(ctx, request, .forbidden, "403 Forbidden\n");
            return;
        }
    }

    // Strip leading slash(es) to make it relative to root_dir.
    var rel = decoded;
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];

    try serveRelPath(ctx, request, rel, decoded);
}

fn serveRelPath(ctx: *ConnCtx, request: *std.http.Server.Request, rel_in: []const u8, display_path: []const u8) !void {
    const io = ctx.io;
    const root_dir = ctx.root_dir;

    const rel: []const u8 = if (rel_in.len == 0) "." else rel_in;

    const stat = root_dir.statFile(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            respondError(ctx, request, .not_found, "404 Not Found\n");
            return;
        },
        else => {
            respondError(ctx, request, .internal_server_error, "500 Internal Server Error\n");
            return;
        },
    };

    if (stat.kind == .directory) {
        // Try index.html / index.htm first.
        const index_names = [_][]const u8{ "index.html", "index.htm" };
        var buf: [Dir.max_path_bytes]u8 = undefined;
        for (index_names) |index_name| {
            const cleaned: []const u8 = if (std.mem.eql(u8, rel, "."))
                index_name
            else
                std.fmt.bufPrint(&buf, "{s}/{s}", .{ rel, index_name }) catch continue;
            if (root_dir.statFile(io, cleaned, .{})) |istat| {
                if (istat.kind == .file) {
                    return serveFile(ctx, request, cleaned, display_path);
                }
            } else |_| {}
        }
        return serveDirListing(ctx, request, rel, display_path);
    }

    if (stat.kind != .file) {
        respondError(ctx, request, .forbidden, "403 Forbidden\n");
        return;
    }

    return serveFile(ctx, request, rel, display_path);
}

fn serveFile(ctx: *ConnCtx, request: *std.http.Server.Request, rel: []const u8, display_path: []const u8) !void {
    const io = ctx.io;

    var file = ctx.root_dir.openFile(io, rel, .{}) catch {
        respondError(ctx, request, .not_found, "404 Not Found\n");
        return;
    };
    defer file.close(io);

    const stat = file.stat(io) catch {
        respondError(ctx, request, .internal_server_error, "500 Internal Server Error\n");
        return;
    };

    const content_type = mime.forPath(rel);

    var file_read_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_read_buf);

    var send_buf: [16 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&send_buf, .{
        .content_length = stat.size,
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type },
            },
        },
    });

    _ = body_writer.writer.sendFileAll(&file_reader, .unlimited) catch |err| switch (err) {
        error.WriteFailed => return err,
        else => {},
    };
    try body_writer.end();

    logLine(ctx, request.head.method, display_path, .ok);
}

fn serveDirListing(ctx: *ConnCtx, request: *std.http.Server.Request, rel: []const u8, display_path: []const u8) !void {
    const io = ctx.io;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = ctx.root_dir.openDir(io, rel, .{ .iterate = true }) catch {
        respondError(ctx, request, .not_found, "404 Not Found\n");
        return;
    };
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        const name_copy = try std.fmt.allocPrint(arena, "{s}{s}", .{ entry.name, suffix });
        try list.append(arena, name_copy);
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var html: std.ArrayList(u8) = .empty;
    try html.appendSlice(arena,
        \\<!DOCTYPE html>
        \\<html><head><meta charset="utf-8">
        \\<title>Index</title>
        \\<style>
        \\body{font-family:system-ui,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}
        \\h1{font-size:1.2rem;word-break:break-all}
        \\ul{list-style:none;padding:0}
        \\li{padding:.35rem 0;border-bottom:1px solid #eee}
        \\a{text-decoration:none;color:#0060c0}
        \\a:hover{text-decoration:underline}
        \\</style></head><body>
        \\
    );
    try html.appendSlice(arena, "<h1>Index of ");
    if (display_path.len == 0 or display_path[0] != '/') try html.appendSlice(arena, "/");
    try htmlEscapeAppend(arena, &html, display_path);
    if (display_path.len == 0 or display_path[display_path.len - 1] != '/') try html.appendSlice(arena, "/");
    try html.appendSlice(arena, "</h1>\n<ul>\n");
    if (!(rel.len == 0 or std.mem.eql(u8, rel, "."))) {
        try html.appendSlice(arena, "<li><a href=\"../\">../</a></li>\n");
    }
    for (list.items) |name| {
        try html.appendSlice(arena, "<li><a href=\"");
        try htmlEscapeAppend(arena, &html, name);
        try html.appendSlice(arena, "\">");
        try htmlEscapeAppend(arena, &html, name);
        try html.appendSlice(arena, "</a></li>\n");
    }
    try html.appendSlice(arena, "</ul></body></html>\n");

    try request.respond(html.items, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
    logLine(ctx, request.head.method, display_path, .ok);
}

fn htmlEscapeAppend(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(arena, "&amp;"),
            '<' => try out.appendSlice(arena, "&lt;"),
            '>' => try out.appendSlice(arena, "&gt;"),
            '"' => try out.appendSlice(arena, "&quot;"),
            else => try out.append(arena, c),
        }
    }
}
