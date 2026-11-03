#include "ports.h"
#include "output.h"
#include "usb_ids.h"
#include "usb_ids_metadata.h"

#include <limits.h>
#include <stdlib.h>
#include <wchar.h>
#include <wctype.h>

static const wchar_t help_text[] =
    L"Usage: comls [--usb-only | -u] [--sort-by-time | -t] [--verbose | -v | -d | -vv] [--help | -h] [--version]\n"
    L"\nList currently present Windows COM ports without opening them.\n"
    L"\n"
    L"  -v, --verbose  Show common device details\n"
    L"  -d            Alias for -v (details)\n"
    L"  -vv           Show all device and driver details (or repeat -v)\n"
    L"  -u, --usb-only Show only ports classified as USB\n"
    L"  -t, --sort-by-time Sort by last arrival, newest first (unknown times last)\n"
    L"  -h, --help     Show this help without discovering devices\n"
    L"      --version  Show the version without discovering devices\n"
    L"\nCompact output groups ports that arrived within the last 5 minutes.\n"
    L"Verbose output includes the last arrival in local time and its relative age.\n"
    L"\n"
    L"Exit codes: 0 = success (including no ports), 1 = error, 2 = invalid arguments.\n";

static const wchar_t *field_text(const Port *port, PortField field)
{
    const wchar_t *text = port->text[field];
    return text && *text ? text : L"Unknown";
}

static void keep_usb_ports(PortList *list)
{
    size_t i, kept = 0;
    for (i = 0; i < list->count; ++i) {
        Port *port = &list->items[i];
        if (port->transport != TRANSPORT_USB) {
            port_clear(port);
            continue;
        }
        if (kept != i) {
            list->items[kept] = *port;
            *port = (Port){0};
        }
        ++kept;
    }
    list->count = kept;
}

static int add_usb_names(PortList *list)
{
    UsbIds ids = {0};
    int loaded = 0;
    size_t i;
    for (i = 0; i < list->count; ++i) {
        Port *port = &list->items[i];
        unsigned vid, pid;
        if (port->transport != TRANSPORT_USB ||
            !usb_identifiers(port->text[PORT_USB_DEVICE], &vid, &pid))
            continue;
        if (!loaded) {
            if (!usb_ids_load(&ids)) {
                report_error(L"Loading embedded USB database", GetLastError());
                usb_ids_close(&ids);
                return 0;
            }
            loaded = 1;
        }
        if (!usb_ids_lookup(&ids, vid, pid, &port->text[PORT_USB_VENDOR],
                            &port->text[PORT_USB_PRODUCT])) {
            report_error(L"Looking up USB names", GetLastError());
            usb_ids_close(&ids);
            return 0;
        }
    }
    usb_ids_close(&ids);
    return 1;
}

static const wchar_t *compact_transport_name(Transport transport)
{
    return transport == TRANSPORT_BLUETOOTH ? L"BL" : transport_name(transport);
}

static OutputColor transport_color(Transport transport)
{
    return transport == TRANSPORT_BLUETOOTH ? OUTPUT_BLUE :
        transport == TRANSPORT_USB ? OUTPUT_YELLOW : OUTPUT_DEFAULT;
}

static int print_detail_label(HANDLE stream, const wchar_t *label)
{
    return output_color_format(stream, OUTPUT_GRAY, L"  %ls:%*ls",
                               label, 16 - (int)wcslen(label), L"");
}

static int print_detail(HANDLE stream, const wchar_t *label,
                        const wchar_t *value, OutputColor color)
{
    return print_detail_label(stream, label) &&
        output_color_format(stream, color, L"%ls\n", value);
}

static size_t compact_description_length(const Port *port)
{
    const wchar_t *description = field_text(port, PORT_DESCRIPTION);
    const wchar_t *name = field_text(port, PORT_NAME);
    size_t length = wcslen(description), end = length, name_length = wcslen(name);
    while (end && iswspace(description[end - 1]))
        --end;
    if (end < name_length + 2 || description[end - 1] != L')' ||
        description[end - name_length - 2] != L'(' ||
        _wcsnicmp(description + end - name_length - 1, name, name_length) != 0)
        return length;
    end -= name_length + 2;
    while (end && iswspace(description[end - 1]))
        --end;
    return end;
}

