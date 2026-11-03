#include "usb_ids.h"
#include "resource.h"

#include <windows.h>
#include <compressapi.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static uint32_t read32(const unsigned char *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
        (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int valid_name(const UsbIds *ids, uint32_t offset)
{
    const char *end;
    size_t length;
    if (offset >= ids->strings_size ||
        (offset && ids->strings[offset - 1] != '\0'))
        return 0;
    end = memchr(ids->strings + offset, 0, ids->strings_size - offset);
    if (!end)
        return 0;
    length = (size_t)(end - (ids->strings + offset));
    return length && length <= INT_MAX &&
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                            ids->strings + offset, (int)length, NULL, 0) > 0;
}

int usb_ids_open(UsbIds *ids, const void *data, size_t size)
{
    const unsigned char *bytes = data;
    UsbIds view = {0};
    uint32_t pool, i, next_product = 0, previous_vendor = 0;
    uint64_t expected;
    memset(ids, 0, sizeof(*ids));
    if (!bytes || size < 32 || memcmp(bytes, "CUSBIDS\0", 8) != 0 ||
        read32(bytes + 8) != 1 || read32(bytes + 28) != 0)
        goto invalid;
    view.vendor_count = read32(bytes + 12);
    view.product_count = read32(bytes + 16);
    pool = read32(bytes + 20);
    view.strings_size = read32(bytes + 24);
    expected = 32ULL + (uint64_t)view.vendor_count * 16 +
        (uint64_t)view.product_count * 8;
    if (!view.vendor_count || !view.product_count || !view.strings_size ||
        expected != pool || expected + view.strings_size != size)
        goto invalid;
    view.vendors = bytes + 32;
    view.products = view.vendors + (size_t)view.vendor_count * 16;
    view.strings = (const char *)bytes + pool;
    for (i = 0; i < view.vendor_count; ++i) {
        const unsigned char *v = view.vendors + (size_t)i * 16;
        uint32_t vid = read32(v), first = read32(v + 8), count = read32(v + 12);
        uint32_t j, previous_pid = 0;
        if (vid > 0xFFFF || (i && vid <= previous_vendor) ||
            first != next_product || count > view.product_count - next_product ||
            !valid_name(&view, read32(v + 4)))
            goto invalid;
        for (j = 0; j < count; ++j) {
            const unsigned char *p = view.products + (size_t)(first + j) * 8;
            uint32_t pid = read32(p);
            if (pid > 0xFFFF || (j && pid <= previous_pid) ||
                !valid_name(&view, read32(p + 4)))
                goto invalid;
            previous_pid = pid;
        }
        previous_vendor = vid;
        next_product += count;
    }
    if (next_product != view.product_count)
        goto invalid;
    *ids = view;
    return 1;
invalid:
    SetLastError(ERROR_INVALID_DATA);
    return 0;
}

int usb_ids_unpack(UsbIds *ids, const void *data, size_t size)
{
    DECOMPRESSOR_HANDLE decompressor;
    SIZE_T needed = 0, written = 0;
    void *buffer = NULL;
    DWORD error;
    int ok = 0;
    memset(ids, 0, sizeof(*ids));
    if (!data || !size) {
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    if (!CreateDecompressor(COMPRESS_ALGORITHM_MSZIP, NULL, &decompressor))
        return 0;
    if (Decompress(decompressor, data, size, NULL, 0, &needed)) {
        SetLastError(ERROR_INVALID_DATA);
        goto done;
    }
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER)
        goto done;
    /* Reject corrupt size headers before allocating from the process heap. */
    if (needed < 32 || needed > 64 * 1024 * 1024) {
        SetLastError(ERROR_INVALID_DATA);
        goto done;
    }
    buffer = malloc(needed);
    if (!buffer) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        goto done;
    }
    if (!Decompress(decompressor, data, size, buffer, needed, &written))
        goto done;
    if (written != needed) {
        SetLastError(ERROR_INVALID_DATA);
        goto done;
    }
    if (!usb_ids_open(ids, buffer, written))
        goto done;
    ids->allocation = buffer;
    buffer = NULL;
    ok = 1;
done:
    error = GetLastError();
    CloseDecompressor(decompressor);
    free(buffer);
    SetLastError(error);
    return ok;
}

void usb_ids_close(UsbIds *ids)
{
    free(ids->allocation);
    memset(ids, 0, sizeof(*ids));
}

int usb_ids_load(UsbIds *ids)
{
    HMODULE module = GetModuleHandleW(NULL);
    HRSRC resource;
    HGLOBAL loaded;
    DWORD size;
    const void *data;
    memset(ids, 0, sizeof(*ids));
    if (!module)
        return 0;
    resource = FindResourceW(module, MAKEINTRESOURCEW(IDR_USB_IDS), RT_RCDATA);
    if (!resource)
        return 0;
    size = SizeofResource(module, resource);
    if (!size) {
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    loaded = LoadResource(module, resource);
    if (!loaded)
        return 0;
    data = LockResource(loaded);
    if (!data) {
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    return usb_ids_unpack(ids, data, size);
}

static const unsigned char *find_id(const unsigned char *records,
                                    uint32_t count, size_t stride, unsigned id)
{
    uint32_t low = 0, high = count;
    while (low < high) {
        uint32_t middle = low + (high - low) / 2;
        const unsigned char *record = records + (size_t)middle * stride;
        uint32_t found = read32(record);
        if (found < id)
            low = middle + 1;
        else if (found > id)
            high = middle;
        else
            return record;
    }
    return NULL;
}

static wchar_t *copy_name(const UsbIds *ids, uint32_t offset)
{
    const char *text = ids->strings + offset;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    wchar_t *copy;
    if (!count)
        return NULL;
    copy = malloc((size_t)count * sizeof(*copy));
    if (!copy) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, copy, count)) {
        DWORD error = GetLastError();
        free(copy);
        SetLastError(error);
        return NULL;
    }
    return copy;
}

int usb_ids_lookup(const UsbIds *ids, unsigned vid, unsigned pid,
                   wchar_t **vendor, wchar_t **product)
{
    const unsigned char *v, *p;
    *vendor = NULL;
    *product = NULL;
    v = find_id(ids->vendors, ids->vendor_count, 16, vid);
    if (!v)
        return 1;
    *vendor = copy_name(ids, read32(v + 4));
    if (!*vendor)
        return 0;
    p = find_id(ids->products + (size_t)read32(v + 8) * 8,
                read32(v + 12), 8, pid);
    if (p) {
        *product = copy_name(ids, read32(p + 4));
        if (!*product) {
            DWORD error = GetLastError();
            free(*vendor);
            *vendor = NULL;
            SetLastError(error);
            return 0;
        }
    }
    return 1;
}
