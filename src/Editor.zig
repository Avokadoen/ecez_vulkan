const std = @import("std");
const Allocator = std.mem.Allocator;

const zgui = @import("zgui");
const glfw = @import("glfw");

const RenderContext = @import("RenderContext.zig");
const MeshHandle = RenderContext.MeshHandle;
const InstanceHandle = RenderContext.InstanceHandle;

// TODO: try using ecez to make the Editor! :)

const ObjectMetadata = struct {
    name: [:0]const u8,

    pub fn init(allocator: Allocator, name: []const u8, index: u32) !ObjectMetadata {
        const hash_fluff = "##" ++ [_]u8{
            @intCast(u8, index & 0xFF),
            @intCast(u8, (index >> 8) & 0xFF),
            @intCast(u8, (index >> 16) & 0xFF),
            @intCast(u8, (index >> 24) & 0xFF),
        };
        const name_clone = try allocator.alloc(u8, name.len + hash_fluff.len + 1);
        errdefer allocator.free(name_clone);

        std.mem.copy(u8, name_clone, name);
        std.mem.copy(u8, name_clone[name.len..], hash_fluff);
        name_clone[name_clone.len - 1] = 0;

        return ObjectMetadata{
            .name = name_clone[0 .. name_clone.len - 1 :0],
        };
    }

    pub fn deinit(self: ObjectMetadata, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

const PersistentState = struct {
    selected_instance: ?InstanceHandle = null,
};

/// This type maps an instance handle with a name and other metadata in the editor
const EditorObjectMap = std.AutoArrayHashMap(InstanceHandle, ObjectMetadata);

// TODO: editor should not be part of renderer

/// Editor for making scenes
const Editor = @This();

allocator: Allocator,
instance_metadata_map: EditorObjectMap,
persistent_state: PersistentState,

pointing_hand: glfw.Cursor,
arrow: glfw.Cursor,
ibeam: glfw.Cursor,
crosshair: glfw.Cursor,
resize_ns: glfw.Cursor,
resize_ew: glfw.Cursor,
resize_nesw: glfw.Cursor,
resize_nwse: glfw.Cursor,
not_allowed: glfw.Cursor,

pub fn init(allocator: Allocator, instance_handles: [][]const InstanceHandle) !Editor {
    var instance_metadata_map = EditorObjectMap.init(allocator);
    errdefer {
        for (instance_metadata_map.values()) |value| {
            value.deinit(allocator);
        }
        instance_metadata_map.deinit();
    }

    const total_handle_count = blk: {
        var count: usize = 0;
        for (instance_handles) |handles| {
            count += handles.len;
        }
        break :blk count;
    };

    try instance_metadata_map.ensureUnusedCapacity(total_handle_count);
    for (instance_handles) |handles| {
        for (handles) |handle, i| {
            const metadata = try ObjectMetadata.init(allocator, "TODO", @intCast(u32, i));
            instance_metadata_map.putAssumeCapacity(handle, metadata);
        }
    }

    const persistent_state = PersistentState{
        .selected_instance = null,
    };

    // Color scheme
    const StyleCol = zgui.StyleCol;
    const style = zgui.getStyle();
    style.setColor(StyleCol.title_bg, [4]f32{ 0.1, 0.1, 0.1, 0.85 });
    style.setColor(StyleCol.title_bg_active, [4]f32{ 0.15, 0.15, 0.15, 0.9 });
    style.setColor(StyleCol.menu_bar_bg, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.header, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.check_mark, [4]f32{ 0, 1, 0, 1 });

    const pointing_hand = try glfw.Cursor.createStandard(.pointing_hand);
    errdefer pointing_hand.destroy();
    const arrow = try glfw.Cursor.createStandard(.arrow);
    errdefer arrow.destroy();
    const ibeam = try glfw.Cursor.createStandard(.ibeam);
    errdefer ibeam.destroy();
    const crosshair = try glfw.Cursor.createStandard(.crosshair);
    errdefer crosshair.destroy();
    const resize_ns = try glfw.Cursor.createStandard(.resize_ns);
    errdefer resize_ns.destroy();
    const resize_ew = try glfw.Cursor.createStandard(.resize_ew);
    errdefer resize_ew.destroy();
    const resize_nesw = try glfw.Cursor.createStandard(.resize_nesw);
    errdefer resize_nesw.destroy();
    const resize_nwse = try glfw.Cursor.createStandard(.resize_nwse);
    errdefer resize_nwse.destroy();
    const not_allowed = try glfw.Cursor.createStandard(.not_allowed);
    errdefer not_allowed.destroy();

    return Editor{
        .allocator = allocator,
        .instance_metadata_map = instance_metadata_map,
        .persistent_state = persistent_state,
        .pointing_hand = pointing_hand,
        .arrow = arrow,
        .ibeam = ibeam,
        .crosshair = crosshair,
        .resize_ns = resize_ns,
        .resize_ew = resize_ew,
        .resize_nesw = resize_nesw,
        .resize_nwse = resize_nwse,
        .not_allowed = not_allowed,
    };
}

pub fn newFrame(self: *Editor, window: glfw.Window, delta_time: f32) !void {
    const frame_size = try window.getFramebufferSize();
    zgui.io.setDisplaySize(@intToFloat(f32, frame_size.width), @intToFloat(f32, frame_size.height));
    zgui.io.setDisplayFramebufferScale(1.0, 1.0);

    // NOTE: getting cursor must be done before calling zgui.newFrame
    switch (zgui.getMouseCursor()) {
        .none => window.setCursor(self.pointing_hand) catch {},
        .arrow => window.setCursor(self.arrow) catch {},
        .text_input => window.setCursor(self.ibeam) catch {},
        .resize_all => window.setCursor(self.crosshair) catch {},
        .resize_ns => window.setCursor(self.resize_ns) catch {},
        .resize_ew => window.setCursor(self.resize_ew) catch {},
        .resize_nesw => window.setCursor(self.resize_nesw) catch {},
        .resize_nwse => window.setCursor(self.resize_nwse) catch {},
        .hand => window.setCursor(self.pointing_hand) catch {},
        .not_allowed => window.setCursor(self.not_allowed) catch {},
        .count => window.setCursor(self.ibeam) catch {},
    }

    zgui.newFrame();
    defer zgui.render();

    zgui.io.setDeltaTime(delta_time);

    var b = true;
    _ = zgui.showDemoWindow(&b);

    // define editor header
    const header_height = blk1: {
        if (zgui.beginMainMenuBar() == false) {
            break :blk1 0;
        }
        defer zgui.endMainMenuBar();

        blk2: {
            if (zgui.beginMenu("File", true) == false) {
                break :blk2;
            }
            defer zgui.endMenu();

            if (zgui.menuItem("Export", .{})) {
                std.debug.print("export", .{});
            }

            if (zgui.menuItem("Import", .{})) {
                std.debug.print("import", .{});
            }

            if (zgui.menuItem("Load new model", .{})) {
                std.debug.print("load new model", .{});
            }
        }

        blk2: {
            if (zgui.beginMenu("Window", true) == false) {
                break :blk2;
            }
            defer zgui.endMenu();

            // TODO: array that defines each window, loop them here to make them toggleable
            if (zgui.menuItem("Object list", .{})) {
                std.debug.print("object list", .{});
            }

            if (zgui.menuItem("Debug log", .{})) {
                std.debug.print("debug log", .{});
            }
        }

        blk2: {
            if (zgui.beginMenu("Objects", true) == false) {
                break :blk2;
            }
            defer zgui.endMenu();

            if (zgui.menuItem("Create new", .{})) {
                std.debug.print("create new object", .{});
            }
        }

        break :blk1 zgui.getWindowHeight();
    };

    // define Entity List
    {
        const width = @intToFloat(f32, frame_size.width) / 8;

        zgui.setNextWindowSize(.{ .w = width, .h = @intToFloat(f32, frame_size.height), .cond = .always });
        zgui.setNextWindowPos(.{ .x = 0, .y = header_height, .cond = .always });
        _ = zgui.begin("Object List", .{ .popen = null, .flags = .{
            .menu_bar = false,
            .no_move = true,
            .no_resize = false,
            .no_scrollbar = false,
            .no_scroll_with_mouse = false,
            .no_collapse = true,
        } });
        defer zgui.end();

        {
            if (zgui.beginPopupContextWindow()) {
                defer zgui.endPopup();

                zgui.text("create new object", .{});
            }

            // selected instance is either our persistent user selction, or an invalid/unlikely InstanceHandle.
            var invalid_instance: u64 = std.math.maxInt(u64);
            var selected_instance = self.persistent_state.selected_instance orelse @bitCast(InstanceHandle, invalid_instance);

            var instance_metadata_iterator = self.instance_metadata_map.iterator();
            while (instance_metadata_iterator.next()) |kv_instance_metadata| {
                const instance_handle: InstanceHandle = kv_instance_metadata.key_ptr.*;
                const metadata: *ObjectMetadata = kv_instance_metadata.value_ptr;

                if (zgui.selectable(metadata.name, .{
                    .selected = instance_handle.instance_handle == selected_instance.instance_handle,
                    .flags = .{ .allow_double_click = false },
                })) {
                    self.persistent_state.selected_instance = instance_handle;
                }
            }
        }
    }

    // define Entity Inspector
    {
        const width = @intToFloat(f32, frame_size.width) / 8;

        zgui.setNextWindowSize(.{ .w = width, .h = @intToFloat(f32, frame_size.height), .cond = .always });
        zgui.setNextWindowPos(.{ .x = @intToFloat(f32, frame_size.width) - width, .y = header_height, .cond = .always });
        _ = zgui.begin("Object Inspector", .{ .popen = null, .flags = .{
            .menu_bar = false,
            .no_move = true,
            .no_resize = false,
            .no_scrollbar = false,
            .no_scroll_with_mouse = false,
            .no_collapse = true,
        } });
        defer zgui.end();

        {
            if (zgui.treeNode("hello ")) {
                defer zgui.treePop();

                zgui.text("world!", .{});
            }
        }
    }
}

pub fn deinit(self: *Editor) void {
    for (self.instance_metadata_map.values()) |value| {
        value.deinit(self.allocator);
    }
    self.instance_metadata_map.deinit();

    self.pointing_hand.destroy();
    self.arrow.destroy();
    self.ibeam.destroy();
    self.crosshair.destroy();
    self.resize_ns.destroy();
    self.resize_ew.destroy();
    self.resize_nesw.destroy();
    self.resize_nwse.destroy();
    self.not_allowed.destroy();
}

/// register input so only editor handles glfw input
pub fn setEditorInput(self: Editor, window: glfw.Window) void {
    _ = self;
    _ = window.setKeyCallback(keyCallback);
    _ = window.setCharCallback(charCallback);
    _ = window.setMouseButtonCallback(mouseButtonCallback);
    _ = window.setCursorPosCallback(cursorPosCallback);
    _ = window.setScrollCallback(scrollCallback);
}

pub fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = scancode;

    // apply modifiers
    zgui.io.addKeyEvent(zgui.Key.mod_shift, mods.shift);
    zgui.io.addKeyEvent(zgui.Key.mod_ctrl, mods.control);
    zgui.io.addKeyEvent(zgui.Key.mod_alt, mods.alt);
    zgui.io.addKeyEvent(zgui.Key.mod_super, mods.super);
    // zgui.addKeyEvent(zgui.Key.mod_caps_lock, mod.caps_lock);
    // zgui.addKeyEvent(zgui.Key.mod_num_lock, mod.num_lock);

    zgui.io.addKeyEvent(mapGlfwKeyToImgui(key), action == .press);
}

pub fn charCallback(window: glfw.Window, codepoint: u21) void {
    _ = window;

    var buffer: [8]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, buffer[0..]) catch return;
    const cstr = buffer[0 .. len + 1];
    cstr[len] = 0; // null terminator
    zgui.io.addInputCharactersUTF8(@ptrCast([*:0]const u8, cstr.ptr));
}

