#include "SilTermVTermBridge.h"

#include <string.h>

int silterm_value_bool(const VTermValue *v) {
    return v ? v->boolean : 0;
}

int silterm_value_number(const VTermValue *v) {
    return v ? v->number : 0;
}

const char *silterm_value_string(const VTermValue *v) {
    return v ? v->string.str : NULL;
}

size_t silterm_value_string_len(const VTermValue *v) {
    return v ? (size_t)v->string.len : 0;
}

int silterm_value_string_final(const VTermValue *v) {
    return v ? (int)v->string.final : 0;
}

int silterm_color_is_default_fg(const VTermColor *c) {
    return c ? (int)VTERM_COLOR_IS_DEFAULT_FG(c) : 0;
}

int silterm_color_is_default_bg(const VTermColor *c) {
    return c ? (int)VTERM_COLOR_IS_DEFAULT_BG(c) : 0;
}

int silterm_color_is_indexed(const VTermColor *c) {
    return c ? (int)VTERM_COLOR_IS_INDEXED(c) : 0;
}

int silterm_color_is_rgb(const VTermColor *c) {
    return c ? (int)VTERM_COLOR_IS_RGB(c) : 0;
}

int silterm_color_index(const VTermColor *c) {
    return c ? (int)c->indexed.idx : 0;
}

void silterm_color_rgb_values(const VTermColor *c, int *r, int *g, int *b) {
    if (!c) {
        if (r) *r = 0;
        if (g) *g = 0;
        if (b) *b = 0;
        return;
    }
    if (r) *r = (int)c->rgb.red;
    if (g) *g = (int)c->rgb.green;
    if (b) *b = (int)c->rgb.blue;
}

void silterm_decode_cell(const VTermScreenCell *cell, SilTermCellInfo *out) {
    if (!out) {
        return;
    }
    memset(out, 0, sizeof(*out));
    if (!cell) {
        return;
    }
    for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL; i++) {
        out->chars[i] = cell->chars[i];
    }
    out->width = (int)cell->width;
    out->bold = (int)cell->attrs.bold;
    out->underline = (int)cell->attrs.underline;
    out->italic = (int)cell->attrs.italic;
    out->blink = (int)cell->attrs.blink;
    out->reverse = (int)cell->attrs.reverse;
    out->strike = (int)cell->attrs.strike;
    out->conceal = (int)cell->attrs.conceal;

    const VTermColor *fg = &cell->fg;
    const VTermColor *bg = &cell->bg;
    out->fg_default = (int)VTERM_COLOR_IS_DEFAULT_FG(fg);
    out->fg_indexed = (int)VTERM_COLOR_IS_INDEXED(fg);
    out->fg_index = (int)fg->indexed.idx;
    out->fg_r = (int)fg->rgb.red;
    out->fg_g = (int)fg->rgb.green;
    out->fg_b = (int)fg->rgb.blue;

    out->bg_default = (int)VTERM_COLOR_IS_DEFAULT_BG(bg);
    out->bg_indexed = (int)VTERM_COLOR_IS_INDEXED(bg);
    out->bg_index = (int)bg->indexed.idx;
    out->bg_r = (int)bg->rgb.red;
    out->bg_g = (int)bg->rgb.green;
    out->bg_b = (int)bg->rgb.blue;
}
