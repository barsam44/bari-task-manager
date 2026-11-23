/* Aero glue implementation: SDL2 window + OpenGL context + Dear ImGui 1.9x.
 * Compiled as C with -DSDL_MAIN_HANDLED; Zig owns process entry. */
#include "glue.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SDL.h>
#include "imgui.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_opengl3.h"

#if defined(_WIN32)
#include <windows.h>
#endif
#include <GL/gl.h>

static SDL_Window*   g_window  = NULL;
static SDL_GLContext g_gl      = NULL;
static ImDrawList*   g_main_dl = NULL;

/* ------------------------------------------------------------------ */
/* lifecycle                                                           */
/* ------------------------------------------------------------------ */

int aero_app_init(const char* title, int w, int h)
{
    SDL_SetMainReady();
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 0);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 0);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return -1;
    }
    g_window = SDL_CreateWindow(title,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, w, h,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    if (!g_window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        return -2;
    }
    g_gl = SDL_GL_CreateContext(g_window);
    if (!g_gl) {
        fprintf(stderr, "SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        return -3;
    }
    SDL_GL_SetSwapInterval(1); /* vsync */

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = NULL; /* do not write imgui.ini */

    ImGui_ImplSDL2_InitForOpenGL(g_window, g_gl);
    ImGui_ImplOpenGL3_Init("#version 130");

    glClearColor(0.10f, 0.26f, 0.46f, 1.0f);
    return 0;
}

void aero_app_shutdown(void)
{
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();
    if (g_gl)   { SDL_GL_DeleteContext(g_gl); g_gl = NULL; }
    if (g_window) { SDL_DestroyWindow(g_window); g_window = NULL; }
    SDL_Quit();
}

int aero_pump_events(AeroEvents* ev)
{
    SDL_Event e;
    ev->quit = 0;
    ev->resized = 0;
    while (SDL_PollEvent(&e)) {
        ImGui_ImplSDL2_ProcessEvent(&e);
        if (e.type == SDL_QUIT) ev->quit = 1;
        if (e.type == SDL_WINDOWEVENT) {
            if (e.window.event == SDL_WINDOWEVENT_CLOSE) ev->quit = 1;
            if (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) ev->resized = 1;
        }
        if (e.type == SDL_KEYDOWN && !e.key.repeat &&
            e.key.keysym.sym == SDLK_ESCAPE) ev->quit = 1;
    }
    return ev->quit ? 0 : 1;
}

void aero_frame_begin(void)
{
    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL2_NewFrame();
    ImGui::NewFrame();
    g_main_dl = NULL;
}

void aero_frame_end(void)
{
    ImGui::Render();
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}

void aero_swap(void)
{
    SDL_GL_SwapWindow(g_window);
}

void aero_screenshot(const char* path)
{
    int w = 0, h = 0;
    SDL_GL_GetDrawableSize(g_window, &w, &h);
    if (w <= 0 || h <= 0) return;
    const size_t row = (size_t)w * 3;
    unsigned char* tmp = (unsigned char*)malloc(row * (size_t)h);
    if (!tmp) return;
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, tmp);
    FILE* f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        /* flip vertically: GL origin bottom-left */
        for (int y = h - 1; y >= 0; y--)
            fwrite(tmp + row * (size_t)y, 1, row, f);
        fclose(f);
    }
    free(tmp);
}

/* ------------------------------------------------------------------ */
/* io                                                                  */
/* ------------------------------------------------------------------ */

float aero_delta_time(void)  { return ImGui::GetIO().DeltaTime; }
float aero_framerate(void)   { return ImGui::GetIO().Framerate; }

void aero_display_size(float* w, float* h)
{
    ImVec2 s = ImGui::GetIO().DisplaySize;
    *w = s.x; *h = s.y;
}

void aero_mouse_pos(float* x, float* y)
{
    ImVec2 p = ImGui::GetIO().MousePos;
    *x = p.x; *y = p.y;
}

/* ------------------------------------------------------------------ */
/* style & fonts                                                       */
/* ------------------------------------------------------------------ */

