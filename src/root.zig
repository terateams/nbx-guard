//! Library root: re-exports the guard modules and aggregates unit tests.
pub const context = @import("context.zig");
pub const config = @import("config.zig");
pub const store = @import("store.zig");
pub const ids = @import("ids.zig");
pub const policy = @import("policy.zig");
pub const plan = @import("plan.zig");
pub const approval = @import("approval.zig");
pub const backup = @import("backup.zig");
pub const audit = @import("audit.zig");
pub const netbox = @import("netbox.zig");
pub const cli = @import("cli.zig");

test {
    _ = @import("ids.zig");
    _ = @import("config.zig");
    _ = @import("store.zig");
    _ = @import("context.zig");
    _ = @import("policy.zig");
    _ = @import("plan.zig");
    _ = @import("approval.zig");
    _ = @import("backup.zig");
    _ = @import("audit.zig");
    _ = @import("netbox.zig");
    _ = @import("cli.zig");
}
