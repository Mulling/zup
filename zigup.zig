const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

pub const std_options = .{
    .log_level = .info,
};

const fixdeletetree = @import("fixdeletetree.zig");

const arch = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .riscv64 => "riscv64",
    .powerpc64le => "powerpc64le",
    .powerpc => "powerpc",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    else => @compileError("Unsupported OS"),
};
const url_platform = os ++ "-" ++ arch;
const json_platform = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

/// Ouput debug info
var verbose = false;

/// Force the given operation, i.e., `zigup --force default .`
var force = false;

inline fn fix_format_string(comptime fmt: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        // Not sure what is going on here, or why they are doing this on
        // windows, but this follows the behaviour of `loginfo` on windows.
        // ¯\_(ツ)_/¯
        var fixed_fmt = std.mem.zeroes([fmt.len]u8);
        std.mem.replace(u8, fmt, '\'', '\"', &fixed_fmt);

        return fixed_fmt;
    } else {
        return fmt;
    }
}

inline fn logi(comptime fmt: []const u8, args: anytype) void {
    if (verbose) std.log.info(fix_format_string(fmt), args);
}

inline fn loge(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fix_format_string(fmt), args);
}

inline fn logw(comptime fmt: []const u8, args: anytype) void {
    std.log.warn(fix_format_string(fmt), args);
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const DownloadResult = union(enum) {
    ok: void,
    err: []u8,
    pub fn deinit(self: DownloadResult, allocator: Allocator) void {
        switch (self) {
            .ok => {},
            .err => |e| allocator.free(e),
        }
    }
};
fn download(allocator: Allocator, url: []const u8, writer: anytype) DownloadResult {
    const uri = std.Uri.parse(url) catch |err| std.debug.panic("failed to parse url '{s}' with {s}", .{ url, @errorName(err) });

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    client.initDefaultProxies(allocator) catch |err| return .{ .err = std.fmt.allocPrint(allocator, "failed to query the HTTP proxy settings with {s}", .{@errorName(err)}) catch |e| oom(e) };

    var header_buffer: [4096]u8 = undefined;
    var request = client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    }) catch |err| return .{ .err = std.fmt.allocPrint(allocator, "failed to connect to the HTTP server with {s}", .{@errorName(err)}) catch |e| oom(e) };

    defer request.deinit();

    request.send() catch |err| return .{ .err = std.fmt.allocPrint(allocator, "failed to send the HTTP request with {s}", .{@errorName(err)}) catch |e| oom(e) };
    request.wait() catch |err| return .{ .err = std.fmt.allocPrint(allocator, "failed to read the HTTP response headers with {s}", .{@errorName(err)}) catch |e| oom(e) };

    if (request.response.status != .ok) return .{ .err = std.fmt.allocPrint(
        allocator,
        "HTTP server replied with unsuccessful response '{d} {s}'",
        .{ @intFromEnum(request.response.status), request.response.status.phrase() orelse "" },
    ) catch |e| oom(e) };

    // TODO: we take advantage of request.response.content_length

    var buf: [std.mem.page_size]u8 = undefined;
    while (true) {
        const len = request.reader().read(&buf) catch |err| return .{ .err = std.fmt.allocPrint(allocator, "failed to read the HTTP response body with {s}'", .{@errorName(err)}) catch |e| oom(e) };
        if (len == 0)
            return .ok;
        writer.writeAll(buf[0..len]) catch |err| return .{ .err = std.fmt.allocPrint(allocator, "failed to write the HTTP response body with {s}'", .{@errorName(err)}) catch |e| oom(e) };
    }
}

const DownloadStringResult = union(enum) {
    ok: []u8,
    err: []u8,
};
fn downloadToString(allocator: Allocator, url: []const u8) DownloadStringResult {
    var response_array_list = ArrayList(u8).initCapacity(allocator, 20 * 1024) catch |e| oom(e); // 20 KB (modify if response is expected to be bigger)
    defer response_array_list.deinit();
    switch (download(allocator, url, response_array_list.writer())) {
        .ok => return .{ .ok = response_array_list.toOwnedSlice() catch |e| oom(e) },
        .err => |e| return .{ .err = e },
    }
}

fn ignoreHttpCallback(request: []const u8) void {
    _ = request;
}

fn makeDirIfMissing(path: []const u8) !void {
    if (builtin.mode == std.builtin.OptimizeMode.Debug)
        std.debug.assert(std.fs.path.isAbsolute(path));

    logi("creating directory '{s}'", .{path});

    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => {
            logi("directory '{s}' already exists!", .{path});
        },
        else => return e,
    };
}

// fn makeZigPathLinkString(allocator: Allocator) ![]const u8 {
//     const zigup_dir = try std.fs.selfExeDirPathAlloc(allocator);
//     defer allocator.free(zigup_dir);
//
//     return try std.fs.path.join(allocator, &[_][]const u8{ zigup_dir, comptime "zig" ++ builtin.target.exeFileExt() });
// }

// TODO: this should be in standard lib
fn toAbsolute(allocator: Allocator, path: []const u8) ![]u8 {
    std.debug.assert(!std.fs.path.isAbsolute(path));
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &[_][]const u8{ cwd, path });
}

