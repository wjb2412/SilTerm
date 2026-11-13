#ifndef SILTERM_VTERM_BRIDGE_H
#define SILTERM_VTERM_BRIDGE_H

#include "vterm.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* VTermValue 是 C union，Swift 无法直接访问成员，这里提供取值辅助函数 */
int silterm_value_bool(const VTermValue *v);
int silterm_value_number(const VTermValue *v);
const char *silterm_value_string(const VTermValue *v);
size_t silterm_value_string_len(const VTermValue *v);
int silterm_value_string_final(const VTermValue *v);

int silterm_color_is_default_fg(const VTermColor *c);
int silterm_color_is_default_bg(const VTermColor *c);
int silterm_color_is_indexed(const VTermColor *c);
int silterm_color_is_rgb(const VTermColor *c);
int silterm_color_index(const VTermColor *c);
void silterm_color_rgb_values(const VTermColor *c, int *r, int *g, int *b);

/* 将单个终端单元格一次性解码为扁平结构，减少跨语言调用次数 */
typedef struct {
    uint32_t chars[VTERM_MAX_CHARS_PER_CELL];
    int width;
    int bold;
    int underline;
    int italic;
    int blink;
    int reverse;
    int strike;
    int conceal;

    int fg_default;
    int fg_indexed;
    int fg_index;
    int fg_r, fg_g, fg_b;

    int bg_default;
    int bg_indexed;
    int bg_index;
    int bg_r, bg_g, bg_b;
} SilTermCellInfo;

void silterm_decode_cell(const VTermScreenCell *cell, SilTermCellInfo *out);

#ifdef __cplusplus
}
#endif

#endif /* SILTERM_VTERM_BRIDGE_H */
