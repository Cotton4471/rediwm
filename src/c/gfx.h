/* libc plus the drawing and keyboard stack (`c_gfx`): what ui/ and the app
 * clients share, so a cairo_t or xkb_state means one type across them. */
#include "libc.h"

#include <cairo.h>
#include <cairo-pdf.h>
#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include <freetype/freetype.h>
#include <freetype/ftmm.h>
#include <freetype/ftsizes.h>
#include <hb.h>
#include <hb-ft.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <xkbcommon/xkbcommon-keysyms.h>
