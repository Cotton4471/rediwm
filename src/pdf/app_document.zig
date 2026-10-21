//! PDF viewer document state: opening, passwords, worker sync and render jobs.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const document = @import("document.zig");
const layout = @import("layout.zig");
const cache = @import("cache.zig");
const worker = @import("worker.zig");
const a = @import("app.zig").a;
const Rect = @import("app.zig").Rect;
const tileClip = @import("app.zig").tileClip;

pub fn clearOutline(self: *App) void {
    if (self.outline) |items| {
        for (items) |it| it.deinit(a);
        a.free(items);
        self.outline = null;
    }
}

pub fn clearPageContents(self: *App) void {
    var it = self.page_contents.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    self.page_contents.clearRetainingCapacity();
}

pub fn openDocument(self: *App, password: ?[:0]const u8) !void {
    self.error_message = null;
    self.generation += 1;
    self.loading = true;

    if (self.doc_layout) |l| {
        l.deinit();
        self.doc_layout = null;
    }
    if (self.sidebar_layout) |s| {
        s.deinit();
        self.sidebar_layout = null;
    }
    self.page_sizes.clearRetainingCapacity();
    self.page_cache.clearGeneration(self.generation);
    self.thumb_cache.clearGeneration(self.generation);
    self.clearOutline();
    self.clearPageContents();
    self.clearSelectionText();
    self.selection_page = null;
    self.selection_range = null;
    self.selection_active = false;
    self.selection_dragging = false;
    self.search_matches.clearRetainingCapacity();

    self.current_page = 0;
    self.scroll_y = 0.0;
    self.anchor = .{ .page_index = 0, .rel_y = 0.0 };
    self.dialog = .none;
    self.focus = .none;

    try self.worker.requestOpen(password, self.generation);
    self.updateTitle();
    self.dirty = true;
}

pub fn submitPassword(self: *App) void {
    const len = self.password_input.len;
    self.password_buf[len] = 0;
    // requestOpen makes its own locked copy before this storage is wiped.
    self.openDocument(self.password_buf[0..len :0]) catch {
        self.loading = false;
        self.dialog = .password;
        self.focus = .password;
        self.error_message = tr("Could not prepare password. Please try again.");
    };
    self.password_input.clear();
    self.dirty = true;
}