void aero_style_setup(void)
{
    ImGuiStyle& s = ImGui::GetStyle();
    s.WindowRounding    = 0.0f;
    s.ChildRounding     = 14.0f;
    s.FrameRounding     = 9.0f;
    s.PopupRounding     = 14.0f;
    s.ScrollbarRounding = 12.0f;
    s.GrabRounding      = 9.0f;
    s.TabRounding       = 9.0f;
    s.ScrollbarSize     = 14.0f;
    s.FramePadding      = ImVec2(12, 7);
    s.ItemSpacing       = ImVec2(10, 8);
    s.ItemInnerSpacing  = ImVec2(8, 6);
    s.WindowPadding     = ImVec2(14, 14);
    s.WindowBorderSize  = 0.0f;
    s.ChildBorderSize   = 0.0f;
    s.PopupBorderSize   = 1.0f;
    s.FrameBorderSize   = 0.0f;

    ImVec4* c = s.Colors;
    c[ImGuiCol_WindowBg]           = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_ChildBg]            = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_PopupBg]            = ImVec4(0.96f, 0.98f, 1.00f, 0.94f);
    c[ImGuiCol_Text]               = ImVec4(0.09f, 0.17f, 0.24f, 1.00f);
    c[ImGuiCol_TextDisabled]       = ImVec4(0.09f, 0.17f, 0.24f, 0.55f);
    c[ImGuiCol_FrameBg]            = ImVec4(1.00f, 1.00f, 1.00f, 0.38f);
    c[ImGuiCol_FrameBgHovered]     = ImVec4(1.00f, 1.00f, 1.00f, 0.55f);
    c[ImGuiCol_FrameBgActive]      = ImVec4(1.00f, 1.00f, 1.00f, 0.70f);
    c[ImGuiCol_Header]             = ImVec4(1.00f, 1.00f, 1.00f, 0.25f);
    c[ImGuiCol_HeaderHovered]      = ImVec4(1.00f, 1.00f, 1.00f, 0.48f);
    c[ImGuiCol_HeaderActive]       = ImVec4(1.00f, 1.00f, 1.00f, 0.62f);
    c[ImGuiCol_Button]             = ImVec4(1.00f, 1.00f, 1.00f, 0.22f);
    c[ImGuiCol_ButtonHovered]      = ImVec4(1.00f, 1.00f, 1.00f, 0.42f);
    c[ImGuiCol_ButtonActive]       = ImVec4(1.00f, 1.00f, 1.00f, 0.58f);
    c[ImGuiCol_ScrollbarBg]        = ImVec4(1.00f, 1.00f, 1.00f, 0.10f);
    c[ImGuiCol_ScrollbarGrab]      = ImVec4(1.00f, 1.00f, 1.00f, 0.45f);
    c[ImGuiCol_ScrollbarGrabHovered] = ImVec4(1.00f, 1.00f, 1.00f, 0.65f);
    c[ImGuiCol_ScrollbarGrabActive]  = ImVec4(1.00f, 1.00f, 1.00f, 0.85f);
    c[ImGuiCol_TableBorderStrong]  = ImVec4(1.00f, 1.00f, 1.00f, 0.30f);
    c[ImGuiCol_TableBorderLight]   = ImVec4(1.00f, 1.00f, 1.00f, 0.18f);
    c[ImGuiCol_TableRowBg]         = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_TableRowBgAlt]      = ImVec4(1.00f, 1.00f, 1.00f, 0.10f);
    c[ImGuiCol_TableHeaderBg]      = ImVec4(1.00f, 1.00f, 1.00f, 0.30f);
    c[ImGuiCol_Separator]          = ImVec4(1.00f, 1.00f, 1.00f, 0.35f);
    c[ImGuiCol_TitleBg]            = ImVec4(0.62f, 0.78f, 0.92f, 0.85f);
    c[ImGuiCol_TitleBgActive]      = ImVec4(0.52f, 0.72f, 0.90f, 0.95f);
    c[ImGuiCol_TitleBgCollapsed]   = ImVec4(0.40f, 0.60f, 0.80f, 0.40f);
    c[ImGuiCol_ModalWindowDimBg]   = ImVec4(0.08f, 0.18f, 0.30f, 0.45f);
    c[ImGuiCol_DragDropTarget]     = ImVec4(1.00f, 1.00f, 1.00f, 0.90f);
    c[ImGuiCol_NavCursor]          = ImVec4(1.00f, 1.00f, 1.00f, 0.60f);
}

