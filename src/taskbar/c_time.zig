//! The C time and locale declarations the taskbar clock shares across its files.

pub const c = @cImport({
    @cInclude("locale.h");
    @cInclude("time.h");
});
