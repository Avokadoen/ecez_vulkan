const std = @import("std");
const Allocator = std.mem.Allocator;

const AssetHandler = @This();

const prefix = "../../assets/";

exe_path: []const u8,

pub fn init(allocator: Allocator) !AssetHandler {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    return AssetHandler{
        .exe_path = exe_path,
    };
}

pub fn deinit(self: AssetHandler, allocator: Allocator) void {
    allocator.free(self.exe_path);
}

pub inline fn getPath(self: AssetHandler, allocator: Allocator, file_path: []const u8) ![]const u8 {
    const join_path = [_][]const u8{ self.exe_path, prefix, file_path };
    return std.fs.path.resolve(allocator, join_path[0..]);
}

pub inline fn getCPath(self: AssetHandler, allocator: Allocator, file_path: []const u8) ![:0]const u8 {
    const join_path = [_][]const u8{ self.exe_path, prefix, file_path };
    var absolute_file_path = try std.fs.path.resolve(allocator, &join_path);
    defer allocator.free(absolute_file_path);

    return std.cstr.addNullByte(allocator, absolute_file_path);
}