pub fn mouseButtonCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;

    if (switch (button) {
        .left => zgui.MouseButton.left,
        .right => zgui.MouseButton.right,
        .middle => zgui.MouseButton.middle,
        .four, .five, .six, .seven, .eight => null,
    }) |zgui_button| {
        // apply modifiers
        zgui.io.addKeyEvent(zgui.Key.mod_shift, mods.shift);
        zgui.io.addKeyEvent(zgui.Key.mod_ctrl, mods.control);
        zgui.io.addKeyEvent(zgui.Key.mod_alt, mods.alt);
        zgui.io.addKeyEvent(zgui.Key.mod_super, mods.super);

        zgui.io.addMouseButtonEvent(zgui_button, action == .press);
    }
}

pub fn cursorPosCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;

    zgui.io.addMousePositionEvent(@floatCast(f32, xpos), @floatCast(f32, ypos));
}

pub fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    _ = window;

    zgui.io.addMouseWheelEvent(@floatCast(f32, xoffset), @floatCast(f32, yoffset));
}

inline fn mapGlfwKeyToImgui(key: glfw.Key) zgui.Key {
    return switch (key) {
        .unknown => zgui.Key.none,
        .space => zgui.Key.space,
        .apostrophe => zgui.Key.apostrophe,
        .comma => zgui.Key.comma,
        .minus => zgui.Key.minus,
        .period => zgui.Key.period,
        .slash => zgui.Key.slash,
        .zero => zgui.Key.zero,
        .one => zgui.Key.one,
        .two => zgui.Key.two,
        .three => zgui.Key.three,
        .four => zgui.Key.four,
        .five => zgui.Key.five,
        .six => zgui.Key.six,
        .seven => zgui.Key.seven,
        .eight => zgui.Key.eight,
        .nine => zgui.Key.nine,
        .semicolon => zgui.Key.semicolon,
        .equal => zgui.Key.equal,
        .a => zgui.Key.a,
        .b => zgui.Key.b,
        .c => zgui.Key.c,
        .d => zgui.Key.d,
        .e => zgui.Key.e,
        .f => zgui.Key.f,
        .g => zgui.Key.g,
        .h => zgui.Key.h,
        .i => zgui.Key.i,
        .j => zgui.Key.j,
        .k => zgui.Key.k,
        .l => zgui.Key.l,
        .m => zgui.Key.m,
        .n => zgui.Key.n,
        .o => zgui.Key.o,
        .p => zgui.Key.p,
        .q => zgui.Key.q,
        .r => zgui.Key.r,
        .s => zgui.Key.s,
        .t => zgui.Key.t,
        .u => zgui.Key.u,
        .v => zgui.Key.v,
        .w => zgui.Key.w,
        .x => zgui.Key.x,
        .y => zgui.Key.y,
        .z => zgui.Key.z,
        .left_bracket => zgui.Key.left_bracket,
        .backslash => zgui.Key.back_slash,
        .right_bracket => zgui.Key.right_bracket,
        .grave_accent => zgui.Key.grave_accent,
        .world_1 => zgui.Key.none, // ????
        .world_2 => zgui.Key.none, // ????
        .escape => zgui.Key.escape,
        .enter => zgui.Key.enter,
        .tab => zgui.Key.tab,
        .backspace => zgui.Key.back_space,
        .insert => zgui.Key.insert,
        .delete => zgui.Key.delete,
        .right => zgui.Key.right_arrow,
        .left => zgui.Key.left_arrow,
        .down => zgui.Key.down_arrow,
        .up => zgui.Key.up_arrow,
        .page_up => zgui.Key.page_up,
        .page_down => zgui.Key.page_down,
        .home => zgui.Key.home,
        .end => zgui.Key.end,
        .caps_lock => zgui.Key.caps_lock,
        .scroll_lock => zgui.Key.scroll_lock,
        .num_lock => zgui.Key.num_lock,
        .print_screen => zgui.Key.print_screen,
        .pause => zgui.Key.pause,
        .F1 => zgui.Key.f1,
        .F2 => zgui.Key.f2,
        .F3 => zgui.Key.f3,
        .F4 => zgui.Key.f4,
        .F5 => zgui.Key.f5,
        .F6 => zgui.Key.f6,
        .F7 => zgui.Key.f7,
        .F8 => zgui.Key.f8,
        .F9 => zgui.Key.f9,
        .F10 => zgui.Key.f10,
        .F11 => zgui.Key.f11,
        .F12 => zgui.Key.f12,
        .F13,
        .F14,
        .F15,
        .F16,
        .F17,
        .F18,
        .F19,
        .F20,
        .F21,
        .F22,
        .F23,
        .F24,
        .F25,
        => zgui.Key.none,
        .kp_0 => zgui.Key.keypad_0,
        .kp_1 => zgui.Key.keypad_1,
        .kp_2 => zgui.Key.keypad_2,
        .kp_3 => zgui.Key.keypad_3,
        .kp_4 => zgui.Key.keypad_4,
        .kp_5 => zgui.Key.keypad_5,
        .kp_6 => zgui.Key.keypad_6,
        .kp_7 => zgui.Key.keypad_7,
        .kp_8 => zgui.Key.keypad_8,
        .kp_9 => zgui.Key.keypad_9,
        .kp_decimal => zgui.Key.keypad_decimal,
        .kp_divide => zgui.Key.keypad_divide,
        .kp_multiply => zgui.Key.keypad_multiply,
        .kp_subtract => zgui.Key.keypad_subtract,
        .kp_add => zgui.Key.keypad_add,
        .kp_enter => zgui.Key.keypad_enter,
        .kp_equal => zgui.Key.keypad_equal,
        .left_shift => zgui.Key.left_shift,
        .left_control => zgui.Key.left_ctrl,
        .left_alt => zgui.Key.left_alt,
        .left_super => zgui.Key.left_super,
        .right_shift => zgui.Key.right_shift,
        .right_control => zgui.Key.right_ctrl,
        .right_alt => zgui.Key.right_alt,
        .right_super => zgui.Key.right_super,
        .menu => zgui.Key.menu,
    };
}
