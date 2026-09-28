const std = @import("std");
const windows = std.os.windows;

pub const RECT = extern struct {
    left: windows.LONG,
    top: windows.LONG,
    right: windows.LONG,
    bottom: windows.LONG,
};

pub const APPBARDATA = extern struct {
    cbSize: windows.DWORD,
    hWnd: windows.HWND,
    uCallbackMessage: windows.UINT,
    uEdge: windows.UINT,
    rc: RECT,
    lParam: windows.LPARAM,
};

pub const ABM_NEW: windows.DWORD = 0x00000000;
pub const ABM_REMOVE: windows.DWORD = 0x00000001;
pub const ABM_QUERYPOS: windows.DWORD = 0x00000002;
pub const ABM_SETPOS: windows.DWORD = 0x00000003;
pub const ABM_WINDOWPOSCHANGED: windows.DWORD = 0x00000009;

pub const ABE_LEFT: windows.UINT = 0;
pub const ABE_TOP: windows.UINT = 1;
pub const ABE_RIGHT: windows.UINT = 2;
pub const ABE_BOTTOM: windows.UINT = 3;

pub extern "shell32" fn SHAppBarMessage(
    message: windows.DWORD,
    app_bar_data: *APPBARDATA,
) callconv(.winapi) usize;

pub extern "user32" fn RegisterWindowMessageW(
    message: windows.LPCWSTR,
) callconv(.winapi) windows.UINT;

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
