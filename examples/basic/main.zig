const std = @import("std");
const app_bar_lib = @import("windows_app_bar");
const windows = std.os.windows;

const WNDPROC = *const fn (window: windows.HWND, message: windows.UINT, wparam: usize, lparam: isize) callconv(.winapi) isize;
const WNDCLASSEXW = extern struct { cbSize: windows.UINT, style: windows.UINT, window_proc: WNDPROC, class_extra: i32, window_extra: i32, instance: ?windows.HINSTANCE, icon: ?windows.HICON, cursor: ?windows.HCURSOR, background_brush: ?windows.HBRUSH, menu_name: ?windows.LPCWSTR, class_name: windows.LPCWSTR, small_icon: ?windows.HICON };
const POINT = extern struct { x: i32, y: i32 };
const MSG = extern struct { window: ?windows.HWND, message: windows.UINT, wparam: usize, lparam: isize, time: windows.DWORD, point: POINT };

const WS_POPUP: windows.DWORD = 0x80000000;
const WS_OVERLAPPEDWINDOW: windows.DWORD = 0x00cf0000;
const WS_CHILD: windows.DWORD = 0x40000000;
const WS_VISIBLE: windows.DWORD = 0x10000000;
const WS_TABSTOP: windows.DWORD = 0x00010000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: i32 = 5;
const COLOR_WINDOW: usize = 5;
const IDC_ARROW: windows.LPCWSTR = @ptrFromInt(32512);
const WM_CLOSE: windows.UINT = 0x0010;
const WM_DESTROY: windows.UINT = 0x0002;
const WM_COMMAND: windows.UINT = 0x0111;
const WM_DPICHANGED: windows.UINT = 0x02e0;

const button_show = 100;
const button_hide = 101;
const button_edge_left = 110;
const button_edge_top = 111;
const button_edge_right = 112;
const button_edge_bottom = 113;
const button_monitor_previous = 120;
const button_monitor_next = 121;
const button_thickness_64 = 130;
const button_thickness_128 = 131;
const button_thickness_256 = 132;
const button_thickness_320 = 133;
const button_refresh = 140;
const button_unregister = 141;
const button_reregister = 142;
const button_deinit = 143;
const button_register = 144;
const status_control = 200;

const Error = error{ InvalidArguments, WindowClassRegistrationFailed, CursorLoadFailed, WindowCreationFailed, ControlCreationFailed, ConsoleHandlerRegistrationFailed, MessageLoopFailed };
const Config = app_bar_lib.AppBarConfig;

