#ifndef COMLS_OUTPUT_H
#define COMLS_OUTPUT_H

#include <windows.h>

typedef enum {
    OUTPUT_DEFAULT,
    OUTPUT_BLUE,
    OUTPUT_YELLOW,
    OUTPUT_GRAY
} OutputColor;

int output_text(HANDLE stream, const wchar_t *text);
int output_format(HANDLE stream, const wchar_t *format, ...);
int output_color_format(HANDLE stream, OutputColor color, const wchar_t *format, ...);
void report_error(const wchar_t *context, DWORD error);

#endif
