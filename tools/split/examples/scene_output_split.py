#!/usr/bin/env python3
"""How src/scene_output.c was split: an example for csplit.py.

    scene_output_split.py [ORIGINAL]

ORIGINAL defaults to src/scene_output.c; it only matches the file as it was
before the split (pass REV:src/scene_output.c with the split commit's parent
to rerun it), and every `expect` stops it on anything else. Run from the
repository root.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from csplit import Source, unstatic, write  # noqa: E402

src = Source(sys.argv[1] if len(sys.argv) > 1 else 'src/scene_output.c', renames={
    'collect': 'scene_output_collect', 'clear_entries': 'scene_output_clear_entries',
    'decide_effects': 'scene_output_decide_effects', 'render_entry': 'scene_output_render_entry'})
R, expect, rename = src.R, src.expect, src.rename

expect(3, '#define WLR_USE_UNSTABLE')
expect(31, '#include <wlr/util/transform.h>')
expect(33, '// Stage 5c')
expect(78, 'static bool render_entry(')
expect(80, 'struct rediwm_output_renderer {')
expect(87, 'struct rediwm_output_renderer *rediwm_output_renderer_create(')
expect(160, '// Stage 3 parity')
expect(163, 'static struct wlr_box device_box(')
expect(176, 'static void device_region(')
expect(179, '// Which device corner')
expect(218, '// What of a clipped item')
expect(236, 'struct collector {')
expect(252, 'static bool same_clip(')
expect(258, 'static bool collect(')
expect(366, 'static void clear_entries(')
expect(374, '// The node\'s own texture cache.')
expect(389, 'static void sample(')
expect(399, 'static bool try_scanout(')
expect(443, '// Most entries lie outside')
expect(453, '// ---- Effects')
expect(454, 'uint64_t rediwm_scene_output_reblurs;')
expect(491, '// Decides, bottom to top')
expect(496, 'static bool decide_effects(')
expect(590, 'static void render_effect(')
expect(676, '// `backdrop`: drawing into')
expect(679, 'static bool render_entry(')
expect(808, '#ifdef REDIWM_DAMAGE_AUDIT')
expect(900, '#endif')
expect(901, 'bool rediwm_scene_output_build_state(')
expect(1034, '}')

hdr = ['// Private to scene_output*.c: what the output pass keeps per output and builds',
       '// per frame, and the device-space helpers every part uses (`static inline`, so a',
       '// file boundary costs them no inlining). Everyone else uses scene_output.h.',
       '#ifndef REDIWM_SCENE_OUTPUT_INTERNAL_H',
       '#define REDIWM_SCENE_OUTPUT_INTERNAL_H', '']
hdr += R(3, 31) + ['']
hdr += R(33, 77)            # effect_cache, output_state, entry
hdr += R(80, 86)            # struct rediwm_output_renderer
hdr += R(160, 162) + unstatic(R(163, 175), inline=True)   # device_box
hdr += unstatic(R(176, 178), inline=True)                 # device_region
hdr += R(236, 251)          # struct collector
hdr += ['',
        '// Shared between the parts (scene_output_*.c).',
        'extern uint64_t rediwm_scene_output_reblurs;',
        'bool scene_output_collect(const struct rediwm_item *item, struct rediwm_node *transport, void *data);',
        'void scene_output_clear_entries(struct rediwm_output_renderer *r);',
        'bool scene_output_decide_effects(struct rediwm_output_renderer *r, struct output_state *os,',
        '        struct rediwm_scene_output *out, const struct output_view *v, pixman_region32_t *changed);',
        'bool scene_output_render_entry(struct rediwm_output_renderer *r, struct entry *e, struct rediwm_scene_output *out,',
        '    struct wlr_render_pass *pass, const struct output_view *v, pixman_region32_t *damage, bool backdrop);',
        '',
        '#endif']
write('src/scene_output_internal.h', hdr)

core = R(1, 2) + ['#include "scene_output_internal.h"', '',
                  '// The parts: scene_output_collect.c turns the graph into this frame\'s entries,',
                  '// scene_output_effects.c decides which glass blurs are re-taken and',
                  '// scene_output_draw.c draws entries and effects. This file keeps the',
                  '// per-output state, direct scanout, the damage audit and the frame build.', '']
core += R(87, 159)
core += R(389, 442)          # sample, try_scanout
core += rename(R(808, 1034))  # audit, build_state
write('src/scene_output.c', core)

col = ['// What a frame draws: the graph\'s items, top to bottom, culled against what is',
       '// above them, with their visible and opaque regions. Part of scene_output.c.',
       '#include "scene_output_internal.h"', '']
col += R(218, 235)                          # clip_cover
col += R(252, 257)                          # same_clip
col += rename(unstatic(R(258, 365)))        # collect
col += rename(unstatic(R(366, 373)))        # clear_entries
write('src/scene_output_collect.c', col)

eff = R(453, 453) + ['// Part of scene_output.c.', '#include "scene_output_internal.h"', '']
eff += R(454, 490)
eff += R(491, 495) + rename(unstatic(R(496, 589)))
write('src/scene_output_effects.c', eff)

draw = ['// Drawing entries through the owned pass (scene_pass.c): clipped shapes, rects,',
        '// textures, shadows and glass. Part of scene_output.c.',
        '#include "scene_output_internal.h"', '']
draw += R(179, 217)          # device_radii, shape_for
draw += R(374, 388)          # buffer_texture
draw += R(443, 452)          # misses_damage
draw += rename(R(590, 675))
draw += R(676, 678) + rename(unstatic(R(679, 807)))
write('src/scene_output_draw.c', draw)
print('ok')