static const wchar_t *known_field_text(const Port *port, PortField field)
{
    const wchar_t *text = port->text[field];
    return text && *text && _wcsicmp(text, L"Unknown") != 0 ? text : NULL;
}

static int print_compact_details(HANDLE stream, const Port *port)
{
    const wchar_t *manufacturer = known_field_text(port, PORT_MANUFACTURER);
    const wchar_t *vendor = NULL, *product = NULL;
    if (manufacturer && _wcsicmp(manufacturer, L"Microsoft") == 0)
        manufacturer = NULL;
    if (port->transport == TRANSPORT_USB) {
        vendor = known_field_text(port, PORT_USB_VENDOR);
        product = known_field_text(port, PORT_USB_PRODUCT);
    }
    if (!manufacturer && !vendor && !product)
        return 1;
    return output_color_format(stream, OUTPUT_GRAY, L" [%ls%ls%ls%ls%ls%ls]",
                               manufacturer ? manufacturer : L"",
                               manufacturer && (vendor || product) ? L", " : L"",
                               vendor || product ? L"USB: " : L"",
                               vendor ? vendor : L"",
                               vendor && product ? L" / " : L"",
                               product ? product : L"");
}

static int print_summary(HANDLE stream, const PortList *list)
{
    struct {
        Transport transport;
        const wchar_t *label;
        size_t count;
    } types[] = {
        { TRANSPORT_NATIVE, L"native", 0 },
        { TRANSPORT_BLUETOOTH, L"bluetooth", 0 },
        { TRANSPORT_USB, L"USB", 0 },
        { TRANSPORT_VIRTUAL, L"virtual", 0 },
        { TRANSPORT_UNKNOWN, L"unknown", 0 }
    };
    size_t i, type;
    int first = 1;
    for (i = 0; i < list->count; ++i) {
        for (type = 0; type < ARRAYSIZE(types); ++type) {
            if (list->items[i].transport == types[type].transport) {
                ++types[type].count;
                break;
            }
        }
    }
    if (!output_format(stream, L"Found %zu %ls", list->count,
                       list->count == 1 ? L"port" : L"ports"))
        return 0;
    for (type = 0; type < ARRAYSIZE(types); ++type) {
        if (!types[type].count)
            continue;
        if (!output_format(stream, L"%ls%zu %ls", first ? L" (" : L", ",
                           types[type].count, types[type].label))
            return 0;
        first = 0;
    }
    return output_text(stream, first ? L":\n\n" : L"):\n\n");
}

#ifdef COMLS_TEST_FIXTURE
uint64_t fixture_reference_time(void);
#endif

static uint64_t output_reference_time(void)
{
#ifdef COMLS_TEST_FIXTURE
    return fixture_reference_time();
#else
    FILETIME time;
    GetSystemTimeAsFileTime(&time);
    return ((uint64_t)time.dwHighDateTime << 32) | time.dwLowDateTime;
#endif
}

typedef struct {
    uint64_t amount;
    const wchar_t *unit;
    const wchar_t *compact_unit;
} ArrivalAge;

static ArrivalAge arrival_age(const Port *port, uint64_t now)
{
    uint64_t seconds = (port->last_arrival > now ?
                        port->last_arrival - now : now - port->last_arrival) /
        UINT64_C(10000000);
    if (seconds < 60)
        return (ArrivalAge){ seconds, L"second", L"s" };
    if (seconds < 3600)
        return (ArrivalAge){ seconds / 60, L"minute", L"min" };
    if (seconds < 86400)
        return (ArrivalAge){ seconds / 3600, L"hour", L"h" };
    return (ArrivalAge){ seconds / 86400, L"day", L"d" };
}