pub fn sync(self: *App) void {
    var received_any = false;
    while (self.worker.takeResult()) |res| {
        var mut_res = res;
        defer mut_res.deinit();

        if (mut_res.generation != self.generation) continue;
        received_any = true;

        switch (mut_res.payload) {
            .open_done => |od| {
                self.loading = false;
                self.n_pages = od.page_count;
                self.dialog = .none;
                self.focus = .none;

                self.page_sizes.clearRetainingCapacity();
                self.page_sizes.ensureTotalCapacity(a, self.n_pages) catch {
                    self.n_pages = 0;
                    self.error_message = tr("Not enough memory to open this document.");
                    self.dirty = true;
                    continue;
                };

                // Initial estimate from page 0
                self.page_sizes.appendAssumeCapacity(od.first_page_size);
                for (1..self.n_pages) |_| {
                    self.page_sizes.appendAssumeCapacity(od.first_page_size);
                }

                // Store outline
                self.clearOutline();
                self.outline = od.outline;
                mut_res.payload.open_done.outline = null;

                self.updateEffectiveZoom();
                self.recomputeLayout() catch {};
                self.updateTitle();
                self.dirty = true;
            },

            .open_failed => |of| {
                self.loading = false;
                if (of.err == error.Encrypted) {
                    self.dialog = .password;
                    self.focus = .password;
                    self.password_input.clear();
                    self.error_message = tr("Document is encrypted. Enter password:");
                } else if (of.err == error.FileNotFound) {
                    self.error_message = tr("File not found.");
                } else if (of.err == error.InvalidPdf) {
                    self.error_message = tr("Invalid or corrupt PDF document.");
                } else {
                    self.error_message = tr("Could not open document.");
                }
                self.dirty = true;
            },

            .page_sizes_batch => |b| {
                for (b.sizes, 0..) |sz, idx| {
                    const p_idx = b.start + idx;
                    if (p_idx < self.page_sizes.items.len) {
                        self.page_sizes.items[p_idx] = sz;
                    }
                }
                // Open fitted to the first page's size; refit to the real ones.
                if (self.zoom_mode != .manual) self.updateEffectiveZoom();
                self.relayout();
            },

            .page_rendered => |*pr| {
                const key = cache.PageKey.init(
                    self.generation,
                    pr.page_index,
                    pr.scale,
                    pr.rotation,
                    if (pr.clip) |c_val| .{
                        .x = @intFromFloat(c_val.x),
                        .y = @intFromFloat(c_val.y),
                        .w = @intFromFloat(c_val.w),
                        .h = @intFromFloat(c_val.h),
                    } else null,
                );
                self.page_cache.put(.{
                    .key = key,
                    .pixels = pr.rendered.pixels,
                    .width = pr.rendered.width,
                    .height = pr.rendered.height,
                    .stride = pr.rendered.stride,
                    .bytes = @intCast(pr.rendered.stride * pr.rendered.height),
                    .last_used = 0,
                    .allocator = pr.rendered.allocator,
                }) catch {};
                pr.rendered.pixels = &[_]u32{};
                self.dirty = true;
            },

            .thumb_rendered => |*thumb| {
                const key = cache.ThumbKey{
                    .generation = self.generation,
                    .page_index = thumb.page_index,
                    .rotation = thumb.rotation,
                    .card_w = thumb.card_w,
                    .card_h = thumb.card_h,
                };
                self.thumb_cache.put(.{
                    .key = key,
                    .pixels = thumb.rendered.pixels,
                    .width = thumb.rendered.width,
                    .height = thumb.rendered.height,
                    .stride = thumb.rendered.stride,
                    .bytes = @intCast(thumb.rendered.stride * thumb.rendered.height),
                    .last_used = 0,
                    .allocator = thumb.rendered.allocator,
                }) catch {};
                thumb.rendered.pixels = &[_]u32{};
                self.dirty = true;
            },

            .content_extracted => |*ce| {
                var entry = self.page_contents.getOrPut(ce.page_index) catch continue;
                if (entry.found_existing) entry.value_ptr.deinit();
                entry.value_ptr.* = .{
                    .page_index = ce.page_index,
                    .text = ce.text,
                    .text_rects = ce.text_rects,
                    .links = ce.links,
                };
                ce.text = null;
                ce.text_rects = &[_]layout.Rect{};
                if (self.selection_page == ce.page_index) self.updateSelection();
                ce.links = &[_]document.Link{};
                self.dirty = true;
            },

            .search_matches => |*sm| {
                for (sm.rects) |r| {
                    self.search_matches.append(a, .{ .page_index = sm.page_index, .rect = r }) catch {};
                }
                if (self.search_matches.items.len > 0 and self.search_match_idx == 0) {
                    self.scrollToMatch(0);
                }
                self.dirty = true;
            },

            else => {},
        }
    }

    self.queueRenderJobs();
}

