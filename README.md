# zig_windows_app_bar

A Windows-only Zig wrapper for the Win32 AppBar API.

## Requirements

- Zig 0.16.0
- A Windows target

The development environment is Windows 11. The library does not impose a minimum Windows version because the AppBar API has been available in Windows for a long time.

This project will provide a small, idiomatic interface for reserving an edge of a monitor for an application window. It is intended for applications such as docks, sidebars, and desktop panels that must cooperate with the Windows taskbar and other AppBars.

The public API registers an AppBar with `ABM_NEW`, reserves its position with `ABM_SETPOS`, moves the window with `SetWindowPos`, and removes the AppBar with `ABM_REMOVE`. It handles AppBar position-change notifications, `WM_WINDOWPOSCHANGED`, display-configuration changes, and DPI changes.

`monitor_index` is zero-based in the order reported by `EnumDisplayMonitors`. The requested thickness must be greater than zero and no larger than the selected monitor dimension along the AppBar edge. Each position query rebuilds its candidate from the selected monitor rectangle, edge, and thickness; the shell-approved rectangle is retained separately.

On `WM_DISPLAYCHANGE`, the library first tries to find the monitor previously selected by its device interface name. If it is absent, it falls back to the original `monitor_index`, then to monitor index `0`. If no monitor is available, the AppBar is unregistered without destroying the window and is automatically retried on the next display change.

`thickness` is always a physical-pixel value. On `WM_DPICHANGED`, the library keeps that thickness and re-queries, reserves, and positions the AppBar for the selected monitor. The application remains responsible for choosing its own DPI-awareness context; the library does not change process or thread DPI settings.

When the AppBar window is moved or resized, `WM_WINDOWPOSCHANGED` causes the library to reapply the selected monitor, edge, and thickness. Synchronous internal repositioning does not report another `ABM_WINDOWPOSCHANGED`; `ABN_POSCHANGED` always re-queries and reapplies the AppBar position.

Explorer restart recovery is implemented through the `TaskbarCreated` message. `WM_ACTIVATE` is forwarded to the shell through `ABM_ACTIVATE` without consuming the window message. `ABN_STATECHANGE` re-queries and reapplies the AppBar position so taskbar autohide setting changes do not depend solely on `ABN_POSCHANGED`; it does not expose the taskbar state. On `ABN_FULLSCREENAPP`, the AppBar moves to the bottom of the Z order while a fullscreen application is open and returns to the normal Z order when it closes. During `ABN_WINDOWARRANGE`, the library temporarily hides an AppBar that was visible before the operation and restores it without activation afterwards.

## Basic example

Run an empty AppBar window with a monitor index, edge, and thickness in pixels:

```powershell
zig build run -- 0 right 320
```

The edge must be `left`, `top`, `right`, or `bottom`. Press Ctrl+C in the terminal to remove the AppBar and exit the example.

The library uses Zig declarations for the small Win32 surface it needs. They are verified against the Windows SDK and link to `Shell32.lib` and `User32.lib`; consumers do not need to configure C header imports.

The intended usage is:

```zig
var app_bar = try AppBar.register(hwnd, monitor_index, .right, width);
defer app_bar.cleanup();

// In the window procedure:
const consumed = try app_bar.handleWindowMessage(message, wparam, lparam);
if (consumed) {
    return 0;
}
```
