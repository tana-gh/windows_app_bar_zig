const std = @import("std");
const api = @import("api.zig");
const win32 = @import("win32.zig");

pub const Monitor = struct {
    index: u32,
    rect: win32.RECT,
    id: ?api.MonitorId,
};

const MonitorSearch = struct {
    target: api.MonitorSelector,
    next_index: u32 = 0,
    monitor: ?Monitor = null,
};

const MonitorEnumeration = struct {
    monitors: *std.array_list.Managed(api.MonitorInfo),
    next_index: u32 = 0,
    allocation_failed: bool = false,
};

/// Enumerates monitors in the zero-based order used by MonitorSelector.index.
/// The caller owns the returned slice and must free it with allocator.
pub fn enumerateMonitors(allocator: std.mem.Allocator) std.mem.Allocator.Error![]api.MonitorInfo {
    var monitors = std.array_list.Managed(api.MonitorInfo).init(allocator);
    errdefer monitors.deinit();

    var enumeration = MonitorEnumeration{ .monitors = &monitors };
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        enumerateMonitorCallback,
        @bitCast(@intFromPtr(&enumeration)),
    );
    if (enumeration.allocation_failed) {
        return error.OutOfMemory;
    }
    return monitors.toOwnedSlice();
}

pub fn resolveMonitorSelector(selector: api.MonitorSelector) ?Monitor {
    return switch (selector) {
        .index => |index| resolveMonitor(index, null),
        .id => |id| findMonitorById(id),
    };
}

pub fn resolveMonitor(preferred_index: u32, previous_id: ?api.MonitorId) ?Monitor {
    if (previous_id) |id| {
        if (findMonitorById(id)) |monitor| {
            return monitor;
        }
    }
    return findMonitorByIndex(preferred_index) orelse findMonitorByIndex(0);
}

pub fn rectFromWin32(rect: win32.RECT) api.Rect {
    return .{
        .left = rect.left,
        .top = rect.top,
        .right = rect.right,
        .bottom = rect.bottom,
    };
}

fn findMonitorById(id: api.MonitorId) ?Monitor {
    var search = MonitorSearch{ .target = .{ .id = id } };
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        findMonitorCallback,
        @bitCast(@intFromPtr(&search)),
    );
    return search.monitor;
}

fn findMonitorByIndex(index: u32) ?Monitor {
    var search = MonitorSearch{ .target = .{ .index = index } };
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        findMonitorCallback,
        @bitCast(@intFromPtr(&search)),
    );
    return search.monitor;
}

fn findMonitorCallback(
    monitor_handle: win32.HMONITOR,
    _: ?std.os.windows.HDC,
    monitor_rect: *win32.RECT,
    data: api.LParam,
) callconv(.winapi) std.os.windows.BOOL {
    const search: *MonitorSearch = @ptrFromInt(@as(usize, @bitCast(data)));
    if (search.next_index == std.math.maxInt(u32)) {
        return .FALSE;
    }
    const monitor = monitorFromHandle(monitor_handle, monitor_rect.*, search.next_index);
    search.next_index += 1;

    switch (search.target) {
        .index => |index| {
            if (monitor.index == index) {
                search.monitor = monitor;
                return .FALSE;
            }
        },
        .id => |id| {
            if (monitor.id) |monitor_id| {
                if (monitorIdsEqual(monitor_id, id)) {
                    search.monitor = monitor;
                    return .FALSE;
                }
            }
        },
    }
    return .TRUE;
}

fn enumerateMonitorCallback(
    monitor_handle: win32.HMONITOR,
    _: ?std.os.windows.HDC,
    monitor_rect: *win32.RECT,
    data: api.LParam,
) callconv(.winapi) std.os.windows.BOOL {
    const enumeration: *MonitorEnumeration = @ptrFromInt(@as(usize, @bitCast(data)));
    if (enumeration.next_index == std.math.maxInt(u32)) {
        return .FALSE;
    }
    const monitor = monitorFromHandle(monitor_handle, monitor_rect.*, enumeration.next_index);
    enumeration.next_index += 1;
    enumeration.monitors.append(.{
        .index = monitor.index,
        .id = monitor.id,
        .rect = rectFromWin32(monitor.rect),
    }) catch {
        enumeration.allocation_failed = true;
        return .FALSE;
    };
    return .TRUE;
}

