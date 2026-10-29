#include "ports.h"
#include "output.h"

#include <stdlib.h>
#include <wchar.h>

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
    int port_width = 4;
    if (!list->count)
        return output_text(stream, L"No COM ports found.\n");
    for (i = 0; i < list->count; ++i) {
        size_t length = wcslen(list->items[i].text[PORT_NAME]);
        if (length > 64)
            length = 64;
        if ((int)length > port_width)
            port_width = (int)length;
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
    if (!verbose)
        return 1;
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
        printed = output_text(stream, L"comls " COMLS_VERSION L"\n");
    else {
        if (!port_list_load(&list)) {
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