fn help() void {
    std.io.getStdErr().writeAll(
        \\Download and manage zig compilers.
        \\
        \\Common Usage:
        \\
        \\  zigup VERSION                 download and set VERSION compiler as default
        \\  zigup fetch VERSION           download VERSION compiler
        \\  zigup default [VERSION]       get or set the default compiler
        \\  zigup undefine                unset the default compiler
        \\  zigup list                    list installed compiler versions
        \\  zigup clean   [VERSION]       deletes the given compiler version, otherwise, cleans all compilers
        \\                                that aren't the default, master, or marked to keep
        \\  zigup keep VERSION            mark a compiler to be kept during clean
        \\  zigup run VERSION ARGS...     run the given VERSION of the compiler with the given ARGS...
        \\
        \\Uncommon Usage:
        \\
        \\  zigup fetch-index             download and print the download index json
        \\
        \\Common Options:
        \\  --install-dir DIR             override the default install location
        \\  --path-link PATH              path to the `zig` symlink that points to the default compiler
        \\                                this will typically be a file path within a PATH directory so
        \\                                that the user can just run `zig`
        \\
    ) catch unreachable;
}

fn getCmdOpt(args: [][]const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* == args.len) {
        std.log.err("option '{s}' requires an argument", .{args[i.* - 1]});
        return error.AlreadyReported;
    }
    return args[i.*];
}

pub fn promptUser(msg: []const u8, out: []u8) ![]u8 {
    try std.io.getStdOut().writeAll(msg);

    return try std.io.getStdIn().reader().readUntilDelimiter(out, '\n');
}

pub fn promptUserAlloc(allocator: Allocator, msg: []const u8) ![]u8 {
    try std.io.getStdOut().writeAll(msg);

    return try std.io.getStdIn().reader().readUntilDelimiterAlloc(allocator, '\n', 4096);
}

pub fn yesOrNoP(comptime msg: []const u8) !bool {
    const out_msg = msg ++ " [Y/n]";

    var buf: [2]u8 = undefined;

    prompt: while (true) {
        const ret = promptUser(out_msg, &buf) catch |err| if (err == error.StreamTooLong) {
            std.debug.print("stream too long", .{});
            continue :prompt;
        } else return err;

        // TODO: Make this configurable
        // User just pressed ret, assume true;
        if (ret.len == 0) {
            return true;
        }

        if (ret[0] == 'y' or ret[0] == 'Y') {
            return true;
        } else if (buf[0] == 'n' or buf[0] == 'N') {
            return false;
        }
    }
}

const ZigupConfig = struct {
    allocator: Allocator,

    path: []const u8,
    install_path: []u8,
    default_path: []u8,

    const Self = @This();

    pub fn init(allocator: Allocator, path: []const u8) !ZigupConfig {
        const install_path = try std.fs.path.join(allocator, &[_][]const u8{ path, "cache" });
        const default_path = try std.fs.path.join(allocator, &[_][]const u8{ path, "default" });

        return .{
            .allocator = allocator,
            .path = path,
            .install_path = install_path,
            .default_path = default_path,
        };
    }

    pub fn set_install_path(self: *Self, install_path: []const u8) !void {
        self.allocator.free(self.install_path);

        self.install_path = try self.allocator.alloc(u8, install_path.len);

        @memcpy(self.install_path, install_path);
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.default_path);
        self.allocator.free(self.install_path);
    }
};

pub fn configure(allocator: Allocator) !void {
    if (!try yesOrNoP("Could not get config from env, configure zigup?")) {
        return error.ConfigAborted;
    }

    const home = std.posix.getenv("HOME") orelse @panic("$HOME is not in env");
    const default_path = try std.fmt.allocPrint(allocator, "{s}/.zigup", .{home});

    logi("default zigup_path = '{s}'", .{default_path});

    const path_prompt = try std.fmt.allocPrint(allocator, "Install path for zigup (default: {s}): ", .{default_path});

    var path = try promptUserAlloc(allocator, path_prompt);

    if (path.len == 0) path = default_path;

    // TODO: Prompt if the users wants to change this
    // const install_path = try std.fmt.allocPrint(allocator, "{s}/cache", .{path});

    if (!std.posix.isatty(std.io.getStdOut().handle))
        return error.NonInteractiveTerminal;

    // TODO: add zsh
    // TODO: add fish
    if (isBash()) {
        try outputPosixShellEnv(allocator, path);
    } else {
        @panic("Could not guess the current shell");
    }
}

inline fn isBash() bool {
    return std.mem.endsWith(u8, std.posix.getenv("SHELL") orelse return false, "bash");
}

const shellEnvFmt =
    \\#!/bin/sh
    \\
    \\# Path to env
    \\export ZIGUP_DIR="{s}"
    \\# Path to cache
    \\export ZIGUP_INSTALL_DIR="$ZIGUP_DIR/cache"
    \\
    \\case ":$PATH:" in
    \\    *:"$ZIGUP_DIR/default":*)
    \\        ;;
    \\    *)
    \\        # Prepend to override system-hide install
    \\        export PATH="$ZIGUP_DIR/default:$PATH"
    \\        ;;
    \\esac
    \\
;

