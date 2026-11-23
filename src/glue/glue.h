/* Aero glue - minimal C ABI bridge between Zig and SDL2 + Dear ImGui.
 * Everything here is plain C so both Zig (via translate-c) and the C++
 * ImGui sources can share it. All coordinates are in ImGui display space. */
#ifndef AERO_GLUE_H
#define AERO_GLUE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { float x, y; } AeroVec2;

typedef struct {
    int quit;     /* user closed window or pressed ESC */
    int resized;  /* window was resized since last frame */
    float new_w;
    float new_h;
} AeroEvents;

/* ---- lifecycle ---- */
int   aero_app_init(const char* title, int w, int h);   /* 0 = ok */
void  aero_app_shutdown(void);
int   aero_pump_events(AeroEvents* ev);                 /* 1 = keep running */
void  aero_frame_begin(void);
void  aero_frame_end(void);                             /* render ImGui (no swap) */
void  aero_swap(void);                                  /* present back buffer */
void  aero_screenshot(const char* path);                /* dump back buffer as PPM */

/* ---- io ---- */
float aero_delta_time(void);
float aero_framerate(void);
void  aero_display_size(float* w, float* h);
void  aero_mouse_pos(float* x, float* y);

/* ---- style & fonts ---- */
void  aero_style_setup(void);
void* aero_load_font(const char* ttf_path, float size_px); /* NULL on failure */
void  aero_set_default_font(void* font);
/* NOTE: only valid while a frame is open (between frame_begin/frame_end). */
void  aero_calc_text_size(void* font, float size, const char* text, float* w, float* h);

/* ---- main fullscreen window ---- */
int   aero_begin_main(void);
void  aero_end_main(void);
void* aero_main_drawlist(void);

/* ---- child glass panels (positions relative to main window) ---- */
void  aero_child_begin(const char* name, float x, float y, float w, float h, int scroll_v);
void  aero_child_end(void);
void* aero_cur_drawlist(void);   /* drawlist of the current window (child) */
void  aero_cur_pos(float* x, float* y); /* current cursor position, absolute */

/* ---- basic widgets ---- */
void  aero_text(const char* text);
void  aero_text_col(float r, float g, float b, float a, const char* text);
void  aero_dummy(float h);
void  aero_same_line(float offset_from_start_x, float spacing);
void  aero_separator(void);
int   aero_button(const char* label, float w, float h);
int   aero_invisible_button(const char* label, float w, float h);
int   aero_item_hovered(void);
int   aero_item_active(void);
void  aero_item_rect(float* x0, float* y0, float* x1, float* y1);
int   aero_input_text(const char* label, const char* hint, char* buf, int buf_size); /* 1 = edited */
void  aero_set_cursor(float x, float y); /* relative to current window */
void  aero_set_item_width(float w);
int   aero_selectable(const char* label, int selected, float row_h, int span_cols);

/* ---- tables ---- */
int   aero_table_begin(const char* name, int cols, float outer_w, float outer_h);
void  aero_table_col(const char* label, float w, int stretch);
void  aero_table_headers(void);
void  aero_table_row(float min_h);
void  aero_table_col_i(int i);
void  aero_table_end(void);

/* ---- modal popup ---- */
void  aero_open_popup(const char* name);
int   aero_popup_begin(const char* title);
void  aero_popup_end(void);
void  aero_close_popup(void);

/* ---- drawlist primitives ---- */
void  aero_dl_gradient_v(void* dl, float x0, float y0, float x1, float y1, unsigned top, unsigned bottom);
void  aero_dl_rect_filled(void* dl, float x0, float y0, float x1, float y1, float rounding, unsigned col);
void  aero_dl_rect(void* dl, float x0, float y0, float x1, float y1, float rounding, unsigned col, float thickness);
void  aero_dl_circle_filled(void* dl, float x, float y, float r, unsigned col);
void  aero_dl_circle(void* dl, float x, float y, float r, unsigned col, float thickness);
void  aero_dl_line(void* dl, float x0, float y0, float x1, float y1, unsigned col, float thickness);
void  aero_dl_arc(void* dl, float cx, float cy, float r, float a0, float a1, unsigned col, float thickness, int segments);
void  aero_dl_poly_filled(void* dl, const float* xy, int n, unsigned col);
void  aero_dl_text(void* dl, float x, float y, unsigned col, void* font, float size, const char* text);
void  aero_dl_push_clip(void* dl, float x0, float y0, float x1, float y1);
void  aero_dl_pop_clip(void* dl);
void  aero_dl_glow(void* dl, float x0, float y0, float x1, float y1, float rounding, unsigned col);
void  aero_dl_circle_glow(void* dl, float x, float y, float r, unsigned col);

#ifdef __cplusplus
}
#endif
#endif /* AERO_GLUE_H */
