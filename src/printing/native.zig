pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/eventfd.h");
    @cInclude("linux/netlink.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("pthread.h");
    @cInclude("time.h");
    @cInclude("pwd.h");
});