pub fn queueRenderJobs(self: *App) void {
    const dl = self.doc_layout orelse return;
    const cv = self.canvasRect();
    const vis = layout.findVisiblePages(dl.pages, self.scroll_y, cv.h);
    const vis_range = vis orelse return;

    var jobs: [64]worker.Job = undefined;
    var count: usize = 0;

    const effective_scale = self.zoom * @as(f64, @floatFromInt(self.scale));

    // 1. Visible page render jobs (priority 0)
    for (vis_range.start_index..vis_range.end_index + 1) |i| {
        if (count >= jobs.len) break;
        const p = dl.pages[i];

        // Large pages: only the tiles in view.
        if (self.tileSpan(cv, p)) |span| {
            for (span.y0..span.y1) |ty| for (span.x0..span.x1) |tx| {
                if (count >= jobs.len) break;
                const tk = span.key(tx, ty);
                const pk = cache.PageKey.init(self.generation, i, effective_scale, self.rotation, tk);
                if (self.page_cache.get(pk) == null) {
                    jobs[count] = .{
                        .kind = .render_page,
                        .priority = 0,
                        .generation = self.generation,
                        .page_index = i,
                        .scale = effective_scale,
                        .rotation = self.rotation,
                        .clip = tileClip(tk),
                    };
                    count += 1;
                }
            };
        } else {
            const pk = cache.PageKey.init(self.generation, i, effective_scale, self.rotation, null);
            if (self.page_cache.get(pk) == null) {
                jobs[count] = .{
                    .kind = .render_page,
                    .priority = 0,
                    .generation = self.generation,
                    .page_index = i,
                    .scale = effective_scale,
                    .rotation = self.rotation,
                    .clip = null,
                };
                count += 1;
            }
        }

        // Also request content for links / selection if not cached
        if (!self.page_contents.contains(i)) {
            self.worker.requestContent(i, self.generation);
        }
    }

    // 2. Visible thumbnail jobs (priority 1)
    if (self.sidebar_open and self.sidebar_tab == .pages and self.sidebar_layout != null) {
        const sb = self.sidebarRect();
        const sbl = self.sidebar_layout.?;
        const vis_sb = layout.findVisibleSidebarCards(sbl.cards, self.sidebar_scroll_y, sb.h);
        if (vis_sb) |vsb| {
            const card_w = self.sidebar_w - 32.0;
            for (vsb.start_index..vsb.end_index + 1) |i| {
                if (count >= jobs.len) break;
                const card = sbl.cards[i];
                const tk = cache.ThumbKey{
                    .generation = self.generation,
                    .page_index = i,
                    .rotation = self.rotation,
                    .card_w = @intFromFloat(card_w),
                    .card_h = @intFromFloat(card.card_h),
                };
                if (self.thumb_cache.get(tk) == null) {
                    const rsz = layout.rotatedPageSize(self.page_sizes.items[i], self.rotation);
                    const base_w = rsz.width * layout.PTS_TO_LOGICAL;
                    const thumb_scale = (card_w / base_w) * @as(f64, @floatFromInt(self.scale));
                    jobs[count] = .{
                        .kind = .render_thumb,
                        .priority = 1,
                        .generation = self.generation,
                        .page_index = i,
                        .scale = thumb_scale,
                        .rotation = self.rotation,
                        .card_w = card_w,
                        .card_h = card.card_h,
                    };
                    count += 1;
                }
            }
        }
    }

    // 3. Nearby prefetch page (priority 2), unless it would be tiled: a
    // whole raster of it would be large, and drawn tiles replace it.
    if (vis_range.start_index > 0 and count < jobs.len and !self.isTiled(dl.pages[vis_range.start_index - 1])) {
        const prev = vis_range.start_index - 1;
        const pk = cache.PageKey.init(self.generation, prev, effective_scale, self.rotation, null);
        if (self.page_cache.get(pk) == null) {
            jobs[count] = .{
                .kind = .render_page,
                .priority = 2,
                .generation = self.generation,
                .page_index = prev,
                .scale = effective_scale,
                .rotation = self.rotation,
            };
            count += 1;
        }
    }
    if (vis_range.end_index + 1 < dl.pages.len and count < jobs.len and !self.isTiled(dl.pages[vis_range.end_index + 1])) {
        const next = vis_range.end_index + 1;
        const pk = cache.PageKey.init(self.generation, next, effective_scale, self.rotation, null);
        if (self.page_cache.get(pk) == null) {
            jobs[count] = .{
                .kind = .render_page,
                .priority = 2,
                .generation = self.generation,
                .page_index = next,
                .scale = effective_scale,
                .rotation = self.rotation,
            };
            count += 1;
        }
    }

    if (count > 0) {
        self.worker.setRenderJobs(jobs[0..count], self.generation);
    }
}
