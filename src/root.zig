const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows_app_bar supports Windows targets only");
    }
}
