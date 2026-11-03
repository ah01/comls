#include "usb_ids.h"
#include "resource.h"

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expression) do { \
    if (!(expression)) { \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); \
        exit(1); \
    } \
} while (0)

static void check_lookup(const UsbIds *ids, unsigned vid, unsigned pid,
                          const wchar_t *expected_vendor, const wchar_t *expected_product)
{
    wchar_t *vendor, *product;
    CHECK(usb_ids_lookup(ids, vid, pid, &vendor, &product));
    CHECK(expected_vendor ? vendor && wcscmp(vendor, expected_vendor) == 0 : !vendor);
    CHECK(expected_product ? product && wcscmp(product, expected_product) == 0 : !product);
    free(vendor);
    free(product);
}

static uint32_t read32(const unsigned char *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
        (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void write32(unsigned char *p, uint32_t value)
{
    unsigned i;
    for (i = 0; i < 4; ++i)
        p[i] = (unsigned char)(value >> (i * 8));
}

static void reject(const unsigned char *bytes, size_t size)
{
    UsbIds ids;
    SetLastError(ERROR_SUCCESS);
    CHECK(!usb_ids_open(&ids, bytes, size));
    CHECK(GetLastError() == ERROR_INVALID_DATA);
    CHECK(!ids.vendors && !ids.products && !ids.strings && !ids.vendor_count);
}

static void check_invalid(const unsigned char *original, size_t size)
{
    static const struct {
        size_t offset;
        uint32_t value;
    } mutations[] = {
        { 8, 2 }, { 12, 0 }, { 12, UINT32_MAX }, { 16, 0 },
        { 16, UINT32_MAX }, { 20, UINT32_MAX }, { 24, UINT32_MAX },
        { 24, 0 }, { 28, 1 }, { 32, 0x10000 }, { 36, UINT32_MAX },
        { 40, 1 }, { 44, UINT32_MAX }, { 48, 0 }, { 52, 1 }
    };
    unsigned char *copy = malloc(size + 1);
    size_t i;
    uint32_t pool = read32(original + 20);
    size_t products = 32 + (size_t)read32(original + 12) * 16;
    CHECK(copy);
    reject(NULL, size);
    for (i = 0; i < size; ++i)
        reject(original, i);
    for (i = 0; i < ARRAYSIZE(mutations); ++i) {
        memcpy(copy, original, size);
        write32(copy + mutations[i].offset, mutations[i].value);
        reject(copy, size);
    }
    memcpy(copy, original, size);
    copy[size] = 0;
    reject(copy, size + 1);
    memcpy(copy, original, size);
    copy[0] ^= 1;
    reject(copy, size);
    memcpy(copy, original, size);
    copy[pool] = 0xff;
    reject(copy, size);
    memcpy(copy, original, size);
    copy[pool] = 0;
    reject(copy, size);
    memcpy(copy, original, size);
    copy[size - 1] = 'x';
    reject(copy, size);
    memcpy(copy, original, size);
    write32(copy + products, 0x10000);
    reject(copy, size);
    memcpy(copy, original, size);
    write32(copy + products + 4, UINT32_MAX);
    reject(copy, size);
    memcpy(copy, original, size);
    write32(copy + products + 16, 1);
    reject(copy, size);
    memcpy(copy, original, size);
    write32(copy + 32 + 4 * 16 + 12, 0);
    reject(copy, size);
    free(copy);
}

static void check_production(const wchar_t *path)
{
    HMODULE module = LoadLibraryExW(path, NULL,
        LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
    HRSRC resource, notice;
    const unsigned char *bytes;
    UsbIds ids;
    uint32_t i;
    CHECK(module);
    resource = FindResourceW(module, MAKEINTRESOURCEW(IDR_USB_IDS), RT_RCDATA);
    notice = FindResourceW(module, MAKEINTRESOURCEW(IDR_USB_IDS_NOTICE), RT_RCDATA);
    CHECK(resource && notice && SizeofResource(module, notice) > 0);
    bytes = LockResource(LoadResource(module, resource));
    CHECK(usb_ids_open(&ids, bytes, SizeofResource(module, resource)));
    for (i = 0; i < ids.vendor_count; ++i) {
        const unsigned char *v = ids.vendors + (size_t)i * 16;
        uint32_t j, count = read32(v + 12), first = read32(v + 8);
        for (j = 0; j < count; ++j) {
            const unsigned char *p = ids.products + (size_t)(first + j) * 8;
            wchar_t *vendor, *product;
            CHECK(usb_ids_lookup(&ids, read32(v), read32(p), &vendor, &product));
            CHECK(vendor && *vendor && product && *product);
            free(vendor);
            free(product);
        }
    }
    CHECK(FreeLibrary(module));
}

int wmain(int argc, wchar_t **argv)
{
    UsbIds ids;
    HMODULE module = GetModuleHandleW(NULL);
    HRSRC resource = FindResourceW(module, MAKEINTRESOURCEW(IDR_USB_IDS), RT_RCDATA);
    DWORD size;
    const unsigned char *bytes;
    CHECK(resource);
    size = SizeofResource(module, resource);
    bytes = LockResource(LoadResource(module, resource));
    CHECK(bytes);
    CHECK(usb_ids_load(&ids));
    CHECK(ids.vendor_count == 5 && ids.product_count == 5);
    check_lookup(&ids, 0, 0, L"First vendor", L"Zero product");
    check_lookup(&ids, 0x0403, 0x6001, L"Example USB vendor \u65e5\U0001f600",
                 L"Example USB product \u65e5\U0001f600");
    check_lookup(&ids, 0x0403, 1, L"Example USB vendor \u65e5\U0001f600", L"First product");
    check_lookup(&ids, 0x1234, 0x6001, L"Other vendor", L"Other product");
    check_lookup(&ids, 0x5678, 0x6001, L"Vendor without products", NULL);
    check_lookup(&ids, 0xffff, 0xffff, L"Last vendor", L"Last product");
    check_lookup(&ids, 0xffff, 0, L"Last vendor", NULL);
    check_lookup(&ids, 0x0403, 2, L"Example USB vendor \u65e5\U0001f600", NULL);
    check_lookup(&ids, 1, 0x6001, NULL, NULL);
    check_lookup(&ids, 0x10000, 0x6001, NULL, NULL);
    check_lookup(&ids, 0, 0x10000, L"First vendor", NULL);
    check_invalid(bytes, size);
    CHECK(argc == 2);
    check_production(argv[1]);
    puts("USB binary validation and lookup tests passed.");
    return 0;
}
