const std = @import("std");
const Allocator = std.mem.Allocator;

const tracy = @import("ztracy");

const AssetHandler = @This();

const prefix = "../../assets/";

exe_path: []const u8,

pub fn init(allocator: Allocator) !AssetHandler {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    return AssetHandler{
        .exe_path = exe_path,
    };
}

pub fn deinit(self: AssetHandler, allocator: Allocator) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    allocator.free(self.exe_path);
}

pub inline fn getPath(self: AssetHandler, allocator: Allocator, file_path: []const u8) ![]const u8 {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const join_path = [_][]const u8{ self.exe_path, prefix, file_path };
    return std.fs.path.resolve(allocator, join_path[0..]);
}

pub inline fn getCPath(self: AssetHandler, allocator: Allocator, file_path: []const u8) ![:0]const u8 {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const join_path = [_][]const u8{ self.exe_path, prefix, file_path };
    const absolute_file_path = try std.fs.path.resolve(allocator, &join_path);
    defer allocator.free(absolute_file_path);

    return allocator.dupeZ(u8, absolute_file_path);
}
