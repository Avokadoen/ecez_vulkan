const glfw = @import("zglfw");
const zgui = @import("zgui");

const GlfwCursors = @This();

pointing_hand: *glfw.Cursor,
arrow: *glfw.Cursor,
ibeam: *glfw.Cursor,
crosshair: *glfw.Cursor,
resize_ns: *glfw.Cursor,
resize_ew: *glfw.Cursor,
resize_nesw: *glfw.Cursor,
resize_nwse: *glfw.Cursor,
not_allowed: *glfw.Cursor,

pub fn init() error{CreateCursorFailed}!GlfwCursors {
    const pointing_hand = glfw.Cursor.createStandard(.hand) catch return error.CreateCursorFailed;
    errdefer pointing_hand.destroy();

    const arrow = glfw.Cursor.createStandard(.arrow) catch return error.CreateCursorFailed;
    errdefer arrow.destroy();

    const ibeam = glfw.Cursor.createStandard(.ibeam) catch return error.CreateCursorFailed;
    errdefer ibeam.destroy();

    const crosshair = glfw.Cursor.createStandard(.crosshair) catch return error.CreateCursorFailed;
    errdefer crosshair.destroy();

    const resize_ns = glfw.Cursor.createStandard(.resize_ns) catch return error.CreateCursorFailed;
    errdefer resize_ns.destroy();

    const resize_ew = glfw.Cursor.createStandard(.resize_ew) catch return error.CreateCursorFailed;
    errdefer resize_ew.destroy();

    const resize_nesw = glfw.Cursor.createStandard(.resize_nesw) catch return error.CreateCursorFailed;
    errdefer resize_nesw.destroy();

    const resize_nwse = glfw.Cursor.createStandard(.resize_nwse) catch return error.CreateCursorFailed;
    errdefer resize_nwse.destroy();

    const not_allowed = glfw.Cursor.createStandard(.not_allowed) catch return error.CreateCursorFailed;
    errdefer not_allowed.destroy();

    return GlfwCursors{
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

pub fn deinit(self: GlfwCursors) void {
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

pub fn handleZguiCursor(self: GlfwCursors, window: *glfw.Window) void {
    switch (zgui.getMouseCursor()) {
        .none => window.setInputMode(.cursor, .hidden),
        .arrow => window.setCursor(self.arrow),
        .text_input => window.setCursor(self.ibeam),
        .resize_all => window.setCursor(self.crosshair),
        .resize_ns => window.setCursor(self.resize_ns),
        .resize_ew => window.setCursor(self.resize_ew),
        .resize_nesw => window.setCursor(self.resize_nesw),
        .resize_nwse => window.setCursor(self.resize_nwse),
        .hand => window.setCursor(self.pointing_hand),
        .not_allowed => window.setCursor(self.not_allowed),
        .count => window.setCursor(self.ibeam),
    }
}
