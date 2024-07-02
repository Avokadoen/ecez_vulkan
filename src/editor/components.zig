const tracy = @import("ztracy");
const ecez = @import("ecez");
const std = @import("std");

pub const all = [_]type{
    EntityMetadata,
};

pub const EntityMetadata = struct {
    const buffer_len = 128;
    const hash_len = "##".len + @sizeOf(ecez.Entity);

    id_len: u8,
    id_buffer: [buffer_len]u8,

    pub fn init(name: []const u8, entity: ecez.Entity) EntityMetadata {
        const zone = tracy.ZoneN(@src(), @src().fn_name);
        defer zone.End();

        const id_len = name.len + hash_len;
        std.debug.assert(id_len < buffer_len);

        const hash_fluff = "##" ++ std.mem.asBytes(&entity.id);
        var id_buffer: [buffer_len]u8 = undefined;

        @memcpy(id_buffer[0..name.len], name);
        @memcpy(id_buffer[name.len .. name.len + hash_fluff.len], hash_fluff);
        id_buffer[id_len] = 0;

        return EntityMetadata{
            .id_len = @intCast(id_len),
            .id_buffer = id_buffer,
        };
    }

    pub fn rename(self: *EntityMetadata, name: []const u8) void {
        const zone = tracy.ZoneN(@src(), @src().fn_name);
        defer zone.End();

        const id_len = name.len + hash_len;
        std.debug.assert(id_len < buffer_len);

        // move the hash to its new postion
        // we could use mem.rotate to perf
        const hash_start_pos = self.id_len - hash_len;
        var tmp_hash_buffer: [hash_len]u8 = undefined;
        @memcpy(tmp_hash_buffer[0..hash_len], self.id_buffer[hash_start_pos .. hash_start_pos + hash_len]);
        @memcpy(self.id_buffer[name.len .. name.len + hash_len], tmp_hash_buffer[0..hash_len]);

        // copy new name over
        @memcpy(self.id_buffer[0..name.len], name);
        self.id_buffer[id_len] = 0;
        self.id_len = @intCast(id_len);
    }

    pub inline fn getId(self: EntityMetadata) [:0]const u8 {
        return self.id_buffer[0..self.id_len :0];
    }

    pub inline fn getDisplayName(self: EntityMetadata) []const u8 {
        // name - "##xyzw"
        return self.id_buffer[0 .. self.id_len - hash_len];
    }
};