static int print_arrival(HANDLE stream, const Port *port, uint64_t now)
{
    FILETIME utc_time;
    SYSTEMTIME utc, local;
    ArrivalAge age;
    int future = port->last_arrival > now;
    if (!port->has_last_arrival)
        return print_detail(stream, L"Last arrival", L"Unknown", OUTPUT_DEFAULT);
    utc_time.dwHighDateTime = (DWORD)(port->last_arrival >> 32);
    utc_time.dwLowDateTime = (DWORD)port->last_arrival;
    if (!FileTimeToSystemTime(&utc_time, &utc) ||
        !SystemTimeToTzSpecificLocalTimeEx(NULL, &utc, &local))
        return 0;
    age = arrival_age(port, now);
    if (!print_detail_label(stream, L"Last arrival") ||
        !output_format(stream, L"%04u-%02u-%02u %02u:%02u:%02u (",
                       (unsigned)local.wYear, (unsigned)local.wMonth, (unsigned)local.wDay,
                       (unsigned)local.wHour, (unsigned)local.wMinute, (unsigned)local.wSecond))
        return 0;
    if (!age.amount)
        return output_text(stream, future ? L"in less than a second)\n" : L"just now)\n");
    return output_format(stream, L"%ls%llu %ls%ls%ls)\n",
                         future ? L"in " : L"", (unsigned long long)age.amount,
                         age.unit, age.amount == 1 ? L"" : L"s", future ? L"" : L" ago");
}

static int print_compact_age(HANDLE stream, const Port *port, uint64_t now)
{
    ArrivalAge age;
    if (!port->has_last_arrival)
        return 1;
    age = arrival_age(port, now);
    return output_color_format(stream, OUTPUT_AQUA, L" %lc%llu %ls",
                               port->last_arrival > now ? L'-' : L'+',
                               (unsigned long long)age.amount, age.compact_unit);
}

static int print_compact_port(HANDLE stream, const Port *port,
                              int port_width, int type_width, uint64_t now)
{
    const wchar_t *type = compact_transport_name(port->transport);
    size_t description_length = compact_description_length(port);
    if (description_length > INT_MAX) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return 0;
    }
    return output_format(stream, L"%-*ls  ", port_width, field_text(port, PORT_NAME)) &&
        output_color_format(stream, transport_color(port->transport), L"(%ls)", type) &&
        output_format(stream, L"%*ls %.*ls", type_width - (int)wcslen(type), L"",
                      (int)description_length, field_text(port, PORT_DESCRIPTION)) &&
        print_compact_details(stream, port) && print_compact_age(stream, port, now) &&
        output_text(stream, L"\n");
}

static int print_ports(HANDLE stream, PortList *list, int verbose)
{
    static const struct {
        const wchar_t *label;
        PortField field;
        int full_only;
    } details[] = {
        { L"Description", PORT_DESCRIPTION, 0 },
        { L"Manufacturer", PORT_MANUFACTURER, 0 },
        { L"Instance ID", PORT_INSTANCE, 1 },
        { L"Hardware IDs", PORT_HARDWARE, 1 },
        { L"Service", PORT_SERVICE, 1 },
        { L"Location", PORT_LOCATION, 1 },
        { L"Driver provider", PORT_DRIVER_PROVIDER, 1 },
        { L"Driver version", PORT_DRIVER_VERSION, 1 },
        { L"Parent instance", PORT_PARENT, 1 },
        { L"USB instance", PORT_USB_DEVICE, 1 }
    };
    size_t i, field;
    uint64_t now = output_reference_time();
    int port_width = 4, type_width = 3;
    if (!print_summary(stream, list))
        return 0;
    if (!list->count)
        return 1;
    if (!verbose) {
        size_t recent = 0;
        int group, groups;
        for (i = 0; i < list->count; ++i) {
            size_t length = wcslen(list->items[i].text[PORT_NAME]);
            int type_length = (int)wcslen(compact_transport_name(list->items[i].transport));
            if (length > 64)
                length = 64;
            if ((int)length > port_width)
                port_width = (int)length;
            if (type_length > type_width)
                type_width = type_length;
            if (port_is_recent(&list->items[i], now))
                ++recent;
        }
        groups = recent && recent < list->count ? 2 : 1;
        for (group = 0; group < groups; ++group) {
            if (recent && !output_color_format(stream, OUTPUT_GRAY, L"%ls", group == 0 ?
                                      L"Recent (last 5 minutes):\n" : L"\nRest:\n"))
                return 0;
            for (i = 0; i < list->count; ++i) {
                const Port *port = &list->items[i];
                if (recent && port_is_recent(port, now) != (group == 0))
                    continue;
                if (!print_compact_port(stream, port, port_width, type_width, now))
                    return 0;
            }
        }
        return 1;
    }
    for (i = 0; i < list->count; ++i) {
        const Port *port = &list->items[i];
        unsigned vid, pid, interface_number;
        if (!output_format(stream, L"%ls%ls\n", i ? L"\n" : L"", field_text(port, PORT_NAME)) ||
            !print_detail(stream, L"Type", transport_name(port->transport),
                          transport_color(port->transport)) ||
            !print_arrival(stream, port, now))
            return 0;
        for (field = 0; field < ARRAYSIZE(details); ++field) {
            if (details[field].full_only && verbose < 2)
                continue;
            if (!print_detail(stream, details[field].label,
                              field_text(port, details[field].field), OUTPUT_DEFAULT))
                return 0;
        }
        if (usb_identifiers(port->text[PORT_USB_DEVICE], &vid, &pid)) {
            int show_ids = verbose >= 2 || port->transport != TRANSPORT_USB ||
                !known_field_text(port, PORT_USB_VENDOR) ||
                !known_field_text(port, PORT_USB_PRODUCT);
            if (show_ids && (!print_detail_label(stream, L"USB VID:PID") ||
                            !output_format(stream, L"%04X:%04X\n", vid, pid)))
                return 0;
            if (port->transport == TRANSPORT_USB &&
                (!print_detail(stream, L"USB vendor", field_text(port, PORT_USB_VENDOR),
                               OUTPUT_DEFAULT) ||
                 !print_detail(stream, L"USB product", field_text(port, PORT_USB_PRODUCT),
                               OUTPUT_DEFAULT)))
                return 0;
            if (usb_interface(port->text[PORT_USB_DEVICE], &interface_number) &&
                (!print_detail_label(stream, L"USB interface") ||
                 !output_format(stream, L"%02X\n", interface_number)))
                return 0;
        }
    }
    return 1;
}