fn monitorFromHandle(monitor_handle: win32.HMONITOR, rect: win32.RECT, index: u32) Monitor {
    return .{
        .index = index,
        .rect = rect,
        .id = getMonitorId(monitor_handle),
    };
}

fn getMonitorId(monitor: win32.HMONITOR) ?api.MonitorId {
    const windows = std.os.windows;
    var monitor_info = win32.MONITORINFOEXW{
        .cbSize = @sizeOf(win32.MONITORINFOEXW),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
        .szDevice = [_]windows.WCHAR{0} ** 32,
    };
    if (!win32.GetMonitorInfoW(monitor, &monitor_info).toBool()) {
        return null;
    }

    var display_device = win32.DISPLAY_DEVICEW{
        .cb = @sizeOf(win32.DISPLAY_DEVICEW),
        .DeviceName = [_]windows.WCHAR{0} ** 32,
        .DeviceString = [_]windows.WCHAR{0} ** 128,
        .StateFlags = 0,
        .DeviceID = [_]windows.WCHAR{0} ** 128,
        .DeviceKey = [_]windows.WCHAR{0} ** 128,
    };
    if (!win32.EnumDisplayDevicesW(
        @ptrCast(&monitor_info.szDevice),
        0,
        &display_device,
        win32.EDD_GET_DEVICE_INTERFACE_NAME,
    ).toBool()) {
        return null;
    }
    return monitorIdFromUtf16(&display_device.DeviceID);
}

fn monitorIdFromUtf16(utf16: []const std.os.windows.WCHAR) ?api.MonitorId {
    const length = std.mem.indexOfScalar(std.os.windows.WCHAR, utf16, 0) orelse utf16.len;
    if (length == 0) {
        return null;
    }

    var bytes: [api.monitor_id_max_utf8_bytes]u8 = undefined;
    const utf8_length = std.unicode.utf16LeToUtf8(bytes[0..], utf16[0..length]) catch return null;
    return .{
        .bytes = bytes,
        .length = @intCast(utf8_length),
    };
}

fn monitorIdsEqual(first: api.MonitorId, second: api.MonitorId) bool {
    return std.mem.eql(u8, first.utf8(), second.utf8());
}

fn selectMonitorFromSlice(
    monitors: []const Monitor,
    preferred_index: u32,
    previous_id: ?api.MonitorId,
) ?Monitor {
    if (previous_id) |id| {
        for (monitors) |monitor| {
            if (monitor.id) |monitor_id| {
                if (monitorIdsEqual(monitor_id, id)) {
                    return monitor;
                }
            }
        }
    }
    if (preferred_index < monitors.len) {
        return monitors[preferred_index];
    }
    if (monitors.len != 0) {
        return monitors[0];
    }
    return null;
}

test "monitor selection prioritizes identity before index fallbacks" {
    const first_id = try api.MonitorId.fromUtf8("first");
    const second_id = try api.MonitorId.fromUtf8("second");
    const monitors = [_]Monitor{
        .{ .index = 0, .rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 }, .id = first_id },
        .{ .index = 1, .rect = .{ .left = 100, .top = 0, .right = 200, .bottom = 100 }, .id = second_id },
    };

    const identity_match = selectMonitorFromSlice(&monitors, 0, second_id).?;
    try std.testing.expectEqual(@as(i32, 100), identity_match.rect.left);
    try std.testing.expectEqual(@as(u32, 1), identity_match.index);

    const preferred_index_match = selectMonitorFromSlice(&monitors, 1, null).?;
    try std.testing.expectEqual(@as(i32, 100), preferred_index_match.rect.left);

    const zero_index_fallback = selectMonitorFromSlice(&monitors, 9, null).?;
    try std.testing.expectEqual(@as(i32, 0), zero_index_fallback.rect.left);

    try std.testing.expect(selectMonitorFromSlice(&.{}, 0, null) == null);
}