const sourceEnvFmt =
    \\[ -f \"{s}\" ] && source \"{s}\"
;

pub fn outputPosixShellEnv(allocator: Allocator, path: []const u8) !void {
    const env = try std.fmt.allocPrint(
        allocator,
        shellEnvFmt,
        .{path},
    );
    logi("bash env: \n{s}", .{env});

    try makeDirIfMissing(path);

    const env_file = try std.fs.path.join(allocator, &[_][]const u8{ path, "env" });

    const fd = try std.fs.createFileAbsolute(env_file, .{});
    errdefer fd.close();

    try fd.writeAll(env);

    const bash_config = try std.fmt.allocPrint(allocator, sourceEnvFmt, .{ env_file, env_file });

    try std.io.getStdOut().writeAll("Add this to your .bashrc:\n");
    try std.io.getStdOut().writeAll(bash_config);
}

pub fn readConfigFromEnv(allocator: Allocator) !?ZigupConfig {
    // TODO: Allow override of install_path
    return try ZigupConfig.init(
        allocator,
        std.posix.getenv("ZIGUP_DIR") orelse return null,
    );
}

pub fn main() !u8 {
    return zigup() catch |e| switch (e) {
        error.AlreadyReported => return 1,
        else => return e,
    };
}

pub fn zigup() !u8 {
    if (builtin.os.tag == .windows) {
        _ = try std.os.windows.WSAStartup(2, 2);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const args_array = try std.process.argsAlloc(allocator);
    // no need to free, os will do it
    //defer std.process.argsFree(allocator, argsArray);

    const config = try readConfigFromEnv(allocator) orelse {
        try configure(allocator);
        // NOTE: We could just make zigup work here, but we should assert that
        // the user does the proper shell configuration. One way of doing this
        // is to just do noting, which will cause zigup to "not work" until the
        // shell environment is up
        return 0;
    };

    // Assert that the dirs exist
    try makeDirIfMissing(config.path);
    try makeDirIfMissing(config.install_path);

    // TODO: If the user removes `config.path` zigup will work while the shell
    // is up, we should assert that the env exist, possible creating it if it's
    // missing. This has the bonus of allowing the user to skip configuration
    // with `ZIGUP_PATH="..." zigup ...`.

    var args = if (args_array.len == 0) args_array else args_array[1..];
    // parse common options
    {
        var i: usize = 0;
        var newlen: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
                help();
                return 0;
            } else if (std.mem.eql(u8, "-v", arg) or std.mem.eql(u8, "--verbose", arg)) {
                verbose = true;
            } else {
                if (newlen == 0 and std.mem.eql(u8, "run", arg)) {
                    return try runCompiler(allocator, &config, args[i + 1 ..]);
                }
                args[newlen] = args[i];
                newlen += 1;
            }
        }
        args = args[0..newlen];
    }
    if (args.len == 0) {
        help();
        return 1;
    }
    if (std.mem.eql(u8, "fetch-index", args[0])) {
        if (args.len != 1) {
            std.log.err("'index' command requires 0 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        var download_index = try fetchDownloadIndex(allocator);
        defer download_index.deinit(allocator);
        try std.io.getStdOut().writeAll(download_index.text);
        return 0;
    }
    if (std.mem.eql(u8, "undefine", args[0])) {
        if (args.len != 1) {
            loge("'undefine' does not take any arguments", .{});
            return 1;
        }

        try unsetDefaultCompiler(&config);

        return 0;
    }
    if (std.mem.eql(u8, "fetch", args[0])) {
        if (args.len != 2) {
            std.log.err("'fetch' command requires 1 argument but got {d}", .{args.len - 1});
            return 1;
        }

        try fetchCompiler(allocator, args[1], &config, .leave_default);
        return 0;
    }
    if (std.mem.eql(u8, "clean", args[0])) {
        if (args.len == 1) {
            try cleanCompilers(allocator, &config, null);
        } else if (args.len == 2) {
            try cleanCompilers(allocator, &config, args[1]);
        } else {
            std.log.err("'clean' command requires 0 or 1 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, "keep", args[0])) {
        if (args.len != 2) {
            std.log.err("'keep' command requires 1 argument but got {d}", .{args.len - 1});
            return 1;
        }
        try keepCompiler(&config, args[1]);
        return 0;
    }
    if (std.mem.eql(u8, "list", args[0])) {
        if (args.len != 1) {
            std.log.err("'list' command requires 0 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        try listCompilers(&config);
        return 0;
    }
    if (std.mem.eql(u8, "default", args[0])) {
        if (args.len == 1) {
            try printDefaultCompiler(allocator, &config);
            return 0;
        }
        if (args.len == 2) {
            const version_string = args[1];

            const resolved_version_string = init_resolved: {
                if (!std.mem.eql(u8, version_string, "master"))
                    break :init_resolved version_string;

                const optional_master_dir: ?[]const u8 = blk: {
                    var install_dir = std.fs.openDirAbsolute(config.install_path, .{ .iterate = true }) catch |e| switch (e) {
                        error.FileNotFound => break :blk null,
                        else => return e,
                    };
                    defer install_dir.close();
                    break :blk try getMasterDir(allocator, &install_dir);
                };
                // no need to free master_dir, this is a short lived program
                break :init_resolved optional_master_dir orelse {
                    std.log.err("master has not been fetched", .{});
                    return 1;
                };
            };

            // If the user suplys us with a path, make it the default compiler
            if (try setDefaultCompilerFromPath(allocator, &config, resolved_version_string)) return 0;

            const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ config.install_path, resolved_version_string });
            defer allocator.free(compiler_dir);
            try setDefaultCompiler(allocator, compiler_dir, &config, true);
            return 0;
        }
        std.log.err("'default' command requires 1 or 2 arguments but got {d}", .{args.len - 1});
        return 1;
    }
    if (args.len == 1) {
        try fetchCompiler(allocator, args[0], &config, .set_default);
        return 0;
    }
    const command = args[0];
    args = args[1..];
    std.log.err("command not impl '{s}'", .{command});
    return 1;

    //const optionalInstallPath = try find_zigs(allocator);
}

pub fn runCompiler(allocator: Allocator, config: *const ZigupConfig, args: []const []const u8) !u8 {
    if (args.len <= 1) {
        std.log.err("zigup run requires at least 2 arguments: zigup run VERSION PROG ARGS...", .{});
        return 1;
    }
    const version_string = args[0];

    const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ config.install_path, version_string });
    defer allocator.free(compiler_dir);
    if (!try existsAbsolute(compiler_dir)) {
        std.log.err("compiler '{s}' does not exist, fetch it first with: zigup fetch {0s}", .{version_string});
        return 1;
    }

    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.append(try std.fs.path.join(allocator, &.{ compiler_dir, "files", comptime "zig" ++ builtin.target.exeFileExt() }));
    try argv.appendSlice(args[1..]);

    // TODO: use "execve" if on linux
    var proc = std.process.Child.init(argv.items, allocator);
    const ret_val = try proc.spawnAndWait();
    switch (ret_val) {
        .Exited => |code| return code,
        else => |result| {
            std.log.err("compiler exited with {}", .{result});
            return 0xff;
        },
    }
}

const SetDefault = enum { set_default, leave_default };

fn fetchCompiler(allocator: Allocator, version_arg: []const u8, config: *const ZigupConfig, set_default: SetDefault) !void {
    const install_dir = config.install_path;

    var optional_download_index: ?DownloadIndex = null;
    // This is causing an LLVM error
    //defer if (optionalDownloadIndex) |_| optionalDownloadIndex.?.deinit(allocator);
    // Also I would rather do this, but it doesn't work because of const issues
    //defer if (optionalDownloadIndex) |downloadIndex| downloadIndex.deinit(allocator);

    const VersionUrl = struct { version: []const u8, url: []const u8 };

    // NOTE: we only fetch the download index if the user wants to download 'master', we can skip
    //       this step for all other versions because the version to URL mapping is fixed (see getDefaultUrl)
    const is_master = std.mem.eql(u8, version_arg, "master");
    const version_url = blk: {
        if (!is_master)
            break :blk VersionUrl{ .version = version_arg, .url = try getDefaultUrl(allocator, version_arg) };
        optional_download_index = try fetchDownloadIndex(allocator);
        const master = optional_download_index.?.json.value.object.get("master").?;
        const compiler_version = master.object.get("version").?.string;
        const master_linux = master.object.get(json_platform).?;
        const master_linux_tarball = master_linux.object.get("tarball").?.string;
        break :blk VersionUrl{ .version = compiler_version, .url = master_linux_tarball };
    };

    const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, version_url.version });
    defer allocator.free(compiler_dir);

    try installCompiler(allocator, compiler_dir, version_url.url);

    if (is_master) {
        const master_symlink = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "master" });
        defer allocator.free(master_symlink);
        if (builtin.os.tag == .windows) {
            var file = try std.fs.createFileAbsolute(master_symlink, .{});
            defer file.close();
            try file.writer().writeAll(version_url.version);
        } else {
            _ = try loggyUpdateSymlink(version_url.version, master_symlink, .{ .is_directory = true });
        }
    }
    if (set_default == .set_default) {
        try setDefaultCompiler(allocator, compiler_dir, config, false);
    }
}