int wmain(int argc, wchar_t **argv)
{
    PortList list = {0};
    HANDLE stream = GetStdHandle(STD_OUTPUT_HANDLE);
    int i, verbose = 0, usb_only = 0, sort_by_time = 0, help = 0, version = 0, printed;
    for (i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--verbose") == 0 || wcscmp(argv[i], L"-v") == 0 ||
            wcscmp(argv[i], L"-d") == 0) {
            if (verbose < 2)
                ++verbose;
        } else if (wcscmp(argv[i], L"-vv") == 0)
            verbose = 2;
        else if (wcscmp(argv[i], L"--usb-only") == 0 || wcscmp(argv[i], L"-u") == 0)
            usb_only = 1;
        else if (wcscmp(argv[i], L"--sort-by-time") == 0 || wcscmp(argv[i], L"-t") == 0)
            sort_by_time = 1;
        else if (wcscmp(argv[i], L"--help") == 0 || wcscmp(argv[i], L"-h") == 0)
            help = 1;
        else if (wcscmp(argv[i], L"--version") == 0)
            version = 1;
        else {
            output_text(GetStdHandle(STD_ERROR_HANDLE),
                        L"comls: Invalid argument. Use --help for usage.\n");
            return 2;
        }
    }
    if (help)
        printed = output_text(stream, help_text);
    else if (version)
        printed = output_text(stream, L"comls " COMLS_VERSION
                              L"\n\nUSB vendor and product ID sources:\n"
                              L"  usb.ids: " COMLS_USB_IDS_DATE
                              L"\n  raspberrypi/usb-pid: " COMLS_RASPBERRY_PI_DATE
                              L" (" COMLS_RASPBERRY_PI_COMMIT L")\n");
    else {
        if (!port_list_load(&list)) {
            port_list_clear(&list);
            return 1;
        }
        if (usb_only)
            keep_usb_ports(&list);
        if (sort_by_time)
            port_list_sort_by_time(&list);
        if (!add_usb_names(&list)) {
            port_list_clear(&list);
            return 1;
        }
        printed = print_ports(stream, &list, verbose);
        port_list_clear(&list);
    }
    if (!printed) {
        report_error(L"Writing standard output", GetLastError());
        return 1;
    }
    return 0;
}
