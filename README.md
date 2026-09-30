# zig_windows_app_bar

A Windows-only Zig wrapper for the Win32 AppBar API.

## Requirements

- Zig 0.16.0
- A Windows target

The development environment is Windows 11. The library does not impose a minimum Windows version because the AppBar API has been available in Windows for a long time.

This project will provide a small, idiomatic interface for reserving an edge of a monitor for an application window. It is intended for applications such as docks, sidebars, and desktop panels that must cooperate with the Windows taskbar and other AppBars.

The public API registers an AppBar with `ABM_NEW`, reserves its position with `ABM_SETPOS`, moves the window with `SetWindowPos`, and removes the AppBar with `ABM_REMOVE`. It handles AppBar position-change notifications, `WM_WINDOWPOSCHANGED`, display-configuration changes, and DPI changes.

`MonitorTarget` selects a monitor by its zero-based `index` in `EnumDisplayMonitors` order or by its `id`. `AppBarConfig` combines a monitor target, edge, and thickness for registration. `enumerateMonitors(allocator)` returns `MonitorInfo` values in that order; free the returned slice with the same allocator. Monitor identifiers are owned, validated UTF-8 `MonitorId` values. Use an enumerated ID directly, or create one with `MonitorId.fromUtf8()` and read it with `utf8()`.

The requested thickness must be greater than zero and no larger than the selected monitor dimension along the AppBar edge. Each position query rebuilds its candidate from the selected monitor rectangle, edge, and thickness; the shell-approved rectangle is retained separately. When registration uses a monitor ID, `fallbackMonitorIndex()` returns the index of the monitor that ID resolved to; it is used as the fallback if that ID later disappears.

`window()`, `edge()`, `fallbackMonitorIndex()`, and `thickness()` expose the requested configuration. `candidateRect()` returns a fresh candidate rectangle, while `allocatedRect()` returns the shell-approved rectangle only while the AppBar is registered. `Rect` values use screen coordinates in physical pixels.

`setEdge()`, `setMonitor()`, `setFallbackMonitorIndex()`, and `setThickness()` immediately refresh the AppBar position. `setMonitor()` accepts the same `MonitorTarget` used during registration and resolves it strictly, returning `error.MonitorNotFound` when the target is unavailable. The resolved monitor ID is retained when available so later display changes continue to prefer the same physical monitor; its index is retained as a fallback. If applying a new setting fails, the library restores the previous setting and reservation; if that restoration fails, the setter returns `error.ConfigurationRollbackFailed`.

`status()` returns `Status.active`, `Status.suspended`, or `Status.deinitialized`. `isRegistered()` is true only while the AppBar is active and registered with the shell.

`show()` and `hide()` change only the AppBar window's visibility; hiding it retains its reserved screen area. `show()` does not activate the window. `isVisible()` reports the current window visibility.

`unregister()` removes the AppBar registration without destroying or hiding its window. It disables automatic re-registration caused by display changes or Explorer restart. `reregister()` enables automatic re-registration again and immediately registers the AppBar if it is currently unregistered. Calling `reregister()` after `deinit()` returns `error.AppBarDeinitialized`.

Call `refresh()` to explicitly re-query and reserve the current position after an application-level change. It also attempts to restore an AppBar that is temporarily suspended, except after a manual `unregister()`. Calling it after `deinit()` returns `error.AppBarDeinitialized`.

On `WM_DISPLAYCHANGE`, the library first tries to find the monitor previously selected by its device interface name. If it is absent, it falls back to the saved preferred monitor index, then to monitor index `0`. If no monitor is available, the AppBar is unregistered without destroying the window and is automatically retried on the next display change.

`thickness` is always a physical-pixel value. On `WM_DPICHANGED`, the library keeps that thickness and re-queries, reserves, and positions the AppBar for the selected monitor. It then leaves the message unconsumed so the application can update DPI-dependent resources such as fonts and child windows. The shell-approved AppBar placement takes precedence over the suggested rectangle in `lParam`. The application remains responsible for choosing its own DPI-awareness context; the library does not change process or thread DPI settings.

When the AppBar window is moved or resized, `WM_WINDOWPOSCHANGED` causes the library to refresh the selected monitor, edge, and thickness. Synchronous internal repositioning does not report another `ABM_WINDOWPOSCHANGED`; `ABN_POSCHANGED` always re-queries and refreshes the AppBar position.

Explorer restart recovery is implemented through the `TaskbarCreated` message. `WM_ACTIVATE` is forwarded to the shell through `ABM_ACTIVATE` without consuming the window message. `ABN_STATECHANGE` re-queries and reapplies the AppBar position so taskbar autohide setting changes do not depend solely on `ABN_POSCHANGED`; it does not expose the taskbar state. On every `ABN_FULLSCREENAPP` notification, the library re-queries the taskbar state and moves the AppBar to `HWND_TOPMOST` when the taskbar is always on top, or to `HWND_BOTTOM` otherwise. During `ABN_WINDOWARRANGE`, the library temporarily hides an AppBar that was visible before the operation and restores it without activation afterwards.

## Basic example

Run the interactive AppBar example with an initial monitor index, edge, and thickness in pixels:

```powershell
zig build example-basic -- 0 right 320
```

The edge must be `left`, `top`, `right`, or `bottom`. The example opens a separate control panel that can show or hide the AppBar, change its edge, monitor, and thickness, refresh it, unregister or reregister it, and deinitialize or register it again. The panel displays the current lifecycle, visibility, placement, and the most recent operation result. Press Ctrl+C in the terminal to remove the AppBar and exit the example.

The library uses Zig declarations for the small Win32 surface it needs. They are verified against the Windows SDK and link to `Shell32.lib`, `User32.lib`, and `Comctl32.lib`; consumers do not need to configure C header imports.

The intended usage is:

```zig
var app_bar = AppBarBinding{};
try app_bar.attach(hwnd, .{
    .monitor = .{ .index = monitor_index },
    .edge = .right,
    .thickness = thickness,
});
defer app_bar.detach();

try app_bar.setMonitor(.{ .index = other_monitor_index });
```

`AppBarBinding` installs a window subclass and processes AppBar messages without changes to the
window's existing window procedure. Messages that are not consumed by the AppBar are forwarded to
that procedure. The binding must remain at a stable memory address until `detach()` is called.
Call `attach()` and `detach()` from the thread that created the target window. When that window is
destroyed, the binding automatically removes its AppBar registration before forwarding
`WM_DESTROY` to the existing window procedure.
Call `lastError()` to retrieve an error raised while handling a window message.

`AppBar` remains public as a low-level API for applications that need to integrate AppBar handling
into their own window procedure. New applications should normally use `AppBarBinding`.