const download_index_url = "https://ziglang.org/download/index.json";

const DownloadIndex = struct {
    text: []u8,
    json: std.json.Parsed(std.json.Value),
    pub fn deinit(self: *DownloadIndex, allocator: Allocator) void {
        self.json.deinit();
        allocator.free(self.text);
    }
};

fn fetchDownloadIndex(allocator: Allocator) !DownloadIndex {
    const text = switch (downloadToString(allocator, download_index_url)) {
        .ok => |text| text,
        .err => |err| {
            std.log.err("download '{s}' failed: {s}", .{ download_index_url, err });
            return error.AlreadyReported;
        },
    };
    errdefer allocator.free(text);
    var json = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    errdefer json.deinit();
    return DownloadIndex{ .text = text, .json = json };
}

// XXX: What?
// TODO: Get rid of these
fn loggyDeleteTreeAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        logi("rd /s /q \"{s}\"", .{dir_absolute});
    } else {
        logi("rm -rf '{s}'", .{dir_absolute});
    }
    try fixdeletetree.deleteTreeAbsolute(dir_absolute);
}

pub fn loggyRenameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    logi("mv '{s}' '{s}'", .{ old_path, new_path });
    try std.fs.renameAbsolute(old_path, new_path);
}

pub fn loggySymlinkAbsolute(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.Dir.SymLinkFlags) !void {
    logi("ln -s '{s}' '{s}'", .{ target_path, sym_link_path });
    // NOTE: can't use symLinkAbsolute because it requires target_path to be absolute but we don't want that
    //       not sure if it is a bug in the standard lib or not
    //try std.fs.symLinkAbsolute(target_path, sym_link_path, flags);
    _ = flags;
    try std.posix.symlink(target_path, sym_link_path);
}

/// returns: true if the symlink was updated, false if it was already set to the given `target_path`
pub fn loggyUpdateSymlink(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.Dir.SymLinkFlags) !bool {
    var current_target_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.readLinkAbsolute(sym_link_path, &current_target_path_buffer)) |current_target_path| {
        if (std.mem.eql(u8, target_path, current_target_path)) {
            logi("symlink '{s}' already points to '{s}'", .{ sym_link_path, target_path });
            return false; // already up-to-date
        }
        try std.posix.unlink(sym_link_path);
    } else |e| switch (e) {
        error.FileNotFound => {},
        error.NotLink => {
            std.debug.print(
                "unable to update/overwrite the 'zig' PATH symlink, the file '{s}' already exists and is not a symlink\n",
                .{sym_link_path},
            );
            std.process.exit(1);
        },
        else => return e,
    }
    try loggySymlinkAbsolute(target_path, sym_link_path, flags);
    return true; // updated
}

