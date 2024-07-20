const glfw = @import("glfw");

pub const UserPointerType = enum(u32) {
    undefined,
    editor,
    game,
    render,
};

const UserPointer = extern struct {
    type: UserPointerType = .undefined,
    next: ?*UserPointer,
    ptr: *anyopaque,
};

/// Find next user pointer of a given type
pub fn findUserPointer(comptime UserPointerT: type, window: glfw.Window) ?*UserPointerT {
    const type_value = comptime getUserPointerTypeValue(UserPointerT);

    var user_ptr = window.getUserPointer(UserPointer) orelse return null;
    while (user_ptr.type != type_value) {
        user_ptr = user_ptr.next orelse return null;
    }

    return @as(*UserPointerT, @ptrCast(user_ptr));
}

inline fn getUserPointerTypeValue(comptime UserPointerT: type) UserPointerType {
    comptime {
        if (@sizeOf(UserPointerT) != @sizeOf(UserPointer)) {
            @compileError(@typeName(UserPointerT) ++ " does not have a valid user pointer size of " ++ @sizeOf(UserPointer));
        }

        const user_pointer_info = @typeInfo(UserPointerT);

        const struct_info = struct_info_blk: {
            if (user_pointer_info != .Struct) {
                @compileError(@typeName(UserPointerT) ++ " must be a struct");
            }

            break :struct_info_blk user_pointer_info.Struct;
        };

        if (3 != struct_info.fields.len) {
            @compileError(@typeName(UserPointerT) ++ " must have 3 fields");
        }

        if (UserPointerType != struct_info.fields[0].type) {
            @compileError(@typeName(UserPointerT) ++ " first field must be of type " ++ @typeName(UserPointerType));
        }

        const default_value = struct_info.fields[0].default_value orelse @compileError(@typeName(UserPointerT) ++ " field " ++ @typeName(UserPointerType) ++ " must have default value");
        return @as(*const UserPointerType, @ptrCast(@alignCast(default_value))).*;
    }
}

/// handle frame buffer resize and register self.user_pointer
pub fn handleFramebufferResize(comptime Self: type, self: *Self, window: glfw.Window) void {
    self.render_context.handleFramebufferResize(window, false);

    self.user_pointer = Self.UserPointer{
        .ptr = self,
        .next = @ptrCast(&self.render_context.user_pointer),
    };

    window.setUserPointer(&self.user_pointer);
}
