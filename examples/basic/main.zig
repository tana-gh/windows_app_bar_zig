const std = @import("std");
const app_bar_lib = @import("windows_app_bar");
const windows = std.os.windows;

const WNDPROC = *const fn (
    window: windows.HWND,
    message: windows.UINT,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize;

const WNDCLASSEXW = extern struct {
    cbSize: windows.UINT,
    style: windows.UINT,
    window_proc: WNDPROC,
    class_extra: i32,
    window_extra: i32,
    instance: ?windows.HINSTANCE,
    icon: ?windows.HICON,
    cursor: ?windows.HCURSOR,
    background_brush: ?windows.HBRUSH,
    menu_name: ?windows.LPCWSTR,
    class_name: windows.LPCWSTR,
    small_icon: ?windows.HICON,
};

const POINT = extern struct {
    x: i32,
    y: i32,
};

const MSG = extern struct {
    window: ?windows.HWND,
    message: windows.UINT,
    wparam: usize,
    lparam: isize,
    time: windows.DWORD,
    point: POINT,
};

const WS_POPUP: windows.DWORD = 0x80000000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: i32 = 5;
const COLOR_WINDOW: usize = 5;
const IDC_ARROW: windows.LPCWSTR = @ptrFromInt(32512);
const WM_CLOSE: windows.UINT = 0x0010;
const WM_DESTROY: windows.UINT = 0x0002;
const WM_QUIT: windows.UINT = 0x0012;

const Error = error{
    InvalidArguments,
    WindowClassRegistrationFailed,
    CursorLoadFailed,
    WindowCreationFailed,
    ConsoleHandlerRegistrationFailed,
    MessageLoopFailed,
};

var active_app_bar: ?*app_bar_lib.AppBar = null;
var app_window = std.atomic.Value(usize).init(0);

extern "kernel32" fn GetModuleHandleW(module_name: ?windows.LPCWSTR) callconv(.winapi) ?windows.HINSTANCE;

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (event: windows.DWORD) callconv(.winapi) windows.BOOL,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

extern "user32" fn RegisterClassExW(window_class: *const WNDCLASSEXW) callconv(.winapi) windows.ATOM;
extern "user32" fn LoadCursorW(
    instance: ?windows.HINSTANCE,
    cursor_name: windows.LPCWSTR,
) callconv(.winapi) ?windows.HCURSOR;
extern "user32" fn CreateWindowExW(
    extended_style: windows.DWORD,
    class_name: windows.LPCWSTR,
    window_name: ?windows.LPCWSTR,
    style: windows.DWORD,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?windows.HWND,
    menu: ?windows.HMENU,
    instance: ?windows.HINSTANCE,
    parameter: ?windows.LPVOID,
) callconv(.winapi) ?windows.HWND;
extern "user32" fn DefWindowProcW(
    window: windows.HWND,
    message: windows.UINT,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize;
extern "user32" fn DestroyWindow(window: windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn ShowWindow(window: windows.HWND, command: i32) callconv(.winapi) windows.BOOL;
extern "user32" fn GetMessageW(
    message: *MSG,
    window: ?windows.HWND,
    minimum_filter: windows.UINT,
    maximum_filter: windows.UINT,
) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(message: *const MSG) callconv(.winapi) windows.BOOL;
extern "user32" fn DispatchMessageW(message: *const MSG) callconv(.winapi) isize;
extern "user32" fn PostMessageW(
    window: windows.HWND,
    message: windows.UINT,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) windows.BOOL;
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
    try registerWindowClass(instance);

    const window = CreateWindowExW(
        0,
        window_class_name.ptr,
        null,
        WS_POPUP,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1,
        1,
        null,
        null,
        instance,
        null,
    ) orelse return error.WindowCreationFailed;
    defer _ = DestroyWindow(window);

    app_window.store(@intFromPtr(window), .release);
    defer app_window.store(0, .release);

    if (!SetConsoleCtrlHandler(consoleControlHandler, .TRUE).toBool()) {
        return error.ConsoleHandlerRegistrationFailed;
    }
    defer _ = SetConsoleCtrlHandler(consoleControlHandler, .FALSE);

    var app_bar = try app_bar_lib.AppBar.register(
        window,
        config.monitor,
        config.edge,
        config.thickness,
    );
    defer app_bar.cleanup();

    active_app_bar = &app_bar;
    defer active_app_bar = null;

    _ = ShowWindow(window, SW_SHOW);
    std.debug.print("AppBar is running. Press Ctrl+C to exit.\n", .{});
    try runMessageLoop();
}

const Config = struct {
    monitor: app_bar_lib.MonitorSelector,
    edge: app_bar_lib.Edge,
    thickness: u32,
};

fn parseArguments(args: std.process.Args) !Config {
    var iterator = try std.process.Args.Iterator.initAllocator(args, std.heap.page_allocator);
    defer iterator.deinit();
    _ = iterator.next();

    const monitor_index_text = iterator.next() orelse return usage();
    const edge_text = iterator.next() orelse return usage();
    const thickness_text = iterator.next() orelse return usage();
    if (iterator.next() != null) {
        return usage();
    }

    const monitor_index = std.fmt.parseInt(u32, monitor_index_text, 10) catch return usage();
    const thickness = std.fmt.parseInt(u32, thickness_text, 10) catch return usage();
    if (thickness == 0) {
        return usage();
    }

    return .{
        .monitor = .{ .index = monitor_index },
        .edge = parseEdge(edge_text) orelse return usage(),
        .thickness = thickness,
    };
}

fn parseEdge(text: []const u8) ?app_bar_lib.Edge {
    if (std.mem.eql(u8, text, "left")) return .left;
    if (std.mem.eql(u8, text, "top")) return .top;
    if (std.mem.eql(u8, text, "right")) return .right;
    if (std.mem.eql(u8, text, "bottom")) return .bottom;
    return null;
}

fn usage() Error {
    std.debug.print(
        "Usage: zig build run -- <monitor_index> <left|top|right|bottom> <thickness>\n",
        .{},
    );
    return error.InvalidArguments;
}

fn registerWindowClass(instance: windows.HINSTANCE) Error!void {
    const cursor = LoadCursorW(null, IDC_ARROW) orelse return error.CursorLoadFailed;
    const window_class = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .window_proc = windowProc,
        .class_extra = 0,
        .window_extra = 0,
        .instance = instance,
        .icon = null,
        .cursor = cursor,
        .background_brush = @ptrFromInt(COLOR_WINDOW + 1),
        .menu_name = null,
        .class_name = window_class_name.ptr,
        .small_icon = null,
    };
    if (RegisterClassExW(&window_class) == 0) {
        return error.WindowClassRegistrationFailed;
    }
}

fn windowProc(
    window: windows.HWND,
    message: windows.UINT,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    if (active_app_bar) |app_bar| {
        const consumed = app_bar.handleWindowMessage(message, wparam, lparam) catch {
            PostQuitMessage(1);
            return 0;
        };
        if (consumed) {
            return 0;
        }
    }

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

fn consoleControlHandler(_: windows.DWORD) callconv(.winapi) windows.BOOL {
    const window_address = app_window.load(.acquire);
    if (window_address == 0) {
        return .FALSE;
    }

    _ = PostMessageW(@ptrFromInt(window_address), WM_CLOSE, 0, 0);
    return .TRUE;
}

fn runMessageLoop() Error!void {
    var message: MSG = undefined;
    while (true) {
        const result = GetMessageW(&message, null, 0, 0);
        if (result == -1) {
            return error.MessageLoopFailed;
        }
        if (result == 0) {
            return;
        }

        _ = TranslateMessage(&message);
        _ = DispatchMessageW(&message);
    }
}

const window_class_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "windows_app_bar.basic.Window",
);
