#include "usb_ids.h"
#include "resource.h"

#include <windows.h>
#include <compressapi.h>
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

static unsigned char *pack(const void *data, size_t size, size_t *packed_size)
{
    COMPRESSOR_HANDLE compressor;
    SIZE_T needed;
    unsigned char *packed;
    CHECK(CreateCompressor(COMPRESS_ALGORITHM_MSZIP, NULL, &compressor));
    CHECK(!Compress(compressor, data, size, NULL, 0, &needed));
    CHECK(GetLastError() == ERROR_INSUFFICIENT_BUFFER);
    packed = malloc(needed);
    CHECK(packed);
    CHECK(Compress(compressor, data, size, packed, needed, packed_size));
    CHECK(CloseCompressor(compressor));
    return packed;
}

static void reject_packed(const unsigned char *bytes, size_t size)
{
    UsbIds ids;
    SetLastError(ERROR_SUCCESS);
    CHECK(!usb_ids_unpack(&ids, bytes, size));
    CHECK(GetLastError() != ERROR_SUCCESS);
    CHECK(!ids.vendors && !ids.products && !ids.strings && !ids.allocation);
    CHECK(!ids.vendor_count && !ids.product_count && !ids.strings_size);
    usb_ids_close(&ids);
    usb_ids_close(&ids);
}

static void reject(const unsigned char *bytes, size_t size)
{
    UsbIds ids;
    SetLastError(ERROR_SUCCESS);
    CHECK(!usb_ids_open(&ids, bytes, size));
    CHECK(GetLastError() == ERROR_INVALID_DATA);
    CHECK(!ids.vendors && !ids.products && !ids.strings && !ids.vendor_count);
    usb_ids_close(&ids);
    if (bytes && size) {
        size_t packed_size;
        unsigned char *packed = pack(bytes, size, &packed_size);
        reject_packed(packed, packed_size);
        free(packed);
    }
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

static void check_compression(const unsigned char *packed, size_t packed_size)
{
    unsigned char *copy = malloc(packed_size);
    unsigned char *large, *encoded;
    UsbIds oversized;
    size_t i, encoded_size;
    const uint32_t large_size = 64 * 1024 * 1024 + 1;
    CHECK(copy);
    reject_packed(NULL, packed_size);
    for (i = 0; i < packed_size; ++i)
        reject_packed(packed, i);
    memcpy(copy, packed, packed_size);
    copy[0] ^= 1;
    reject_packed(copy, packed_size);
    memset(copy, 0, packed_size);
    reject_packed(copy, packed_size);
    free(copy);

    large = malloc(large_size);
    CHECK(large);
    memset(large, 0, 58);
    memcpy(large, "CUSBIDS\0", 8);
    write32(large + 8, 1);
    write32(large + 12, 1);
    write32(large + 16, 1);
    write32(large + 20, 56);
    write32(large + 24, large_size - 56);
    write32(large + 44, 1);
    write32(large + 52, 2);
    large[56] = 'V';
    memset(large + 58, 'P', large_size - 59);
    large[large_size - 1] = 0;
    CHECK(usb_ids_open(&oversized, large, large_size));
    usb_ids_close(&oversized);
    encoded = pack(large, large_size, &encoded_size);
    reject_packed(encoded, encoded_size);
    free(encoded);
    free(large);
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
    notice = FindResourceW(module, MAKEINTRESOURCEW(IDR_RASPBERRY_PI_NOTICE), RT_RCDATA);
    CHECK(notice && SizeofResource(module, notice) > 0);
    bytes = LockResource(LoadResource(module, resource));
    CHECK(usb_ids_unpack(&ids, bytes, SizeofResource(module, resource)));
    CHECK(ids.allocation);
    check_lookup(&ids, 0x2e8a, 0x0003, L"Raspberry Pi", L"Raspberry Pi RP2040 boot");
    check_lookup(&ids, 0x2e8a, 0x1000, L"Raspberry Pi", L"Cytron Maker Pi RP2040");
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
    usb_ids_close(&ids);
    CHECK(FreeLibrary(module));
}

int wmain(int argc, wchar_t **argv)
{
    UsbIds ids;
    HMODULE module = GetModuleHandleW(NULL);
    HRSRC resource = FindResourceW(module, MAKEINTRESOURCEW(IDR_USB_IDS), RT_RCDATA);
    DWORD size;
    const unsigned char *bytes;
    const unsigned char *raw;
    size_t raw_size;
    unsigned i;
    wchar_t *vendor, *product;
    CHECK(resource);
    size = SizeofResource(module, resource);
    bytes = LockResource(LoadResource(module, resource));
    CHECK(bytes);
    CHECK(usb_ids_load(&ids));
    CHECK(ids.allocation);
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
    raw = ids.vendors - 32;
    raw_size = 32 + (size_t)ids.vendor_count * 16 +
        (size_t)ids.product_count * 8 + ids.strings_size;
    {
        UsbIds borrowed;
        CHECK(usb_ids_open(&borrowed, raw, raw_size));
        CHECK(!borrowed.allocation);
        usb_ids_close(&borrowed);
    }
    check_invalid(raw, raw_size);
    check_compression(bytes, size);
    CHECK(usb_ids_lookup(&ids, 0xffff, 0xffff, &vendor, &product));
    usb_ids_close(&ids);
    CHECK(!ids.vendors && !ids.products && !ids.strings && !ids.allocation);
    CHECK(!ids.vendor_count && !ids.product_count && !ids.strings_size);
    CHECK(wcscmp(vendor, L"Last vendor") == 0 && wcscmp(product, L"Last product") == 0);
    free(vendor);
    free(product);
    usb_ids_close(&ids);
    for (i = 0; i < 10; ++i) {
        CHECK(usb_ids_load(&ids));
        check_lookup(&ids, 0x1234, 0x6001, L"Other vendor", L"Other product");
        usb_ids_close(&ids);
    }
    CHECK(argc == 2);
    check_production(argv[1]);
    puts("USB MSZIP decompression, binary validation, and lookup tests passed.");
    return 0;
}
