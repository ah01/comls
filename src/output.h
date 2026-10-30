#ifndef COMLS_OUTPUT_H
#define COMLS_OUTPUT_H

#include <windows.h>

int output_text(HANDLE stream, const wchar_t *text);
int output_format(HANDLE stream, const wchar_t *format, ...);
void report_error(const wchar_t *context, DWORD error);

#endif
