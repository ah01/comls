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
    CHECK(CloseHandle(read_handle));
    CHECK(!output_text(write_handle, L"closed pipe"));
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

int main(void)
{
    check_utf8();
    check_console();
    puts("Unicode output tests passed.");
    return 0;
}
