const std = @import("std");

pub const WindowHandle = std.os.windows.HWND;
pub const Message = std.os.windows.UINT;
pub const WParam = usize;
pub const LParam = std.os.windows.LPARAM;

pub const Edge = enum(std.os.windows.UINT) {
    left = 0,
    top = 1,
    right = 2,
    bottom = 3,
};

/// A screen rectangle in physical pixels.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const max_monitor_id_utf16_units = 127;
pub const monitor_id_max_utf8_bytes = max_monitor_id_utf16_units * 3;

/// A UTF-8 Windows monitor device interface identifier.
pub const MonitorId = struct {
    bytes: [monitor_id_max_utf8_bytes]u8,
    length: u16,

    /// Creates a monitor identifier from a valid UTF-8 device interface identifier.
    pub fn fromUtf8(value: []const u8) Error!MonitorId {
        if (value.len == 0 or
            value.len > monitor_id_max_utf8_bytes or
            std.mem.indexOfScalar(u8, value, 0) != null or
            !std.unicode.utf8ValidateSlice(value))
        {
            return error.InvalidMonitorId;
        }

        var utf16_length: usize = 0;
        var codepoint_iterator = (std.unicode.Utf8View.init(value) catch return error.InvalidMonitorId).iterator();
        while (codepoint_iterator.nextCodepoint()) |codepoint| {
            utf16_length += std.unicode.utf16CodepointSequenceLength(codepoint) catch {
                return error.InvalidMonitorId;
            };
        }
        if (utf16_length > max_monitor_id_utf16_units) {
            return error.InvalidMonitorId;
        }

        var monitor_id = MonitorId{
            .bytes = undefined,
            .length = @intCast(value.len),
        };
        @memcpy(monitor_id.bytes[0..value.len], value);
        return monitor_id;
    }

    /// Returns the monitor device interface identifier as UTF-8.
    pub fn utf8(self: *const MonitorId) []const u8 {
        return self.bytes[0..self.length];
    }
};

/// Targets a monitor by its current index or persistent device interface identifier.
pub const MonitorTarget = union(enum) {
    index: u32,
    id: MonitorId,
};

/// Describes the requested AppBar placement.
pub const AppBarConfig = struct {
    monitor: MonitorTarget,
    edge: Edge,
    thickness: u32,
};

/// Information about one monitor in EnumDisplayMonitors order.
pub const MonitorInfo = struct {
    index: u32,
    id: ?MonitorId,
    rect: Rect,
};

/// The AppBar registration lifecycle state.
pub const Status = enum {
    active,
    suspended,
    deinitialized,
};

pub const Error = error{
    CallbackMessageRegistrationFailed,
    TaskbarCreatedMessageRegistrationFailed,
    AppBarRegistrationFailed,
    MonitorNotFound,
    InvalidMonitorId,
    InvalidThickness,
    InvalidPlacementRect,
    WindowPlacementFailed,
    WindowZOrderFailed,
    AppBarDeinitialized,
    ConfigurationRollbackFailed,
    WindowSubclassInstallationFailed,
    AppBarBindingAlreadyAttached,
    AppBarBindingNotAttached,
    AppBarWindowDestroyed,
};
