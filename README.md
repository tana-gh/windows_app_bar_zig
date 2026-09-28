# zig_windows_app_bar

A Windows-only Zig wrapper for the Win32 AppBar API.

## Requirements

- Zig 0.16.0
- A Windows target

The development environment is Windows 11. The library does not impose a minimum Windows version because the AppBar API has been available in Windows for a long time.

This project will provide a small, idiomatic interface for reserving an edge of a monitor for an application window. It is intended for applications such as docks, sidebars, and desktop panels that must cooperate with the Windows taskbar and other AppBars.

The public API registers an AppBar with `ABM_NEW` and removes it with `ABM_REMOVE`. Window positioning and AppBar notification handling have not been implemented yet; those steps will add support for monitor, DPI, and taskbar changes.

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