const Application = struct {
    app_bar_window: windows.HWND,
    control_window: ?windows.HWND = null,
    app_bar: ?app_bar_lib.AppBar = null,
    monitors: []app_bar_lib.MonitorInfo,
    selected_monitor_index: u32,
    selected_edge: app_bar_lib.Edge,
    selected_thickness: u32,
    result: [128]u8 = undefined,
    result_length: usize = 0,
    status_text: [512:0]u16 = undefined,

    fn initialConfig(self: *const Application) Config {
        return .{ .monitor = .{ .index = self.selected_monitor_index }, .edge = self.selected_edge, .thickness = self.selected_thickness };
    }
    fn setResult(self: *Application, text: []const u8) void {
        self.result_length = @min(text.len, self.result.len);
        @memcpy(self.result[0..self.result_length], text[0..self.result_length]);
    }
    fn setError(self: *Application, err: anyerror) void {
        const text = std.fmt.bufPrint(&self.result, "Error: {s}", .{@errorName(err)}) catch {
            self.setResult("Error");
            return;
        };
        self.result_length = text.len;
    }
    fn registerAppBar(self: *Application) void {
        if (self.app_bar != null) {
            self.setResult("Already registered");
            self.updateControls();
            return;
        }
        self.app_bar = app_bar_lib.AppBar.register(self.app_bar_window, self.initialConfig()) catch |err| {
            self.setError(err);
            self.updateControls();
            return;
        };
        self.setResult("Registered");
        self.updateControls();
    }
    fn deinitAppBar(self: *Application) void {
        if (self.app_bar) |*app_bar| {
            app_bar.deinit();
            self.app_bar = null;
            self.setResult("Deinitialized");
        } else self.setResult("No AppBar is registered");
        self.updateControls();
    }
    fn updateControls(self: *Application) void {
        const control_window = self.control_window orelse return;
        const has_app_bar = self.app_bar != null;
        const ids = [_]i32{ button_show, button_hide, button_edge_left, button_edge_top, button_edge_right, button_edge_bottom, button_monitor_previous, button_monitor_next, button_thickness_64, button_thickness_128, button_thickness_256, button_thickness_320, button_refresh, button_unregister, button_reregister, button_deinit };
        for (ids) |id| _ = EnableWindow(GetDlgItem(control_window, id), if (has_app_bar) .TRUE else .FALSE);
        _ = EnableWindow(GetDlgItem(control_window, button_register), if (has_app_bar) .FALSE else .TRUE);
        self.updateStatusText(control_window);
    }
    fn updateStatusText(self: *Application, control_window: windows.HWND) void {
        var text: [512]u8 = undefined;
        const status = if (self.app_bar) |*app_bar| @tagName(app_bar.status()) else "deinitialized";
        const registered = if (self.app_bar) |*app_bar| app_bar.isRegistered() else false;
        const visible = if (self.app_bar) |*app_bar| app_bar.isVisible() else false;
        const allocated = if (self.app_bar) |*app_bar| app_bar.allocatedRect() else null;
        const displayed = if (allocated) |rect| std.fmt.bufPrint(&text, "Status: {s}\r\nRegistered: {}\r\nVisible: {}\r\nEdge: {s}\r\nThickness: {} px\r\nFallback monitor: {}\r\nAllocated rect: ({}, {}, {}, {})\r\nLast result: {s}", .{ status, registered, visible, @tagName(self.selected_edge), self.selected_thickness, self.selected_monitor_index, rect.left, rect.top, rect.right, rect.bottom, self.result[0..self.result_length] }) catch "Status text unavailable" else std.fmt.bufPrint(&text, "Status: {s}\r\nRegistered: {}\r\nVisible: {}\r\nEdge: {s}\r\nThickness: {} px\r\nFallback monitor: {}\r\nAllocated rect: none\r\nLast result: {s}", .{ status, registered, visible, @tagName(self.selected_edge), self.selected_thickness, self.selected_monitor_index, self.result[0..self.result_length] }) catch "Status text unavailable";
        setWindowTextAscii(self.status_text[0..], displayed);
        _ = SetWindowTextW(GetDlgItem(control_window, status_control), self.status_text[0..].ptr);
    }
};

var active_application: ?*Application = null;
var app_window = std.atomic.Value(usize).init(0);

