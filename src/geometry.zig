const std = @import("std");
const api = @import("api.zig");
const win32 = @import("win32.zig");

pub const WindowPosition = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub fn makeProposedRect(
    monitor_rect: win32.RECT,
    edge: api.Edge,
    thickness: u32,
) api.Error!win32.RECT {
    const thickness_i32 = try validateThickness(monitor_rect, edge, thickness);
    var proposed_rect = monitor_rect;

    switch (edge) {
        .left => proposed_rect.right = proposed_rect.left + thickness_i32,
        .top => proposed_rect.bottom = proposed_rect.top + thickness_i32,
        .right => proposed_rect.left = proposed_rect.right - thickness_i32,
        .bottom => proposed_rect.top = proposed_rect.bottom - thickness_i32,
    }
    return proposed_rect;
}

pub fn preserveThickness(rect: win32.RECT, edge: api.Edge, thickness: u32) win32.RECT {
    const thickness_i32: i32 = @intCast(thickness);
    var adjusted_rect = rect;

    switch (edge) {
        .left => adjusted_rect.right = adjusted_rect.left + thickness_i32,
        .top => adjusted_rect.bottom = adjusted_rect.top + thickness_i32,
        .right => adjusted_rect.left = adjusted_rect.right - thickness_i32,
        .bottom => adjusted_rect.top = adjusted_rect.bottom - thickness_i32,
    }
    return adjusted_rect;
}

pub fn validateThickness(
    monitor_rect: win32.RECT,
    edge: api.Edge,
    thickness: u32,
) api.Error!i32 {
    if (thickness == 0 or thickness > std.math.maxInt(i32)) {
        return error.InvalidThickness;
    }

    const dimension: i64 = switch (edge) {
        .left, .right => @as(i64, monitor_rect.right) - @as(i64, monitor_rect.left),
        .top, .bottom => @as(i64, monitor_rect.bottom) - @as(i64, monitor_rect.top),
    };
    if (dimension <= 0 or @as(i64, thickness) > dimension) {
        return error.InvalidThickness;
    }
    return @intCast(thickness);
}

pub fn windowPositionFromRect(rect: win32.RECT) api.Error!WindowPosition {
    const width: i64 = @as(i64, rect.right) - @as(i64, rect.left);
    const height: i64 = @as(i64, rect.bottom) - @as(i64, rect.top);
    if (width <= 0 or width > std.math.maxInt(i32) or height <= 0 or height > std.math.maxInt(i32)) {
        return error.InvalidPlacementRect;
    }

    return .{
        .x = rect.left,
        .y = rect.top,
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

test "proposed rectangles preserve the requested thickness on every edge" {
    const monitor_rect = win32.RECT{
        .left = -100,
        .top = 50,
        .right = 900,
        .bottom = 650,
    };

    const left = try makeProposedRect(monitor_rect, .left, 100);
    try std.testing.expectEqual(@as(i32, 0), left.right);

    const top = try makeProposedRect(monitor_rect, .top, 100);
    try std.testing.expectEqual(@as(i32, 150), top.bottom);

    const right = try makeProposedRect(monitor_rect, .right, 100);
    try std.testing.expectEqual(@as(i32, 800), right.left);

    const bottom = try makeProposedRect(monitor_rect, .bottom, 100);
    try std.testing.expectEqual(@as(i32, 550), bottom.top);
}

test "position queries rebuild candidates from the monitor edge" {
    const monitor_rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = 1000,
        .bottom = 1000,
    };
    const previous_approved_rect = win32.RECT{
        .left = 0,
        .top = 860,
        .right = 1000,
        .bottom = 960,
    };

    const candidate = try makeProposedRect(monitor_rect, .bottom, 100);
    try std.testing.expect(candidate.top != previous_approved_rect.top);
    try std.testing.expectEqual(@as(i32, 900), candidate.top);
    try std.testing.expectEqual(@as(i32, 1000), candidate.bottom);
}

test "thickness must fit the selected monitor edge" {
    const monitor_rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = 100,
        .bottom = 50,
    };

    try std.testing.expectError(error.InvalidThickness, makeProposedRect(monitor_rect, .left, 0));
    try std.testing.expectError(error.InvalidThickness, makeProposedRect(monitor_rect, .right, 101));
    try std.testing.expectError(error.InvalidThickness, makeProposedRect(monitor_rect, .bottom, 51));
}

test "window placement preserves screen coordinates and dimensions" {
    const position = try windowPositionFromRect(.{
        .left = -300,
        .top = 50,
        .right = 100,
        .bottom = 250,
    });

    try std.testing.expectEqual(@as(i32, -300), position.x);
    try std.testing.expectEqual(@as(i32, 50), position.y);
    try std.testing.expectEqual(@as(i32, 400), position.width);
    try std.testing.expectEqual(@as(i32, 200), position.height);
}

test "window placement rejects empty rectangles" {
    try std.testing.expectError(error.InvalidPlacementRect, windowPositionFromRect(.{
        .left = 100,
        .top = 0,
        .right = 100,
        .bottom = 100,
    }));
}