// TODO: this should be in std lib somewhere
fn existsAbsolute(absolutePath: []const u8) !bool {
    std.fs.cwd().access(absolutePath, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        error.PermissionDenied => return e,
        error.InputOutput => return e,
        error.SystemResources => return e,
        error.SymLinkLoop => return e,
        error.FileBusy => return e,
        error.Unexpected => unreachable,
        error.InvalidUtf8 => return e,
        error.InvalidWtf8 => return e,
        error.ReadOnlyFileSystem => unreachable,
        error.NameTooLong => unreachable,
        error.BadPathName => unreachable,
    };
    return true;
}

fn listCompilers(config: *const ZigupConfig) !void {
    var install_dir = std.fs.openDirAbsolute(config.install_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();

    const stdout = std.io.getStdOut().writer();
    {
        var it = install_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory)
                continue;
            if (std.mem.endsWith(u8, entry.name, ".installing"))
                continue;
            try stdout.print("{s}\n", .{entry.name});
        }
    }
}

fn keepCompiler(config: *const ZigupConfig, compiler_version: []const u8) !void {
    var install_dir = try std.fs.openDirAbsolute(config.install_path, .{ .iterate = true });
    defer install_dir.close();

    var compiler_dir = install_dir.openDir(compiler_version, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("compiler not found: {s}", .{compiler_version});
            return error.AlreadyReported;
        },
        else => return e,
    };
    var keep_fd = try compiler_dir.createFile("keep", .{});
    keep_fd.close();
    logi("created '{s}{c}{s}{c}{s}'", .{ config.install_path, std.fs.path.sep, compiler_version, std.fs.path.sep, "keep" });
}

fn cleanCompilers(allocator: Allocator, config: *const ZigupConfig, compiler_name_opt: ?[]const u8) !void {
    // getting the current compiler
    const default_comp_opt = try getDefaultCompiler(allocator, config);
    defer if (default_comp_opt) |default_compiler| allocator.free(default_compiler);

    var install_dir = std.fs.openDirAbsolute(config.install_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();
    const master_points_to_opt = try getMasterDir(allocator, &install_dir);
    defer if (master_points_to_opt) |master_points_to| allocator.free(master_points_to);
    if (compiler_name_opt) |compiler_name| {
        if (getKeepReason(master_points_to_opt, default_comp_opt, compiler_name)) |reason| {
            std.log.err("cannot clean '{s}' ({s})", .{ compiler_name, reason });
            return error.AlreadyReported;
        }
        logi("deleting '{s}{c}{s}'", .{ config.install_path, std.fs.path.sep, compiler_name });
        try fixdeletetree.deleteTree(install_dir, compiler_name);
    } else {
        var it = install_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory)
                continue;
            if (getKeepReason(master_points_to_opt, default_comp_opt, entry.name)) |reason| {
                logi("keeping '{s}' ({s})", .{ entry.name, reason });
                continue;
            }

            {
                var compiler_dir = try install_dir.openDir(entry.name, .{});
                defer compiler_dir.close();
                if (compiler_dir.access("keep", .{})) |_| {
                    logi("keeping '{s}' (has keep file)", .{entry.name});
                    continue;
                } else |e| switch (e) {
                    error.FileNotFound => {},
                    else => return e,
                }
            }
            logi("deleting '{s}{c}{s}'", .{ config.install_path, std.fs.path.sep, entry.name });
            try fixdeletetree.deleteTree(install_dir, entry.name);
        }
    }
}

fn readDefaultCompiler(allocator: Allocator, buffer: *[std.fs.max_path_bytes + 1]u8, config: *const ZigupConfig) !?[]const u8 {
    logi("read default compiler link '{s}'", .{config.default_path});

    // TODO: Log for windows
    if (builtin.os.tag == .windows) {
        var file = std.fs.openFileAbsolute(config.default_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close();
        try file.seekTo(win32exelink.exe_offset);
        const len = try file.readAll(buffer);
        if (len != buffer.len) {
            std.log.err("path link file '{s}' is too small", .{config.default_path});
            return error.AlreadyReported;
        }
        const target_exe = std.mem.sliceTo(buffer, 0);
        try targetPathToVersion(allocator, target_exe);
    }

    const target_path = std.fs.readLinkAbsolute(config.default_path, buffer[0..std.fs.max_path_bytes]) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };

    return target_path;
}

inline fn targetPathToVersion(allocator: Allocator, path: []const u8) !void {
    const zig_path = try std.fs.path.join(allocator, &[_][]const u8{ path, "zig" });
    _ = try run(allocator, &[_][]const u8{ zig_path, "version" });
}

fn readMasterDir(buffer: *[std.fs.max_path_bytes]u8, install_dir: *std.fs.Dir) !?[]const u8 {
    if (builtin.os.tag == .windows) {
        var file = install_dir.openFile("master", .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close();
        return buffer[0..try file.readAll(buffer)];
    }
    return install_dir.readLink("master", buffer) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
}

fn getDefaultCompiler(allocator: Allocator, config: *const ZigupConfig) !?[]const u8 {
    // XXX: Why +1!?
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;

    // Dupped again!?
    const slice_path = try readDefaultCompiler(allocator, &buffer, config) orelse return null;

    const path_to_return = try allocator.alloc(u8, slice_path.len);
    @memcpy(path_to_return, slice_path);
    return path_to_return;
}

fn getMasterDir(allocator: Allocator, install_dir: *std.fs.Dir) !?[]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const slice_path = (try readMasterDir(&buffer, install_dir)) orelse return null;
    const path_to_return = try allocator.alloc(u8, slice_path.len);
    @memcpy(path_to_return, slice_path);
    return path_to_return;
}