void* aero_load_font(const char* ttf_path, float size_px)
{
    /* fall back to the executable's directory if the relative path is missing */
    const char* path = ttf_path;
    char buf[1024];
    FILE* f = fopen(ttf_path, "rb");
    if (f) {
        fclose(f);
    } else {
        char* base = SDL_GetBasePath();
        if (base) {
            snprintf(buf, sizeof(buf), "%s%s", base, ttf_path);
            SDL_free(base);
            path = buf;
        }
    }
    ImFont* font = ImGui::GetIO().Fonts->AddFontFromFileTTF(path, size_px);
    return (void*)font;
}

void aero_set_default_font(void* font)
{
    if (font) ImGui::GetIO().FontDefault = (ImFont*)font;
}

void aero_calc_text_size(void* font, float size, const char* text, float* w, float* h)
{
    ImVec2 sz;
    if (font) {
        ImGui::PushFont((ImFont*)font, size);
        sz = ImGui::CalcTextSize(text, NULL, false, -1.0f);
        ImGui::PopFont();
    } else {
        sz = ImGui::CalcTextSize(text, NULL, false, -1.0f);
    }
    *w = sz.x; *h = sz.y;
}

/* ------------------------------------------------------------------ */
/* main window                                                         */
/* ------------------------------------------------------------------ */

int aero_begin_main(void)
{
    ImGuiIO& io = ImGui::GetIO();
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(io.DisplaySize);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
    ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration |
                             ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_NoScrollbar |
                             ImGuiWindowFlags_NoScrollWithMouse |
                             ImGuiWindowFlags_NoBringToFrontOnFocus |
                             ImGuiWindowFlags_NoNav |
                             ImGuiWindowFlags_NoBackground;
    int open = ImGui::Begin("##aero_main", NULL, flags);
    ImGui::PopStyleVar(3);
    g_main_dl = ImGui::GetWindowDrawList();
    return open;
}

void aero_end_main(void)
{
    ImGui::End();
}

void* aero_main_drawlist(void)
{
    return (void*)g_main_dl;
}

/* ------------------------------------------------------------------ */
/* child panels                                                        */
/* ------------------------------------------------------------------ */

void aero_child_begin(const char* name, float x, float y, float w, float h, int scroll_v)
{
    ImGui::SetCursorPos(ImVec2(x, y));
    ImGuiWindowFlags wf = ImGuiWindowFlags_NoTitleBar |
                          ImGuiWindowFlags_NoCollapse |
                          ImGuiWindowFlags_NoMove |
                          ImGuiWindowFlags_NoResize |
                          ImGuiWindowFlags_NoSavedSettings |
                          ImGuiWindowFlags_NoNav |
                          ImGuiWindowFlags_NoBackground;
    if (!scroll_v)
        wf |= ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse;
    ImGui::BeginChild(name, ImVec2(w, h), ImGuiChildFlags_None, wf);
}

void aero_child_end(void)
{
    ImGui::EndChild();
}

void* aero_cur_drawlist(void)
{
    return (void*)ImGui::GetWindowDrawList();
}

void aero_cur_pos(float* x, float* y)
{
    ImVec2 p = ImGui::GetCursorScreenPos();
    *x = p.x; *y = p.y;
}

/* ------------------------------------------------------------------ */
/* basic widgets                                                       */
/* ------------------------------------------------------------------ */

void aero_text(const char* text)
{
    ImGui::TextUnformatted(text);
}

