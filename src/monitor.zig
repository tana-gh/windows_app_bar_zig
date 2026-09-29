const std = @import("std");
const api = @import("api.zig");
const win32 = @import("win32.zig");

pub const Monitor = struct {
    index: u32,
    rect: win32.RECT,
    id: ?api.MonitorId,
};

const MonitorResolution = struct {
    preferred_index: ?u32,
    previous_id: ?api.MonitorId,
    falls_back_to_first: bool,
    next_index: u32 = 0,
    first_monitor: ?Monitor = null,
    preferred_monitor: ?Monitor = null,
    identified_monitor: ?Monitor = null,
};

const MonitorEnumeration = struct {
    monitors: *std.array_list.Managed(api.MonitorInfo),
    next_index: u32 = 0,
    allocation_failed: bool = false,
};

/// Enumerates monitors in the zero-based order used by MonitorTarget.index.
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

pub fn resolveMonitorTarget(target: api.MonitorTarget) ?Monitor {
    return switch (target) {
        .index => |index| findMonitor(index, null, true),
        .id => |id| findMonitor(null, id, false),
    };
}

pub fn resolveMonitor(preferred_index: u32, previous_id: ?api.MonitorId) ?Monitor {
    return findMonitor(preferred_index, previous_id, true);
}

pub fn rectFromWin32(rect: win32.RECT) api.Rect {
    return .{
        .left = rect.left,
        .top = rect.top,
        .right = rect.right,
        .bottom = rect.bottom,
    };
}

fn findMonitor(
    preferred_index: ?u32,
    previous_id: ?api.MonitorId,
    falls_back_to_first: bool,
) ?Monitor {
    var resolution = MonitorResolution{
        .preferred_index = preferred_index,
        .previous_id = previous_id,
        .falls_back_to_first = falls_back_to_first,
    };
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        findMonitorCallback,
        @bitCast(@intFromPtr(&resolution)),
    );
    return selectMonitor(
        resolution.identified_monitor,
        resolution.preferred_monitor,
        if (resolution.falls_back_to_first) resolution.first_monitor else null,
    );
}

fn findMonitorCallback(
    monitor_handle: win32.HMONITOR,
    _: ?std.os.windows.HDC,
    monitor_rect: *win32.RECT,
    data: api.LParam,
) callconv(.winapi) std.os.windows.BOOL {
    const resolution: *MonitorResolution = @ptrFromInt(@as(usize, @bitCast(data)));
    if (resolution.next_index == std.math.maxInt(u32)) {
        return .FALSE;
    }
    const index = resolution.next_index;
    resolution.next_index += 1;
    const current_monitor = monitorFromHandle(
        monitor_handle,
        monitor_rect.*,
        index,
        shouldLoadMonitorId(resolution, index),
    );

    if (resolution.first_monitor == null) {
        resolution.first_monitor = current_monitor;
    }
    if (resolution.preferred_index) |preferred_index| {
        if (index == preferred_index) {
            resolution.preferred_monitor = current_monitor;
            if (resolution.previous_id == null) return .FALSE;
        }
    }
    if (resolution.previous_id) |previous_id| {
        if (current_monitor.id) |monitor_id| {
            if (monitorIdsEqual(monitor_id, previous_id)) {
                resolution.identified_monitor = current_monitor;
                return .FALSE;
            }
        }
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
    const monitor = monitorFromHandle(monitor_handle, monitor_rect.*, enumeration.next_index, true);
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

fn shouldLoadMonitorId(resolution: *const MonitorResolution, index: u32) bool {
    if (resolution.previous_id != null or resolution.first_monitor == null) {
        return true;
    }
    return if (resolution.preferred_index) |preferred_index| index == preferred_index else false;
}

fn monitorFromHandle(
    monitor_handle: win32.HMONITOR,
    rect: win32.RECT,
    index: u32,
    load_id: bool,
) Monitor {
    return .{
        .index = index,
        .rect = rect,
        .id = if (load_id) getMonitorId(monitor_handle) else null,
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

fn selectMonitor(
    identified_monitor: ?Monitor,
    preferred_monitor: ?Monitor,
    first_monitor: ?Monitor,
) ?Monitor {
    return identified_monitor orelse preferred_monitor orelse first_monitor;
}

test "monitor selection prioritizes identity before index fallbacks" {
    const first_id = try api.MonitorId.fromUtf8("first");
    const second_id = try api.MonitorId.fromUtf8("second");
    const first_monitor = Monitor{
        .index = 0,
        .rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .id = first_id,
    };
    const preferred_monitor = Monitor{
        .index = 1,
        .rect = .{ .left = 100, .top = 0, .right = 200, .bottom = 100 },
        .id = second_id,
    };

    const identity_match = selectMonitor(preferred_monitor, first_monitor, null).?;
    try std.testing.expectEqual(@as(i32, 100), identity_match.rect.left);
    try std.testing.expectEqual(@as(u32, 1), identity_match.index);

    const preferred_index_match = selectMonitor(null, preferred_monitor, first_monitor).?;
    try std.testing.expectEqual(@as(i32, 100), preferred_index_match.rect.left);

    const zero_index_fallback = selectMonitor(null, null, first_monitor).?;
    try std.testing.expectEqual(@as(i32, 0), zero_index_fallback.rect.left);

    try std.testing.expect(selectMonitor(null, null, null) == null);
}

test "index resolution loads monitor IDs only for retained candidates" {
    var resolution = MonitorResolution{
        .preferred_index = 2,
        .previous_id = null,
        .falls_back_to_first = true,
    };
    try std.testing.expect(shouldLoadMonitorId(&resolution, 0));
    resolution.first_monitor = .{
        .index = 0,
        .rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .id = null,
    };
    try std.testing.expect(!shouldLoadMonitorId(&resolution, 1));
    try std.testing.expect(shouldLoadMonitorId(&resolution, 2));
    resolution.previous_id = try api.MonitorId.fromUtf8("previous");
    try std.testing.expect(shouldLoadMonitorId(&resolution, 3));
}