extern "kernel32" fn GetModuleHandleW(module_name: ?windows.LPCWSTR) callconv(.winapi) ?windows.HINSTANCE;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (event: windows.DWORD) callconv(.winapi) windows.BOOL, add: windows.BOOL) callconv(.winapi) windows.BOOL;
extern "user32" fn RegisterClassExW(window_class: *const WNDCLASSEXW) callconv(.winapi) windows.ATOM;
extern "user32" fn LoadCursorW(instance: ?windows.HINSTANCE, cursor_name: windows.LPCWSTR) callconv(.winapi) ?windows.HCURSOR;
extern "user32" fn CreateWindowExW(extended_style: windows.DWORD, class_name: windows.LPCWSTR, window_name: ?windows.LPCWSTR, style: windows.DWORD, x: i32, y: i32, width: i32, height: i32, parent: ?windows.HWND, menu: ?windows.HMENU, instance: ?windows.HINSTANCE, parameter: ?windows.LPVOID) callconv(.winapi) ?windows.HWND;
extern "user32" fn DefWindowProcW(window: windows.HWND, message: windows.UINT, wparam: usize, lparam: isize) callconv(.winapi) isize;
extern "user32" fn DestroyWindow(window: windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn ShowWindow(window: windows.HWND, command: i32) callconv(.winapi) windows.BOOL;
extern "user32" fn GetDlgItem(window: windows.HWND, id: i32) callconv(.winapi) ?windows.HWND;
extern "user32" fn EnableWindow(window: ?windows.HWND, enable: windows.BOOL) callconv(.winapi) windows.BOOL;
extern "user32" fn SetWindowTextW(window: ?windows.HWND, text: windows.LPCWSTR) callconv(.winapi) windows.BOOL;
extern "user32" fn GetMessageW(message: *MSG, window: ?windows.HWND, minimum_filter: windows.UINT, maximum_filter: windows.UINT) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(message: *const MSG) callconv(.winapi) windows.BOOL;
extern "user32" fn DispatchMessageW(message: *const MSG) callconv(.winapi) isize;
extern "user32" fn PostMessageW(window: windows.HWND, message: windows.UINT, wparam: usize, lparam: isize) callconv(.winapi) windows.BOOL;
extern "user32" fn PostQuitMessage(exit_code: i32) callconv(.winapi) void;

pub fn main(init: std.process.Init) void {
    run(init.minimal.args) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn run(args: std.process.Args) !void {
    const config = try parseArguments(args);
    const instance = GetModuleHandleW(null) orelse return error.WindowClassRegistrationFailed;
    try registerWindowClass(instance, app_bar_window_class_name, appBarWindowProc);
    try registerWindowClass(instance, control_window_class_name, controlWindowProc);
    const app_bar_window = CreateWindowExW(0, app_bar_window_class_name.ptr, null, WS_POPUP, CW_USEDEFAULT, CW_USEDEFAULT, 1, 1, null, null, instance, null) orelse return error.WindowCreationFailed;
    defer _ = DestroyWindow(app_bar_window);
    const monitors = try app_bar_lib.enumerateMonitors(std.heap.page_allocator);
    defer std.heap.page_allocator.free(monitors);
    var application = Application{ .app_bar_window = app_bar_window, .monitors = monitors, .selected_monitor_index = switch (config.monitor) {
        .index => |index| index,
        .id => 0,
    }, .selected_edge = config.edge, .selected_thickness = config.thickness };
    application.setResult("Ready");
    defer application.deinitAppBar();
    active_application = &application;
    defer active_application = null;
    application.registerAppBar();
    const control_window = try createControlWindow(instance, &application);
    application.control_window = control_window;
    defer _ = DestroyWindow(control_window);
    app_window.store(@intFromPtr(control_window), .release);
    defer app_window.store(0, .release);
    if (!SetConsoleCtrlHandler(consoleControlHandler, .TRUE).toBool()) return error.ConsoleHandlerRegistrationFailed;
    defer _ = SetConsoleCtrlHandler(consoleControlHandler, .FALSE);
    if (application.app_bar) |*app_bar| app_bar.show();
    _ = ShowWindow(control_window, SW_SHOW);
    application.updateControls();
    std.debug.print("AppBar control panel is running. Press Ctrl+C to exit.\n", .{});
    try runMessageLoop();
}
fn createControlWindow(instance: windows.HINSTANCE, application: *Application) Error!windows.HWND {
    const window = CreateWindowExW(0, control_window_class_name.ptr, control_window_title.ptr, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 510, 570, null, null, instance, null) orelse return error.WindowCreationFailed;
    errdefer _ = DestroyWindow(window);
    try createControls(window, instance);
    application.updateStatusText(window);
    return window;
}
fn createControls(parent: windows.HWND, instance: windows.HINSTANCE) Error!void {
    try createStatic(parent, instance, "AppBar controls", 16, 14, 460, 22, 0);
    try createButton(parent, instance, "Show", 16, 46, 108, 30, button_show);
    try createButton(parent, instance, "Hide", 132, 46, 108, 30, button_hide);
    try createButton(parent, instance, "Refresh", 248, 46, 108, 30, button_refresh);
    try createButton(parent, instance, "Unregister", 364, 46, 108, 30, button_unregister);
    try createStatic(parent, instance, "Edge", 16, 90, 80, 20, 0);
    try createButton(parent, instance, "Left", 16, 112, 108, 30, button_edge_left);
    try createButton(parent, instance, "Top", 132, 112, 108, 30, button_edge_top);
    try createButton(parent, instance, "Right", 248, 112, 108, 30, button_edge_right);
    try createButton(parent, instance, "Bottom", 364, 112, 108, 30, button_edge_bottom);
    try createStatic(parent, instance, "Fallback monitor", 16, 158, 160, 20, 0);
    try createButton(parent, instance, "Previous", 16, 180, 108, 30, button_monitor_previous);
    try createButton(parent, instance, "Next", 132, 180, 108, 30, button_monitor_next);
    try createStatic(parent, instance, "Thickness", 16, 226, 120, 20, 0);
    try createButton(parent, instance, "64 px", 16, 248, 108, 30, button_thickness_64);
    try createButton(parent, instance, "128 px", 132, 248, 108, 30, button_thickness_128);
    try createButton(parent, instance, "256 px", 248, 248, 108, 30, button_thickness_256);
    try createButton(parent, instance, "320 px", 364, 248, 108, 30, button_thickness_320);
    try createButton(parent, instance, "Reregister", 16, 302, 108, 30, button_reregister);
    try createButton(parent, instance, "Deinit", 132, 302, 108, 30, button_deinit);
    try createButton(parent, instance, "Register", 248, 302, 108, 30, button_register);
    try createStatic(parent, instance, "State", 16, 350, 80, 20, 0);
    try createStatic(parent, instance, "", 16, 372, 456, 142, status_control);
}
fn createButton(parent: windows.HWND, instance: windows.HINSTANCE, comptime label: []const u8, x: i32, y: i32, width: i32, height: i32, id: usize) Error!void {
    const text = std.unicode.utf8ToUtf16LeStringLiteral(label);
    _ = CreateWindowExW(0, button_class_name.ptr, text.ptr, WS_CHILD | WS_VISIBLE | WS_TABSTOP, x, y, width, height, parent, @ptrFromInt(id), instance, null) orelse return error.ControlCreationFailed;
}
fn createStatic(parent: windows.HWND, instance: windows.HINSTANCE, comptime label: []const u8, x: i32, y: i32, width: i32, height: i32, id: usize) Error!void {
    const text = std.unicode.utf8ToUtf16LeStringLiteral(label);
    _ = CreateWindowExW(0, static_class_name.ptr, text.ptr, WS_CHILD | WS_VISIBLE, x, y, width, height, parent, @ptrFromInt(id), instance, null) orelse return error.ControlCreationFailed;
}
fn parseArguments(args: std.process.Args) !Config {
    var iterator = try std.process.Args.Iterator.initAllocator(args, std.heap.page_allocator);
    defer iterator.deinit();
    _ = iterator.next();
    const index_text = iterator.next() orelse return usage();
    const edge_text = iterator.next() orelse return usage();
    const thickness_text = iterator.next() orelse return usage();
    if (iterator.next() != null) return usage();
    const index = std.fmt.parseInt(u32, index_text, 10) catch return usage();
    const thickness = std.fmt.parseInt(u32, thickness_text, 10) catch return usage();
    if (thickness == 0) return usage();
    return .{ .monitor = .{ .index = index }, .edge = parseEdge(edge_text) orelse return usage(), .thickness = thickness };
}
fn parseEdge(text: []const u8) ?app_bar_lib.Edge {
    if (std.mem.eql(u8, text, "left")) return .left;
    if (std.mem.eql(u8, text, "top")) return .top;
    if (std.mem.eql(u8, text, "right")) return .right;
    if (std.mem.eql(u8, text, "bottom")) return .bottom;
    return null;
}
fn usage() Error {
    std.debug.print("Usage: zig build example-basic -- <monitor_index> <left|top|right|bottom> <thickness>\n", .{});
    return error.InvalidArguments;
}
fn registerWindowClass(instance: windows.HINSTANCE, class_name: windows.LPCWSTR, window_proc: WNDPROC) Error!void {
    const cursor = LoadCursorW(null, IDC_ARROW) orelse return error.CursorLoadFailed;
    const window_class = WNDCLASSEXW{ .cbSize = @sizeOf(WNDCLASSEXW), .style = 0, .window_proc = window_proc, .class_extra = 0, .window_extra = 0, .instance = instance, .icon = null, .cursor = cursor, .background_brush = @ptrFromInt(COLOR_WINDOW + 1), .menu_name = null, .class_name = class_name, .small_icon = null };
    if (RegisterClassExW(&window_class) == 0) return error.WindowClassRegistrationFailed;
}
fn appBarWindowProc(window: windows.HWND, message: windows.UINT, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (active_application) |application| if (window == application.app_bar_window) if (application.app_bar) |*app_bar| {
        const consumed = app_bar.handleMessage(message, wparam, lparam) catch |err| {
            application.setError(err);
            application.updateControls();
            return 0;
        };
        if (message == WM_DPICHANGED) {
            // The AppBar has applied its shell-approved placement; update DPI-dependent resources here.
            return 0;
        }
        if (consumed) return 0;
    };
    switch (message) {
        WM_CLOSE => {
            _ = DestroyWindow(window);
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(window, message, wparam, lparam),
    }
}
fn controlWindowProc(window: windows.HWND, message: windows.UINT, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (message) {
        WM_COMMAND => {
            if (highWord(wparam) == 0) handleCommand(lowWord(wparam));
            return 0;
        },
        WM_CLOSE => {
            _ = DestroyWindow(window);
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(window, message, wparam, lparam),
    }
}
fn handleCommand(id: usize) void {
    const application = active_application orelse return;
    switch (id) {
        button_register => application.registerAppBar(),
        button_deinit => application.deinitAppBar(),
        else => {
            const app_bar = &(application.app_bar orelse return);
            switch (id) {
                button_show => {
                    app_bar.show();
                    application.setResult("Shown");
                },
                button_hide => {
                    app_bar.hide();
                    application.setResult("Hidden");
                },
                button_edge_left => setEdge(application, .left),
                button_edge_top => setEdge(application, .top),
                button_edge_right => setEdge(application, .right),
                button_edge_bottom => setEdge(application, .bottom),
                button_monitor_previous => setFallbackMonitor(application, false),
                button_monitor_next => setFallbackMonitor(application, true),
                button_thickness_64 => setThickness(application, 64),
                button_thickness_128 => setThickness(application, 128),
                button_thickness_256 => setThickness(application, 256),
                button_thickness_320 => setThickness(application, 320),
                button_refresh => app_bar.refresh() catch |err| application.setError(err),
                button_unregister => {
                    app_bar.unregister();
                    application.setResult("Unregistered");
                },
                button_reregister => app_bar.reregister() catch |err| application.setError(err),
                else => return,
            }
            application.updateControls();
        },
    }
}
fn setEdge(application: *Application, edge: app_bar_lib.Edge) void {
    const app_bar = &(application.app_bar orelse return);
    app_bar.setEdge(edge) catch |err| {
        application.setError(err);
        return;
    };
    application.selected_edge = edge;
    application.setResult("Edge updated");
}
fn setFallbackMonitor(application: *Application, move_forward: bool) void {
    if (application.monitors.len == 0) {
        application.setResult("No monitors found");
        return;
    }
    const current: usize = application.selected_monitor_index;
    const selected: usize = if (move_forward) (current + 1) % application.monitors.len else (current + application.monitors.len - 1) % application.monitors.len;
    const app_bar = &(application.app_bar orelse return);
    app_bar.setFallbackMonitorIndex(@intCast(selected)) catch |err| {
        application.setError(err);
        return;
    };
    application.selected_monitor_index = @intCast(selected);
    application.setResult("Fallback monitor updated");
}
fn setThickness(application: *Application, thickness: u32) void {
    const app_bar = &(application.app_bar orelse return);
    app_bar.setThickness(thickness) catch |err| {
        application.setError(err);
        return;
    };
    application.selected_thickness = thickness;
    application.setResult("Thickness updated");
}
fn lowWord(value: usize) usize {
    return value & 0xffff;
}
fn highWord(value: usize) usize {
    return (value >> 16) & 0xffff;
}
fn setWindowTextAscii(destination: []u16, source: []const u8) void {
    const length = @min(destination.len - 1, source.len);
    for (source[0..length], 0..) |byte, index| destination[index] = byte;
    destination[length] = 0;
}
fn consoleControlHandler(_: windows.DWORD) callconv(.winapi) windows.BOOL {
    const window_address = app_window.load(.acquire);
    if (window_address == 0) return .FALSE;
    _ = PostMessageW(@ptrFromInt(window_address), WM_CLOSE, 0, 0);
    return .TRUE;
}
fn runMessageLoop() Error!void {
    var message: MSG = undefined;
    while (true) {
        const result = GetMessageW(&message, null, 0, 0);
        if (result == -1) return error.MessageLoopFailed;
        if (result == 0) return;
        _ = TranslateMessage(&message);
        _ = DispatchMessageW(&message);
    }
}
const app_bar_window_class_name = std.unicode.utf8ToUtf16LeStringLiteral("windows_app_bar.basic.AppBarWindow");
const control_window_class_name = std.unicode.utf8ToUtf16LeStringLiteral("windows_app_bar.basic.ControlWindow");
const control_window_title = std.unicode.utf8ToUtf16LeStringLiteral("Windows AppBar Basic Example");
const button_class_name = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
const static_class_name = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
