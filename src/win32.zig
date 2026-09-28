const std = @import("std");
const windows = std.os.windows;

pub const RECT = extern struct {
    left: windows.LONG,
    top: windows.LONG,
    right: windows.LONG,
    bottom: windows.LONG,
};

pub const HMONITOR = *opaque {};
pub const MONITORENUMPROC = *const fn (
    monitor: HMONITOR,
    hdc: ?std.os.windows.HDC,
    monitor_rect: *RECT,
    data: windows.LPARAM,
) callconv(.winapi) windows.BOOL;

pub const APPBARDATA = extern struct {
    cbSize: windows.DWORD,
    hWnd: windows.HWND,
    uCallbackMessage: windows.UINT,
    uEdge: windows.UINT,
    rc: RECT,
    lParam: windows.LPARAM,
};

pub const MONITORINFOEXW = extern struct {
    cbSize: windows.DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: windows.DWORD,
    szDevice: [32]windows.WCHAR,
};

pub const DISPLAY_DEVICEW = extern struct {
    cb: windows.DWORD,
    DeviceName: [32]windows.WCHAR,
    DeviceString: [128]windows.WCHAR,
    StateFlags: windows.DWORD,
    DeviceID: [128]windows.WCHAR,
    DeviceKey: [128]windows.WCHAR,
};

pub const ABM_NEW: windows.DWORD = 0x00000000;
pub const ABM_REMOVE: windows.DWORD = 0x00000001;
pub const ABM_QUERYPOS: windows.DWORD = 0x00000002;
pub const ABM_SETPOS: windows.DWORD = 0x00000003;
pub const ABM_ACTIVATE: windows.DWORD = 0x00000006;
pub const ABM_WINDOWPOSCHANGED: windows.DWORD = 0x00000009;

pub const ABN_STATECHANGE: usize = 0x00000000;
pub const ABN_POSCHANGED: usize = 0x00000001;
pub const ABN_FULLSCREENAPP: usize = 0x00000002;
pub const ABN_WINDOWARRANGE: usize = 0x00000003;

pub const ABE_LEFT: windows.UINT = 0;
pub const ABE_TOP: windows.UINT = 1;
pub const ABE_RIGHT: windows.UINT = 2;
pub const ABE_BOTTOM: windows.UINT = 3;

pub const SWP_NOZORDER: windows.UINT = 0x0004;
pub const SWP_NOACTIVATE: windows.UINT = 0x0010;
pub const SWP_NOSIZE: windows.UINT = 0x0001;
pub const SWP_NOMOVE: windows.UINT = 0x0002;

pub const SW_HIDE: i32 = 0;
pub const SW_SHOWNOACTIVATE: i32 = 4;

pub const HWND_BOTTOM: windows.HWND = @ptrFromInt(1);

pub const WA_INACTIVE: usize = 0;

pub const WM_ACTIVATE: windows.UINT = 0x0006;
pub const WM_WINDOWPOSCHANGED: windows.UINT = 0x0047;
pub const WM_DISPLAYCHANGE: windows.UINT = 0x007E;
pub const WM_DPICHANGED: windows.UINT = 0x02E0;

pub const EDD_GET_DEVICE_INTERFACE_NAME: windows.DWORD = 0x00000001;

pub extern "shell32" fn SHAppBarMessage(
    message: windows.DWORD,
    app_bar_data: *APPBARDATA,
) callconv(.winapi) usize;

pub extern "user32" fn RegisterWindowMessageW(
    message: windows.LPCWSTR,
) callconv(.winapi) windows.UINT;

pub extern "user32" fn EnumDisplayMonitors(
    hdc: ?windows.HDC,
    clip_rect: ?*const RECT,
    callback: MONITORENUMPROC,
    data: windows.LPARAM,
) callconv(.winapi) windows.BOOL;

pub extern "user32" fn GetMonitorInfoW(
    monitor: HMONITOR,
    monitor_info: *MONITORINFOEXW,
) callconv(.winapi) windows.BOOL;

pub extern "user32" fn EnumDisplayDevicesW(
    device_name: windows.LPCWSTR,
    device_number: windows.DWORD,
    display_device: *DISPLAY_DEVICEW,
    flags: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "user32" fn SetWindowPos(
    window: windows.HWND,
    insert_after: ?windows.HWND,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    flags: windows.UINT,
) callconv(.winapi) windows.BOOL;

pub extern "user32" fn IsWindowVisible(
    window: windows.HWND,
) callconv(.winapi) windows.BOOL;

pub extern "user32" fn ShowWindow(
    window: windows.HWND,
    command: i32,
) callconv(.winapi) windows.BOOL;

test "APPBARDATA ABI matches the Windows SDK" {
    const expected_pointer_offset = @sizeOf(usize);
    const expected_size = switch (@sizeOf(usize)) {
        4 => 36,
        8 => 48,
        else => @compileError("unsupported pointer size"),
    };

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(APPBARDATA, "cbSize"));
    try std.testing.expectEqual(expected_pointer_offset, @offsetOf(APPBARDATA, "hWnd"));
    try std.testing.expectEqual(expected_pointer_offset * 2, @offsetOf(APPBARDATA, "uCallbackMessage"));
    try std.testing.expectEqual(expected_pointer_offset * 2 + 4, @offsetOf(APPBARDATA, "uEdge"));
    try std.testing.expectEqual(expected_pointer_offset * 2 + 8, @offsetOf(APPBARDATA, "rc"));
    try std.testing.expectEqual(expected_pointer_offset * 2 + 24, @offsetOf(APPBARDATA, "lParam"));
    try std.testing.expectEqual(expected_size, @sizeOf(APPBARDATA));
}

test "monitor structures match the Windows SDK" {
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(MONITORINFOEXW));
    try std.testing.expectEqual(@as(usize, 840), @sizeOf(DISPLAY_DEVICEW));
}
