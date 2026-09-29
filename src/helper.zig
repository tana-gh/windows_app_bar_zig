const std = @import("std");
const api = @import("api.zig");
const monitor = @import("monitor.zig");

/// Enumerates monitors in the zero-based order used by MonitorSelector.index.
/// The caller owns the returned slice and must free it with allocator.
pub fn enumerateMonitors(allocator: std.mem.Allocator) std.mem.Allocator.Error![]api.MonitorInfo {
    return monitor.enumerateMonitors(allocator);
}
