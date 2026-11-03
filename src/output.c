#include "output.h"

#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

int output_text(HANDLE stream, const wchar_t *text)
{
    DWORD mode, written;
    size_t length = wcslen(text);
    if (GetConsoleMode(stream, &mode)) {
        while (length) {
            DWORD chunk = length > 16384 ? 16384 : (DWORD)length;
            if (length > chunk && text[chunk - 1] >= 0xD800 &&
                text[chunk - 1] <= 0xDBFF && text[chunk] >= 0xDC00 &&
                text[chunk] <= 0xDFFF)
                --chunk;
            if (!WriteConsoleW(stream, text, chunk, &written, NULL))
                return 0;
            if (!written) {
                SetLastError(ERROR_WRITE_FAULT);
                return 0;
            }
            text += written;
            length -= written;
        }
        return 1;
    } else {
        char *utf8;
        int bytes;
        const char *cursor;
        if (!length)
            return 1;
        if (length > INT_MAX) {
            SetLastError(ERROR_NOT_ENOUGH_MEMORY);
            return 0;
        }
        bytes = WideCharToMultiByte(CP_UTF8, 0, text, (int)length,
                                   NULL, 0, NULL, NULL);
        if (!bytes)
            return 0;
        utf8 = malloc((size_t)bytes);
        if (!utf8) {
            SetLastError(ERROR_NOT_ENOUGH_MEMORY);
            return 0;
        }
        if (!WideCharToMultiByte(CP_UTF8, 0, text, (int)length,
                                utf8, bytes, NULL, NULL)) {
            DWORD error = GetLastError();
            free(utf8);
            SetLastError(error);
            return 0;
        }
        cursor = utf8;
        while (bytes) {
            BOOL success = WriteFile(stream, cursor, (DWORD)bytes, &written, NULL);
            if (!success || !written) {
                DWORD error = success ? ERROR_WRITE_FAULT : GetLastError();
                free(utf8);
                SetLastError(error);
                return 0;
            }
            cursor += written;
            bytes -= (int)written;
        }
        free(utf8);
        return 1;
    }
}

static int output_color_text(HANDLE stream, OutputColor color, const wchar_t *text)
{
    CONSOLE_SCREEN_BUFFER_INFO info;
    DWORD mode, error;
    WORD foreground, attributes;
    int result;
    if (color == OUTPUT_DEFAULT || !GetConsoleMode(stream, &mode))
        return output_text(stream, text);
    if (!GetConsoleScreenBufferInfo(stream, &info))
        return 0;
    switch (color) {
    case OUTPUT_BLUE:
        foreground = FOREGROUND_BLUE | FOREGROUND_INTENSITY;
        break;
    case OUTPUT_YELLOW:
        foreground = FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_INTENSITY;
        break;
    case OUTPUT_GRAY:
        foreground = FOREGROUND_INTENSITY;
        break;
    default:
        SetLastError(ERROR_INVALID_PARAMETER);
        return 0;
    }
    attributes = (WORD)((info.wAttributes & ~(FOREGROUND_RED | FOREGROUND_GREEN |
                        FOREGROUND_BLUE | FOREGROUND_INTENSITY)) | foreground);
    if (!SetConsoleTextAttribute(stream, attributes))
        return 0;
    result = output_text(stream, text);
    error = GetLastError();
    if (!SetConsoleTextAttribute(stream, info.wAttributes) && result)
        return 0;
    SetLastError(error);
    return result;
}

static int output_vformat(HANDLE stream, OutputColor color,
                          const wchar_t *format, va_list args)
{
    va_list measure;
    int length, result;
    wchar_t *text;
    va_copy(measure, args);
    length = _vscwprintf(format, measure);
    va_end(measure);
    if (length < 0) {
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    text = malloc(((size_t)length + 1) * sizeof(*text));
    if (!text) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return 0;
    }
    result = vswprintf_s(text, (size_t)length + 1, format, args);
    if (result < 0) {
        free(text);
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    result = output_color_text(stream, color, text);
    {
        DWORD error = GetLastError();
        free(text);
        SetLastError(error);
    }
    return result;
}

int output_format(HANDLE stream, const wchar_t *format, ...)
{
    va_list args;
    int result;
    va_start(args, format);
    result = output_vformat(stream, OUTPUT_DEFAULT, format, args);
    va_end(args);
    return result;
}

int output_color_format(HANDLE stream, OutputColor color, const wchar_t *format, ...)
{
    va_list args;
    int result;
    va_start(args, format);
    result = output_vformat(stream, color, format, args);
    va_end(args);
    return result;
}

void report_error(const wchar_t *context, DWORD error)
{
    wchar_t message[512] = L"";
    DWORD length = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL, error, 0, message, ARRAYSIZE(message), NULL);
    if (!length || length >= ARRAYSIZE(message)) {
        output_format(GetStdHandle(STD_ERROR_HANDLE),
                      L"comls: %ls (error %lu): No system message available\n", context, error);
        return;
    }
    message[length] = L'\0';
    while (length && (message[length - 1] == L'\r' ||
                      message[length - 1] == L'\n'))
        message[--length] = L'\0';
    output_format(GetStdHandle(STD_ERROR_HANDLE), L"comls: %ls (error %lu): %ls\n",
                  context, error, message);
}
