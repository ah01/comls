#include "ports.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expression) do { \
    if (!(expression)) { \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); \
        exit(1); \
    } \
} while (0)

static void check_names(void)
{
    CHECK(port_name_valid(L"COM1"));
    CHECK(port_name_valid(L"com10"));
    CHECK(port_name_valid(L"COM4294967296000000000000"));
    CHECK(!port_name_valid(NULL));
    CHECK(!port_name_valid(L""));
    CHECK(!port_name_valid(L"C"));
    CHECK(!port_name_valid(L"COM"));
    CHECK(!port_name_valid(L"COM0"));
    CHECK(!port_name_valid(L"COM01"));
    CHECK(!port_name_valid(L"COM-1"));
    CHECK(!port_name_valid(L"COM3junk"));
    CHECK(!port_name_valid(L"COM3:"));
    CHECK(!port_name_valid(L" COM3"));
    CHECK(!port_name_valid(L"LPT1"));
}

static void check_list(void)
{
    static const wchar_t *names[] = {
        L"COM10", L"COM2", L"COM1", L"COM100",
        L"COM4294967296000000000000"
    };
    PortList list = {0};
    Port port = {0};
    size_t i;
    for (i = 0; i < sizeof(names) / sizeof(*names); ++i) {
        CHECK(port_set(&port, PORT_NAME, names[i]));
        CHECK(port_list_add(&list, &port));
        CHECK(port.text[PORT_NAME] == NULL);
    }
    CHECK(port_set(&port, PORT_NAME, L"com2"));
    CHECK(port_set(&port, PORT_MANUFACTURER, L"Example manufacturer"));
    port.transport = TRANSPORT_USB;
    CHECK(port_list_add(&list, &port));
    CHECK(list.count == 5);
    port_list_sort(&list);
    CHECK(wcscmp(list.items[0].text[PORT_NAME], L"COM1") == 0);
    CHECK(wcscmp(list.items[1].text[PORT_NAME], L"COM2") == 0);
    CHECK(wcscmp(list.items[2].text[PORT_NAME], L"COM10") == 0);
    CHECK(wcscmp(list.items[3].text[PORT_NAME], L"COM100") == 0);
    CHECK(wcscmp(list.items[4].text[PORT_NAME], L"COM4294967296000000000000") == 0);
    CHECK(list.items[1].transport == TRANSPORT_USB);
    CHECK(wcscmp(list.items[1].text[PORT_MANUFACTURER], L"Example manufacturer") == 0);
    CHECK(list.items[1].text[PORT_DESCRIPTION] == NULL);
    CHECK(port_set(&port, PORT_NAME, L"COM2"));
    CHECK(port_set(&port, PORT_DESCRIPTION, L"More metadata"));
    CHECK(port_list_add(&list, &port));
    CHECK(list.items[1].transport == TRANSPORT_USB);
    CHECK(wcscmp(list.items[1].text[PORT_DESCRIPTION], L"More metadata") == 0);
    CHECK(port_set(&port, PORT_NAME, L"LPT1"));
    CHECK(!port_list_add(&list, &port));
    port_clear(&port);
    port_list_clear(&list);
    CHECK(list.count == 0 && list.items == NULL);
    port_list_sort(&list);
    port_list_clear(&list);
}

static void check_transports(void)
{
    Port port = {0};
    port_observe(&port, L"BTHENUM\\{SPP}\\DEVICE", 0);
    port_observe(&port, L"USB\\VID_8087&PID_0033\\RADIO", 1);
    port_observe(&port, L"PCI\\VEN_8086&DEV_1234\\0", 3);
    CHECK(port.transport == TRANSPORT_BLUETOOTH);
    memset(&port, 0, sizeof(port));
    port_observe(&port, L"FTDIBUS\\VID_0403+PID_6001\\0000", 0);
    CHECK(port.transport == TRANSPORT_UNKNOWN);
    port_observe(&port, L"usb\\vid_0403&pid_6001\\EXAMPLE", 1);
    CHECK(port.transport == TRANSPORT_USB);
    port_observe(&port, L"PCI\\VEN_8086\\0", 2);
    CHECK(port.transport == TRANSPORT_USB);
    memset(&port, 0, sizeof(port));
    port_observe(&port, L"PCI\\VEN_8086&DEV_1234\\0", 0);
    CHECK(port.transport == TRANSPORT_NATIVE);
    memset(&port, 0, sizeof(port));
    port_observe(&port, L"ACPI\\PNP0501\\0", 0);
    CHECK(port.transport == TRANSPORT_NATIVE);
    memset(&port, 0, sizeof(port));
    port_observe(&port, L"ROOT\\SOME_VENDOR\\0000", 0);
    port_observe(&port, L"ACPI\\PNP0A08\\0", 1);
    port_observe(&port, L"PCI\\VEN_1234\\0", 2);
    CHECK(port.transport == TRANSPORT_UNKNOWN);
    port_observe(&port, NULL, 0);
    CHECK(port.transport == TRANSPORT_UNKNOWN);
    port_observe(&port, L"ROOT\\COM0COM\\0000", 0);
    CHECK(port.transport == TRANSPORT_VIRTUAL);
    port_observe(&port, L"USB\\VID_1234&PID_5678\\0", 1);
    CHECK(port.transport == TRANSPORT_VIRTUAL);
    CHECK(wcscmp(transport_name(TRANSPORT_UNKNOWN), L"Unknown") == 0);
    CHECK(wcscmp(transport_name(TRANSPORT_NATIVE), L"Native") == 0);
    CHECK(wcscmp(transport_name(TRANSPORT_USB), L"USB") == 0);
    CHECK(wcscmp(transport_name(TRANSPORT_VIRTUAL), L"Virtual") == 0);
    CHECK(wcscmp(transport_name(TRANSPORT_BLUETOOTH), L"Bluetooth") == 0);
}

static void check_usb(void)
{
    unsigned vid = 0, pid = 0, number = 0;
    CHECK(usb_identifiers(L"USB\\VID_0403&PID_60a1&MI_02\\EXAMPLE", &vid, &pid));
    CHECK(vid == 0x0403 && pid == 0x60A1);
    CHECK(usb_interface(L"USB\\VID_0403&PID_60A1&MI_02\\EXAMPLE", &number));
    CHECK(number == 2);
    CHECK(!usb_identifiers(NULL, &vid, &pid));
    CHECK(!usb_identifiers(L"USB\\VID_123&PID_5678\\0", &vid, &pid));
    CHECK(!usb_identifiers(L"USB\\VID_12345&PID_5678\\0", &vid, &pid));
    CHECK(!usb_identifiers(L"USB\\VID_ZZZZ&PID_5678\\0", &vid, &pid));
    CHECK(!usb_identifiers(L"USB\\DEVICE\\VID_1234&PID_5678", &vid, &pid));
    CHECK(!usb_identifiers(L"USB\\NOTVID_1234&PID_5678\\0", &vid, &pid));
    CHECK(!usb_identifiers(L"PCI\\VID_1234&PID_5678\\0", &vid, &pid));
    CHECK(!usb_interface(L"USB\\VID_1234&PID_5678&MI_\\0", &number));
    CHECK(!usb_interface(L"USB\\VID_1234&PID_5678&MI_012\\0", &number));
    CHECK(!usb_interface(L"USB\\VID_1234&PID_5678\\MI_01", &number));
    CHECK(!usb_interface(L"", &number));
}

int main(void)
{
    check_names();
    check_list();
    check_transports();
    check_usb();
    puts("Port unit tests passed.");
    return 0;
}