fn printDefaultCompiler(allocator: Allocator, config: *const ZigupConfig) !void {
    if (try getDefaultCompiler(allocator, config)) |default_compiler| {
        try targetPathToVersion(allocator, default_compiler);
    } else {
        try std.io.getStdOut().writeAll("<no-default>\n");
    }
}

fn unsetDefaultCompiler(config: *const ZigupConfig) !void {
    std.posix.unlink(config.default_path) catch |err|
        return if (err == error.FileNotFound) logw("no default compiler is set", .{}) else err;

    if (isBash()) {
        logw("Use `hash -r` to reset the command location cache.", .{});
    }
}

fn setDefaultCompiler(allocator: Allocator, compiler_dir: []const u8, config: *const ZigupConfig, verify_exists: bool) !void {
    if (verify_exists) {
        var dir = std.fs.openDirAbsolute(compiler_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("compiler '{s}' is not installed", .{std.fs.path.basename(compiler_dir)});
                return error.AlreadyReported;
            },
            else => |e| return e,
        };
        dir.close();
    }

    const target = try std.fs.path.join(allocator, &[_][]const u8{ compiler_dir, "files" });
    defer allocator.free(target);

    if (builtin.os.tag == .windows) {
        try createExeLink(target, config.default_path);
    } else {
        _ = try loggyUpdateSymlink(target, config.default_path, .{});
    }

    // TODO: Keep or remove this?!
    // FIXME: This is broken
    //try verifyPathLink(allocator, link_path);
}

fn openDir(path: []const u8) !std.fs.Dir {
    return if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{ .iterate = true })
    else
        std.fs.cwd().openDir(path, .{ .iterate = true });
}

fn findCompiler(allocator: Allocator, dir: *const std.fs.Dir, buf: []u8) !?[]u8 {
    var it = try dir.walk(allocator);
    errdefer it.deinit();

    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.basename, "zig")) {
            const real_path = try entry.dir.realpath(".", buf);

            logi("found zig at '{s}'", .{real_path});

            return real_path;
        }

        if (entry.kind == .directory) {
            logi("searching '{s}'", .{entry.basename});

            var next = try entry.dir.openDir(entry.basename, .{ .iterate = true });
            errdefer next.close();

            if (try findCompiler(allocator, &next, buf)) |zig| return zig;
        }
    }

    return null;
}

fn setDefaultCompilerFromPath(allocator: Allocator, config: *const ZigupConfig, path: []const u8) !bool {
    var dir = openDir(path) catch |err|
        if (err == error.FileNotFound) return false else return err;
    errdefer dir.close();

    var buf = std.mem.zeroes([std.os.linux.PATH_MAX]u8);
    var real_path: []const u8 = try dir.realpath(".", &buf);

    if (!force) {
        logi("searching '{s}'", .{path});
        // XXX: Error out here?
        real_path = try findCompiler(allocator, &dir, &buf) orelse return false;
    }

    logi("set default compiler directory '{s}'", .{real_path});

    // TODO: Asset that the path leads to a valid zig compiler.
    // TODO: Windows
    _ = try loggyUpdateSymlink(real_path, config.default_path, .{});

    return true;
}

/// Verify that path_link will work.  It verifies that `path_link` is
/// in PATH and there is no zig executable in an earlier directory in PATH.
fn verifyPathLink(allocator: Allocator, path_link: []const u8) !void {
    const path_link_dir = std.fs.path.dirname(path_link) orelse {
        std.log.err("invalid '--path-link' '{s}', it must be a file (not the root directory)", .{path_link});
        return error.AlreadyReported;
    };

    const path_link_dir_id = blk: {
        var dir = std.fs.openDirAbsolute(path_link_dir, .{}) catch |err| {
            std.log.err("unable to open the path-link directory '{s}': {s}", .{ path_link_dir, @errorName(err) });
            return error.AlreadyReported;
        };
        defer dir.close();
        break :blk try FileId.initFromDir(dir, path_link);
    };

    if (builtin.os.tag == .windows) {
        const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return,
            else => |e| return e,
        };
        defer allocator.free(path_env);

        var free_pathext: ?[]const u8 = null;
        defer if (free_pathext) |p| allocator.free(p);

        const pathext_env = blk: {
            if (std.process.getEnvVarOwned(allocator, "PATHEXT")) |env| {
                free_pathext = env;
                break :blk env;
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => break :blk "",
                else => |e| return e,
            }
            break :blk "";
        };

        var path_it = std.mem.tokenizeScalar(u8, path_env, ';');
        while (path_it.next()) |path| {
            switch (try compareDir(path_link_dir_id, path)) {
                .missing => continue,
                // can't be the same directory because we were able to open and get
                // the file id for path_link_dir_id
                .access_denied => {},
                .match => return,
                .mismatch => {},
            }
            {
                const exe = try std.fs.path.join(allocator, &.{ path, "zig" });
                defer allocator.free(exe);
                // try enforceNoZig(path_link, exe);
            }

            var ext_it = std.mem.tokenizeScalar(u8, pathext_env, ';');
            while (ext_it.next()) |ext| {
                if (ext.len == 0) continue;
                const basename = try std.mem.concat(allocator, u8, &.{ "zig", ext });
                defer allocator.free(basename);

                const exe = try std.fs.path.join(allocator, &.{ path, basename });
                defer allocator.free(exe);

                // try enforceNoZig(path_link, exe);
            }
        }
    } else {
        var path_it = std.mem.tokenizeScalar(u8, std.posix.getenv("PATH") orelse "", ':');
        while (path_it.next()) |path| {
            switch (try compareDir(path_link_dir_id, path)) {
                .missing => continue,
                // can't be the same directory because we were able to open and get
                // the file id for path_link_dir_id
                .access_denied => {},
                .match => return,
                .mismatch => {},
            }
            const exe = try std.fs.path.join(allocator, &.{ path, "zig" });
            defer allocator.free(exe);
            // try enforceNoZig(path_link, exe);
        }
    }

    std.log.err("the path link '{s}' is not in PATH", .{path_link});
    return error.AlreadyReported;
}