void aero_text_col(float r, float g, float b, float a, const char* text)
{
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(r, g, b, a));
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
}

void aero_dummy(float h)
{
    ImGui::Dummy(ImVec2(0, h));
}

void aero_same_line(float offset_from_start_x, float spacing)
{
    ImGui::SameLine(offset_from_start_x, spacing);
}

void aero_separator(void)
{
    ImGui::Separator();
}

int aero_button(const char* label, float w, float h)
{
    return ImGui::Button(label, ImVec2(w, h)) ? 1 : 0;
}

int aero_invisible_button(const char* label, float w, float h)
{
    return ImGui::InvisibleButton(label, ImVec2(w, h), ImGuiButtonFlags_None) ? 1 : 0;
}

int aero_item_hovered(void) { return ImGui::IsItemHovered() ? 1 : 0; }
int aero_item_active(void)  { return ImGui::IsItemActive()  ? 1 : 0; }

void aero_item_rect(float* x0, float* y0, float* x1, float* y1)
{
    ImVec2 mn = ImGui::GetItemRectMin();
    ImVec2 mx = ImGui::GetItemRectMax();
    *x0 = mn.x; *y0 = mn.y; *x1 = mx.x; *y1 = mx.y;
}

int aero_input_text(const char* label, const char* hint, char* buf, int buf_size)
{
    return ImGui::InputTextWithHint(label, hint, buf, (size_t)buf_size, ImGuiInputTextFlags_None) ? 1 : 0;
}

void aero_set_cursor(float x, float y)
{
    ImGui::SetCursorPos(ImVec2(x, y));
}

void aero_set_item_width(float w)
{
    ImGui::SetNextItemWidth(w);
}

int aero_selectable(const char* label, int selected, float row_h, int span_cols)
{
    ImGuiSelectableFlags fl = ImGuiSelectableFlags_None;
    if (span_cols) fl |= ImGuiSelectableFlags_SpanAllColumns;
    return ImGui::Selectable(label, selected != 0, fl, ImVec2(0, row_h)) ? 1 : 0;
}

/* ------------------------------------------------------------------ */
/* tables                                                              */
/* ------------------------------------------------------------------ */

int aero_table_begin(const char* name, int cols, float outer_w, float outer_h)
{
    ImGuiTableFlags flags = ImGuiTableFlags_RowBg |
                            ImGuiTableFlags_BordersInnerV |
                            ImGuiTableFlags_ScrollY |
                            ImGuiTableFlags_SizingFixedFit |
                            ImGuiTableFlags_NoHostExtendX;
    return ImGui::BeginTable(name, cols, flags, ImVec2(outer_w, outer_h), 0.0f) ? 1 : 0;
}

void aero_table_col(const char* label, float w, int stretch)
{
    ImGuiTableColumnFlags fl = ImGuiTableColumnFlags_NoResize |
                               ImGuiTableColumnFlags_NoSort;
    if (stretch) fl |= ImGuiTableColumnFlags_WidthStretch;
    else         fl |= ImGuiTableColumnFlags_WidthFixed;
    ImGui::TableSetupColumn(label, fl, w, 0);
}

void aero_table_headers(void)   { ImGui::TableHeadersRow(); }
void aero_table_row(float min_h) { ImGui::TableNextRow(ImGuiTableRowFlags_None, min_h); }
void aero_table_col_i(int i)    { ImGui::TableSetColumnIndex(i); }
void aero_table_end(void)       { ImGui::EndTable(); }

/* ------------------------------------------------------------------ */
/* modal popup                                                         */
/* ------------------------------------------------------------------ */

void aero_open_popup(const char* name)
{
    ImGui::OpenPopup(name);
}

int aero_popup_begin(const char* title)
{
    return ImGui::BeginPopupModal(title, NULL, ImGuiWindowFlags_AlwaysAutoResize) ? 1 : 0;
}

void aero_popup_end(void)   { ImGui::EndPopup(); }
void aero_close_popup(void) { ImGui::CloseCurrentPopup(); }

