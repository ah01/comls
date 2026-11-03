#include "ports.h"
#include "output.h"
#include "usb_ids.h"
#include "usb_ids_metadata.h"

#include <limits.h>
#include <stdlib.h>
#include <wchar.h>
#include <wctype.h>

static const wchar_t help_text[] =
    L"Usage: comls [--verbose | -v] [--help | -h] [--version]\n"
    L"\nList currently present Windows COM ports without opening them.\n"
    L"\n"
    L"  -v, --verbose  Show device and driver details\n"
    L"  -h, --help     Show this help without discovering devices\n"
    L"      --version  Show the version without discovering devices\n"
    L"\n"
    L"Exit codes: 0 = success (including no ports), 1 = error, 2 = invalid arguments.\n";

static const wchar_t *field_text(const Port *port, PortField field)
{
    const wchar_t *text = port->text[field];
    return text && *text ? text : L"Unknown";
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

static int print_ports(HANDLE stream, PortList *list, int verbose)
{
    static const struct {
        const wchar_t *label;
        PortField field;
    } details[] = {
        { L"Description", PORT_DESCRIPTION },
        { L"Manufacturer", PORT_MANUFACTURER },
        { L"Instance ID", PORT_INSTANCE },
        { L"Hardware IDs", PORT_HARDWARE },
        { L"Service", PORT_SERVICE },
        { L"Location", PORT_LOCATION },
        { L"Driver provider", PORT_DRIVER_PROVIDER },
        { L"Driver version", PORT_DRIVER_VERSION },
        { L"Parent instance", PORT_PARENT },
        { L"USB instance", PORT_USB_DEVICE }
    };
    size_t i, field;
    int port_width = 4, type_width = 3;
    if (!verbose && !print_summary(stream, list))
        return 0;
    if (!list->count)
        return verbose ? output_text(stream, L"No COM ports found.\n") : 1;
    for (i = 0; i < list->count; ++i) {
        size_t length = wcslen(list->items[i].text[PORT_NAME]);
        if (length > 64)
            length = 64;
        if ((int)length > port_width)
            port_width = (int)length;
        if (!verbose) {
            int type_length = (int)wcslen(compact_transport_name(list->items[i].transport));
            if (type_length > type_width)
                type_width = type_length;
        }
    }
    if (!verbose) {
        for (i = 0; i < list->count; ++i) {
            const Port *port = &list->items[i];
            const wchar_t *type = compact_transport_name(port->transport);
            size_t description_length = compact_description_length(port);
            if (description_length > INT_MAX) {
                SetLastError(ERROR_NOT_ENOUGH_MEMORY);
                return 0;
            }
            if (!output_format(stream, L"%-*ls  (%ls)%*ls %.*ls\n",
                               port_width, field_text(port, PORT_NAME), type,
                               type_width - (int)wcslen(type), L"",
                               (int)description_length, field_text(port, PORT_DESCRIPTION)))
                return 0;
        }
        return 1;
    }
    if (!output_format(stream, L"%-*ls  %-9ls  %-26ls  %ls\n",
                       port_width, L"PORT", L"TYPE", L"MANUFACTURER", L"DESCRIPTION"))
        return 0;
    for (i = 0; i < list->count; ++i) {
        const Port *port = &list->items[i];
        const wchar_t *manufacturer = field_text(port, PORT_MANUFACTURER);
        int precision = 26;
        if (wcslen(manufacturer) > 26 && manufacturer[25] >= 0xD800 &&
            manufacturer[25] <= 0xDBFF && manufacturer[26] >= 0xDC00 &&
            manufacturer[26] <= 0xDFFF)
            precision = 25;
        if (!output_format(stream, L"%-*ls  %-9ls  %-26.*ls  %ls\n",
                           port_width, field_text(port, PORT_NAME),
                           transport_name(port->transport),
                           precision, manufacturer,
                           field_text(port, PORT_DESCRIPTION)))
            return 0;
    }
    for (i = 0; i < list->count; ++i) {
        const Port *port = &list->items[i];
        unsigned vid, pid, interface_number;
        if (!output_format(stream, L"\n%ls\n  %-16ls %ls\n",
                           field_text(port, PORT_NAME), L"Type:",
                           transport_name(port->transport)))
            return 0;
        for (field = 0; field < ARRAYSIZE(details); ++field) {
            if (!output_format(stream, L"  %-16ls %ls\n",
                               details[field].label, field_text(port, details[field].field)))
                return 0;
        }
        if (usb_identifiers(port->text[PORT_USB_DEVICE], &vid, &pid)) {
            if (!output_format(stream, L"  %-16ls %04X:%04X\n", L"USB VID:PID", vid, pid))
                return 0;
            if (port->transport == TRANSPORT_USB &&
                (!output_format(stream, L"  %-16ls %ls\n", L"USB vendor",
                                field_text(port, PORT_USB_VENDOR)) ||
                 !output_format(stream, L"  %-16ls %ls\n", L"USB product",
                                field_text(port, PORT_USB_PRODUCT))))
                return 0;
            if (usb_interface(port->text[PORT_USB_DEVICE], &interface_number) &&
                !output_format(stream, L"  %-16ls %02X\n", L"USB interface", interface_number))
                return 0;
        }
    }
    return 1;
}

int wmain(int argc, wchar_t **argv)
{
    PortList list = {0};
    HANDLE stream = GetStdHandle(STD_OUTPUT_HANDLE);
    int i, verbose = 0, help = 0, version = 0, printed;
    for (i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--verbose") == 0 || wcscmp(argv[i], L"-v") == 0)
            verbose = 1;
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
        if (!port_list_load(&list) || (verbose && !add_usb_names(&list))) {
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