fn compareDir(dir_id: FileId, other_dir: []const u8) !enum { missing, access_denied, match, mismatch } {
    var dir = std.fs.cwd().openDir(other_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => return .missing,
        error.AccessDenied => return .access_denied,
        else => |e| return e,
    };
    defer dir.close();
    return if (dir_id.eql(try FileId.initFromDir(dir, other_dir))) .match else .mismatch;
}

// fn enforceNoZig(path_link: []const u8, exe: []const u8) !void {
//     var file = std.fs.cwd().openFile(exe, .{}) catch |err| switch (err) {
//         error.FileNotFound, error.IsDir => return,
//         error.AccessDenied => return, // if there is a Zig it must not be accessible
//         else => |e| return e,
//     };
//     defer file.close();
//
//     // todo: on posix systems ignore the file if it is not executable
//     std.log.err("zig compiler '{s}' is higher priority in PATH than the path-link '{s}'", .{ exe, path_link });
// }

const FileId = struct {
    dev: if (builtin.os.tag == .windows) u32 else blk: {
        const st: std.posix.Stat = undefined;
        break :blk @TypeOf(st.dev);
    },
    ino: if (builtin.os.tag == .windows) u64 else blk: {
        const st: std.posix.Stat = undefined;
        break :blk @TypeOf(st.ino);
    },

    pub fn initFromFile(file: std.fs.File, filename_for_error: []const u8) !FileId {
        if (builtin.os.tag == .windows) {
            var info: win32.BY_HANDLE_FILE_INFORMATION = undefined;
            if (0 == win32.GetFileInformationByHandle(file.handle, &info)) {
                std.log.err("GetFileInformationByHandle on '{s}' failed, error={}", .{ filename_for_error, std.os.windows.kernel32.GetLastError() });
                return error.AlreadyReported;
            }
            return FileId{
                .dev = info.dwVolumeSerialNumber,
                .ino = (@as(u64, @intCast(info.nFileIndexHigh)) << 32) | @as(u64, @intCast(info.nFileIndexLow)),
            };
        }
        const st = try std.posix.fstat(file.handle);
        return FileId{
            .dev = st.dev,
            .ino = st.ino,
        };
    }

    pub fn initFromDir(dir: std.fs.Dir, name_for_error: []const u8) !FileId {
        if (builtin.os.tag == .windows) {
            return initFromFile(std.fs.File{ .handle = dir.fd }, name_for_error);
        }
        return initFromFile(std.fs.File{ .handle = dir.fd }, name_for_error);
    }

    pub fn eql(self: FileId, other: FileId) bool {
        return self.dev == other.dev and self.ino == other.ino;
    }
};

const win32 = struct {
    pub const BOOL = i32;
    pub const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };
    pub const BY_HANDLE_FILE_INFORMATION = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        dwVolumeSerialNumber: u32,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
        nNumberOfLinks: u32,
        nFileIndexHigh: u32,
        nFileIndexLow: u32,
    };
    pub extern "kernel32" fn GetFileInformationByHandle(
        hFile: ?@import("std").os.windows.HANDLE,
        lpFileInformation: ?*BY_HANDLE_FILE_INFORMATION,
    ) callconv(@import("std").os.windows.WINAPI) BOOL;
};

