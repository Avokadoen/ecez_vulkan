const std = @import("std");

const zgui = @import("zgui");
const glfw = @import("glfw");

// TODO: editor should not be part of renderer

/// Editor for making scenes
const Editor = @This();

window: glfw.Window,

pointing_hand: glfw.Cursor,
arrow: glfw.Cursor,
ibeam: glfw.Cursor,
crosshair: glfw.Cursor,
resize_ns: glfw.Cursor,
resize_ew: glfw.Cursor,
resize_nesw: glfw.Cursor,
resize_nwse: glfw.Cursor,
not_allowed: glfw.Cursor,

pub fn init(window: glfw.Window) !Editor {
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
        .window = window,
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

pub fn newFrame(self: Editor, frame_width: u32, frame_height: u32) void {
    // NOTE: getting cursor must be done before calling zgui.newFrame
    switch (zgui.getMouseCursor()) {
        .none => self.window.setCursor(self.pointing_hand) catch {},
        .arrow => self.window.setCursor(self.arrow) catch {},
        .text_input => self.window.setCursor(self.ibeam) catch {},
        .resize_all => self.window.setCursor(self.crosshair) catch {},
        .resize_ns => self.window.setCursor(self.resize_ns) catch {},
        .resize_ew => self.window.setCursor(self.resize_ew) catch {},
        .resize_nesw => self.window.setCursor(self.resize_nesw) catch {},
        .resize_nwse => self.window.setCursor(self.resize_nwse) catch {},
        .hand => self.window.setCursor(self.pointing_hand) catch {},
        .not_allowed => self.window.setCursor(self.not_allowed) catch {},
        .count => self.window.setCursor(self.ibeam) catch {},
    }

    zgui.newFrame();
    defer zgui.render();

    _ = frame_width;
    _ = frame_height;

    // const style = zgui.getStyle();
    var b = true;
    _ = zgui.showDemoWindow(&b);
    // define editor header
    // {
    //     const rounding = style.window_rounding;
    //     defer style.window_rounding = rounding;

    //     style.window_rounding = 0;

    //     zgui.setNextWindowSize(.{ .w = @intToFloat(f32, frame_width), .h = @intToFloat(f32, frame_height), .cond = .always });
    //     _ = zgui.begin("main menu", .{ .popen = null, .flags = .{
    //         .menu_bar = true,
    //         .no_move = true,
    //         .no_resize = true,
    //         .no_title_bar = false,
    //         .no_scrollbar = true,
    //         .no_scroll_with_mouse = true,
    //         .no_collapse = true,
    //         .no_background = true,
    //     } });

    //     blk: {
    //         if (zgui.beginMenuBar() == false) {
    //             break :blk;
    //         }
    //         defer zgui.endMenuBar();

    //         if (zgui.beginMenu("Hello world", true) == false) {
    //             break :blk;
    //         }
    //         defer zgui.endMenu();

    //         if (zgui.menuItem("Camera", .{})) {
    //             @import("std").debug.print("awesome", .{});
    //         }
    //     }

    //     defer zgui.end();
    // }
}

pub fn deinit(self: Editor) void {
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
pub fn setEditorInput(self: Editor) void {
    _ = self.window.setKeyCallback(keyCallback);
    _ = self.window.setCharCallback(charCallback);
    _ = self.window.setMouseButtonCallback(mouseButtonCallback);
    _ = self.window.setCursorPosCallback(cursorPosCallback);
    _ = self.window.setScrollCallback(scrollCallback);
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
