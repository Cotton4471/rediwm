/* Query actual toolkit styling after GTK loads the exported user CSS. */
#include <gtk/gtk.h>
#include <stdio.h>
#ifdef USE_ADWAITA
#include <adwaita.h>
#endif

int main(int argc, char **argv) {
#if GTK_MAJOR_VERSION == 3
    gtk_init(&argc, &argv);
#else
    (void)argc; (void)argv;
    gtk_init();
#endif
#ifdef USE_ADWAITA
    adw_init();
    GtkWidget *window = adw_window_new();
#else
    GtkWidget *window = gtk_window_new(
#if GTK_MAJOR_VERSION == 3
        GTK_WINDOW_TOPLEVEL
#endif
    );
#endif
    GtkStyleContext *context = gtk_widget_get_style_context(window);
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 4, 4);
    cairo_t *cr = cairo_create(surface);
    GdkRGBA fg;
#if GTK_MAJOR_VERSION == 3
    gtk_style_context_get_color(context, GTK_STATE_FLAG_NORMAL, &fg);
    gtk_render_background(context, cr, 0, 0, 4, 4);
#else
    gtk_style_context_get_color(context, &fg);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gtk_snapshot_render_background(snapshot, context, 0, 0, 4, 4);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    if (node) {
        gsk_render_node_draw(node, cr);
        gsk_render_node_unref(node);
    }
#endif
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    unsigned pixel = *(unsigned *)(cairo_image_surface_get_data(surface) + cairo_image_surface_get_stride(surface) + 4);
    printf("{\"bg\":\"#%06x\",\"fg\":\"#%02x%02x%02x\"}\n", pixel & 0xffffff,
        (unsigned)(fg.red * 255 + .5), (unsigned)(fg.green * 255 + .5), (unsigned)(fg.blue * 255 + .5));
    cairo_surface_destroy(surface);
#if GTK_MAJOR_VERSION == 3
    gtk_widget_destroy(window);
#else
    gtk_window_destroy(GTK_WINDOW(window));
#endif
    return 0;
}