const win32exelink = struct {
    const content = @embedFile("win32exelink");
    const exe_offset: usize = if (builtin.os.tag != .windows) 0 else blk: {
        @setEvalBranchQuota(content.len * 2);
        const marker = "!!!THIS MARKS THE zig_exe_string MEMORY!!#";
        const offset = std.mem.indexOf(u8, content, marker) orelse {
            @compileError("win32exelink is missing the marker: " ++ marker);
        };
        if (std.mem.indexOf(u8, content[offset + 1 ..], marker) != null) {
            @compileError("win32exelink contains multiple markers (not implemented)");
        }
        break :blk offset + marker.len;
    };
};
fn createExeLink(link_target: []const u8, path_link: []const u8) !void {
    if (path_link.len > std.fs.max_path_bytes) {
        std.debug.print("Error: path_link (size {}) is too large (max {})\n", .{ path_link.len, std.fs.max_path_bytes });
        return error.AlreadyReported;
    }
    const file = std.fs.cwd().createFile(path_link, .{}) catch |err| switch (err) {
        error.IsDir => {
            std.debug.print(
                "unable to create the exe link, the path '{s}' is a directory\n",
                .{path_link},
            );
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer file.close();
    try file.writer().writeAll(win32exelink.content[0..win32exelink.exe_offset]);
    try file.writer().writeAll(link_target);
    try file.writer().writeAll(win32exelink.content[win32exelink.exe_offset + link_target.len ..]);
}

const VersionKind = enum { release, dev };
fn determineVersionKind(version: []const u8) VersionKind {
    return if (std.mem.indexOfAny(u8, version, "-+")) |_| .dev else .release;
}

fn getDefaultUrl(allocator: Allocator, compiler_version: []const u8) ![]const u8 {
    return switch (determineVersionKind(compiler_version)) {
        .dev => try std.fmt.allocPrint(allocator, "https://ziglang.org/builds/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext, .{compiler_version}),
        .release => try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{s}/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext, .{compiler_version}),
    };
}

fn installCompiler(allocator: Allocator, compiler_dir: []const u8, url: []const u8) !void {
    if (try existsAbsolute(compiler_dir)) {
        logi("compiler '{s}' already installed", .{compiler_dir});
        return;
    }

    const installing_dir = try std.mem.concat(allocator, u8, &[_][]const u8{ compiler_dir, ".installing" });
    defer allocator.free(installing_dir);
    try loggyDeleteTreeAbsolute(installing_dir);
    try makeDirIfMissing(installing_dir);

    const archive_basename = std.fs.path.basename(url);
    var archive_root_dir: []const u8 = undefined;

    // download and extract archive
    {
        const archive_absolute = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_basename });
        defer allocator.free(archive_absolute);
        logi("downloading '{s}' to '{s}'", .{ url, archive_absolute });

        switch (blk: {
            const file = try std.fs.createFileAbsolute(archive_absolute, .{});
            // note: important to close the file before we handle errors below
            //       since it will delete the parent directory of this file
            defer file.close();
            break :blk download(allocator, url, file.writer());
        }) {
            .ok => {},
            .err => |err| {
                std.log.err("download '{s}' failed: {s}", .{ url, err });
                // this removes the installing dir if the http request fails so we dont have random directories
                try loggyDeleteTreeAbsolute(installing_dir);
                return error.AlreadyReported;
            },
        }

        if (std.mem.endsWith(u8, archive_basename, ".tar.xz")) {
            archive_root_dir = archive_basename[0 .. archive_basename.len - ".tar.xz".len];
            _ = try run(allocator, &[_][]const u8{ "tar", "xf", archive_absolute, "-C", installing_dir });
        } else {
            var recognized = false;
            if (builtin.os.tag == .windows) {
                if (std.mem.endsWith(u8, archive_basename, ".zip")) {
                    recognized = true;
                    archive_root_dir = archive_basename[0 .. archive_basename.len - ".zip".len];

                    var installing_dir_opened = try std.fs.openDirAbsolute(installing_dir, .{});
                    defer installing_dir_opened.close();
                    logi("extracting archive to \"{s}\"", .{installing_dir});
                    var timer = try std.time.Timer.start();
                    var archive_file = try std.fs.openFileAbsolute(archive_absolute, .{});
                    defer archive_file.close();
                    try std.zip.extract(installing_dir_opened, archive_file.seekableStream(), .{});
                    const time = timer.read();
                    logi("extracted archive in {d:.2} s", .{@as(f32, @floatFromInt(time)) / @as(f32, @floatFromInt(std.time.ns_per_s))});
                }
            }

            if (!recognized) {
                std.log.err("unknown archive extension '{s}'", .{archive_basename});
                return error.UnknownArchiveExtension;
            }
        }
        try loggyDeleteTreeAbsolute(archive_absolute);
    }

    {
        const extracted_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_root_dir });
        defer allocator.free(extracted_dir);
        const normalized_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, "files" });
        defer allocator.free(normalized_dir);
        try loggyRenameAbsolute(extracted_dir, normalized_dir);
    }

    // TODO: write date information (so users can sort compilers by date)

    // finish installation by renaming the install dir
    try loggyRenameAbsolute(installing_dir, compiler_dir);
}

pub fn run(allocator: Allocator, argv: []const []const u8) !std.process.Child.Term {
    try logRun(allocator, argv);
    var proc = std.process.Child.init(argv, allocator);
    return proc.spawnAndWait();
}

fn logRun(allocator: Allocator, argv: []const []const u8) !void {
    var buffer = try allocator.alloc(u8, getCommandStringLength(argv));
    defer allocator.free(buffer);

    var prefix = false;
    var offset: usize = 0;
    for (argv) |arg| {
        if (prefix) {
            buffer[offset] = ' ';
            offset += 1;
        } else {
            prefix = true;
        }
        @memcpy(buffer[offset .. offset + arg.len], arg);
        offset += arg.len;
    }
    std.debug.assert(offset == buffer.len);
    logi("[RUN] {s}", .{buffer});
}

pub fn getCommandStringLength(argv: []const []const u8) usize {
    var len: usize = 0;
    var prefix_length: u8 = 0;
    for (argv) |arg| {
        len += prefix_length + arg.len;
        prefix_length = 1;
    }
    return len;
}

pub fn getKeepReason(master_points_to_opt: ?[]const u8, default_compiler_opt: ?[]const u8, name: []const u8) ?[]const u8 {
    if (default_compiler_opt) |default_comp| {
        if (mem.eql(u8, default_comp, name)) {
            return "is default compiler";
        }
    }
    if (master_points_to_opt) |master_points_to| {
        if (mem.eql(u8, master_points_to, name)) {
            return "it is master";
        }
    }
    return null;
}
