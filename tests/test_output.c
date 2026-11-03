#include "output.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define CHECK(expression) do { \
    if (!(expression)) { \
        fprintf(stderr, "FAIL line %d: %s (Win32 %lu)\n", \
                __LINE__, #expression, GetLastError()); \
        exit(1); \
    } \
} while (0)

static void check_utf8(void)
{
    static const unsigned char expected[] = {
        0xC5, 0xBD, 0xE6, 0x97, 0xA5, 0xF0, 0x9F, 0x98, 0x80,
        ' ', '1', '7'
    };
    unsigned char actual[32];
    HANDLE read_handle, write_handle;
    DWORD read_bytes;
    CHECK(CreatePipe(&read_handle, &write_handle, NULL, 0));
    CHECK(output_text(write_handle, L"\u017D\u65E5\U0001F600"));
    CHECK(output_format(write_handle, L" %d", 17));
    CHECK(CloseHandle(write_handle));
    CHECK(ReadFile(read_handle, actual, sizeof(actual), &read_bytes, NULL));
    CHECK(read_bytes == sizeof(expected));
    CHECK(memcmp(actual, expected, sizeof(expected)) == 0);
    CHECK(CloseHandle(read_handle));
    CHECK(CreatePipe(&read_handle, &write_handle, NULL, 0));
    CHECK(output_color_format(write_handle, OUTPUT_BLUE, L"%ls", L"BL"));
    CHECK(output_color_format(write_handle, OUTPUT_YELLOW, L" %ls", L"USB"));
    CHECK(output_color_format(write_handle, OUTPUT_GRAY, L" [%d]", 17));
    CHECK(output_color_format(write_handle, OUTPUT_AQUA, L" +%d min", 5));
    CHECK(CloseHandle(write_handle));
    CHECK(ReadFile(read_handle, actual, sizeof(actual), &read_bytes, NULL));
    CHECK(read_bytes == strlen("BL USB [17] +5 min"));
    CHECK(memcmp(actual, "BL USB [17] +5 min", read_bytes) == 0);
    CHECK(CloseHandle(read_handle));
    CHECK(CreatePipe(&read_handle, &write_handle, NULL, 0));
    CHECK(CloseHandle(read_handle));
    CHECK(!output_text(write_handle, L"closed pipe"));
    CHECK(GetLastError() == ERROR_BROKEN_PIPE || GetLastError() == ERROR_NO_DATA);
    CHECK(!output_color_format(write_handle, OUTPUT_YELLOW, L"closed pipe"));
    CHECK(GetLastError() == ERROR_BROKEN_PIPE || GetLastError() == ERROR_NO_DATA);
    CHECK(CloseHandle(write_handle));
}

static void check_console(void)
{
    static const wchar_t expected[] = L"\u017Dlu\u0165ou\u010Dk\u00FD";
    HANDLE buffer;
    COORD origin = {0, 0};
    wchar_t actual[32] = L"";
    DWORD read_chars;
    int allocated = 0;
    buffer = CreateConsoleScreenBuffer(GENERIC_READ | GENERIC_WRITE, 0,
                                       NULL, CONSOLE_TEXTMODE_BUFFER, NULL);
    if (buffer == INVALID_HANDLE_VALUE) {
        CHECK(AllocConsole());
        allocated = 1;
        buffer = CreateConsoleScreenBuffer(GENERIC_READ | GENERIC_WRITE, 0,
                                           NULL, CONSOLE_TEXTMODE_BUFFER, NULL);
    }
    CHECK(buffer != INVALID_HANDLE_VALUE);
    CHECK(SetConsoleCursorPosition(buffer, origin));
    CHECK(output_text(buffer, expected));
    CHECK(ReadConsoleOutputCharacterW(buffer, actual,
          (DWORD)wcslen(expected), origin, &read_chars));
    CHECK(read_chars == wcslen(expected));
    CHECK(wcscmp(actual, expected) == 0);
    CHECK(CloseHandle(buffer));
    if (allocated)
        CHECK(FreeConsole());
}

static void check_colors(void)
{
    static const struct {
        OutputColor color;
        WORD foreground;
    } cases[] = {
        { OUTPUT_BLUE, FOREGROUND_BLUE | FOREGROUND_INTENSITY },
        { OUTPUT_YELLOW, FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_INTENSITY },
        { OUTPUT_GRAY, FOREGROUND_INTENSITY },
        { OUTPUT_AQUA, FOREGROUND_GREEN | FOREGROUND_BLUE | FOREGROUND_INTENSITY },
        { OUTPUT_DEFAULT, FOREGROUND_RED | FOREGROUND_GREEN }
    };
    HANDLE buffer;
    CONSOLE_SCREEN_BUFFER_INFO info;
    COORD origin = {0, 0};
    WORD actual[2];
    WORD original = BACKGROUND_BLUE | FOREGROUND_RED | FOREGROUND_GREEN;
    WORD mask = FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE | FOREGROUND_INTENSITY;
    DWORD count;
    size_t i;
    int allocated = 0;
    buffer = CreateConsoleScreenBuffer(GENERIC_READ | GENERIC_WRITE, 0,
                                       NULL, CONSOLE_TEXTMODE_BUFFER, NULL);
    if (buffer == INVALID_HANDLE_VALUE) {
        CHECK(AllocConsole());
        allocated = 1;
        buffer = CreateConsoleScreenBuffer(GENERIC_READ | GENERIC_WRITE, 0,
                                           NULL, CONSOLE_TEXTMODE_BUFFER, NULL);
    }
    CHECK(buffer != INVALID_HANDLE_VALUE);
    CHECK(SetConsoleTextAttribute(buffer, original));
    for (i = 0; i < ARRAYSIZE(cases); ++i) {
        CHECK(SetConsoleCursorPosition(buffer, origin));
        CHECK(output_color_format(buffer, cases[i].color, L"%ls", L"X"));
        CHECK(output_text(buffer, L"Y"));
        CHECK(ReadConsoleOutputAttribute(buffer, actual, ARRAYSIZE(actual), origin, &count));
        CHECK(count == ARRAYSIZE(actual));
        CHECK(actual[0] == (WORD)((original & ~mask) | cases[i].foreground));
        CHECK(actual[1] == original);
        CHECK(GetConsoleScreenBufferInfo(buffer, &info));
        CHECK(info.wAttributes == original);
    }
    CHECK(CloseHandle(buffer));
    if (allocated)
        CHECK(FreeConsole());
}

int main(void)
{
    check_utf8();
    check_console();
    check_colors();
    puts("Unicode and console color output tests passed.");
    return 0;
}