/* ------------------------------------------------------------------ */
/* drawlist primitives                                                 */
/* ------------------------------------------------------------------ */

#define DL ((ImDrawList*)dl)

void aero_dl_gradient_v(void* dl, float x0, float y0, float x1, float y1, unsigned top, unsigned bottom)
{
    DL->AddRectFilledMultiColor(ImVec2(x0, y0), ImVec2(x1, y1), top, top, bottom, bottom);
}

void aero_dl_rect_filled(void* dl, float x0, float y0, float x1, float y1, float rounding, unsigned col)
{
    DL->AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), col, rounding, 0);
}

void aero_dl_rect(void* dl, float x0, float y0, float x1, float y1, float rounding, unsigned col, float thickness)
{
    DL->AddRect(ImVec2(x0, y0), ImVec2(x1, y1), col, rounding, 0, thickness);
}

void aero_dl_circle_filled(void* dl, float x, float y, float r, unsigned col)
{
    DL->AddCircleFilled(ImVec2(x, y), r, col, 0);
}

void aero_dl_circle(void* dl, float x, float y, float r, unsigned col, float thickness)
{
    DL->AddCircle(ImVec2(x, y), r, col, 0, thickness);
}

void aero_dl_line(void* dl, float x0, float y0, float x1, float y1, unsigned col, float thickness)
{
    DL->AddLine(ImVec2(x0, y0), ImVec2(x1, y1), col, thickness);
}

void aero_dl_arc(void* dl, float cx, float cy, float r, float a0, float a1, unsigned col, float thickness, int segments)
{
    DL->PathClear();
    DL->PathArcTo(ImVec2(cx, cy), r, a0, a1, segments > 0 ? segments : 24);
    DL->PathStroke(col, 0, thickness);
}

void aero_dl_poly_filled(void* dl, const float* xy, int n, unsigned col)
{
    DL->PathClear();
    for (int i = 0; i < n; i++)
        DL->PathLineTo(ImVec2(xy[i * 2], xy[i * 2 + 1]));
    DL->PathFillConvex(col);
}

void aero_dl_text(void* dl, float x, float y, unsigned col, void* font, float size, const char* text)
{
    ImFont* f = font ? (ImFont*)font : ImGui::GetFont();
    DL->AddText(f, size, ImVec2(x, y), col, text);
}

void aero_dl_push_clip(void* dl, float x0, float y0, float x1, float y1)
{
    DL->PushClipRect(ImVec2(x0, y0), ImVec2(x1, y1), true);
}

void aero_dl_pop_clip(void* dl)
{
    DL->PopClipRect();
}

void aero_dl_glow(void* dl, float x0, float y0, float x1, float y1, float rounding, unsigned col)
{
    unsigned a = (col >> 24) & 0xFFu;
    unsigned r = (col >> 16) & 0xFFu;
    unsigned g = (col >> 8)  & 0xFFu;
    unsigned b =  col        & 0xFFu;
    for (int i = 1; i <= 4; i++) {
        float e = (float)i * 1.7f;
        unsigned ai = (unsigned)(a / (2.4f * (float)i));
        if (ai == 0) break;
        unsigned ci = IM_COL32(r, g, b, ai);
        DL->AddRectFilled(ImVec2(x0 - e, y0 - e), ImVec2(x1 + e, y1 + e), ci, rounding + e, 0);
    }
}

void aero_dl_circle_glow(void* dl, float x, float y, float r, unsigned col)
{
    unsigned a = (col >> 24) & 0xFFu;
    unsigned rr = (col >> 16) & 0xFFu;
    unsigned g  = (col >> 8)  & 0xFFu;
    unsigned b  =  col        & 0xFFu;
    for (int i = 1; i <= 4; i++) {
        float e = (float)i * 2.2f;
        unsigned ai = (unsigned)(a / (2.6f * (float)i));
        if (ai == 0) break;
        DL->AddCircleFilled(ImVec2(x, y), r + e, IM_COL32(rr, g, b, ai), 0);
    }
}

#undef DL
