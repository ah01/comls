#include "ports.h"
#include "output.h"

int port_list_load(PortList *list)
{
    wchar_t scenario[32] = L"";
    Port port = {0};
    GetEnvironmentVariableW(L"COMLS_TEST_SCENARIO", scenario, ARRAYSIZE(scenario));
    if (wcscmp(scenario, L"error") == 0) {
        report_error(L"Synthetic discovery failure", ERROR_ACCESS_DENIED);
        return 0;
    }
    if (wcscmp(scenario, L"empty") == 0)
        return 1;
    if (wcscmp(scenario, L"output-error") == 0) {
        CloseHandle(GetStdHandle(STD_OUTPUT_HANDLE));
        return 1;
    }
    if (wcscmp(scenario, L"compact") == 0) {
        if (!port_set(&port, PORT_NAME, L"COM10") ||
            !port_set(&port, PORT_DESCRIPTION, L"Bluetooth serial port (COM10)"))
            goto failed;
        port.transport = TRANSPORT_BLUETOOTH;
        if (!port_list_add(list, &port))
            goto failed;
        if (!port_set(&port, PORT_NAME, L"COM1") ||
            !port_set(&port, PORT_DESCRIPTION, L"USB Serial Port (COM1)"))
            goto failed;
        port.transport = TRANSPORT_USB;
        if (!port_list_add(list, &port))
            goto failed;
        port_list_sort(list);
        return 1;
    }
    if (wcscmp(scenario, L"suffixes") == 0) {
        static const struct {
            const wchar_t *name;
            const wchar_t *description;
        } cases[] = {
            { L"COM1", L"Serial (COM2)" },
            { L"COM2", L"(COM2) Serial" },
            { L"COM3", L"Serial (COM3) extra" },
            { L"COM4", L"Serial \t(com4) \t" },
            { L"COM5", L"(COM5)" },
            { L"COM6", L"Serial" },
            { L"COM7", L"Serial (COM77)" }
        };
        size_t i;
        for (i = 0; i < ARRAYSIZE(cases); ++i) {
            if (!port_set(&port, PORT_NAME, cases[i].name) ||
                !port_set(&port, PORT_DESCRIPTION, cases[i].description))
                goto failed;
            port.transport = TRANSPORT_USB;
            if (!port_list_add(list, &port))
                goto failed;
        }
        port_list_sort(list);
        return 1;
    }
    if (wcscmp(scenario, L"summary") == 0 || wcscmp(scenario, L"single") == 0) {
        static const struct {
            const wchar_t *name;
            Transport transport;
        } cases[] = {
            { L"COM3", TRANSPORT_NATIVE },
            { L"COM5", TRANSPORT_BLUETOOTH },
            { L"COM7", TRANSPORT_BLUETOOTH },
            { L"COM11", TRANSPORT_USB },
            { L"COM12", TRANSPORT_VIRTUAL },
            { L"COM13", TRANSPORT_UNKNOWN }
        };
        size_t i, count = wcscmp(scenario, L"single") == 0 ? 1 : ARRAYSIZE(cases);
        for (i = 0; i < count; ++i) {
            if (!port_set(&port, PORT_NAME, cases[i].name))
                goto failed;
            port.transport = cases[i].transport;
            if (!port_list_add(list, &port))
                goto failed;
        }
        port_list_sort(list);
        return 1;
    }
    if (!port_set(&port, PORT_NAME, L"COM10") ||
        !port_set(&port, PORT_DESCRIPTION, L"USB serial \u017dlu\u0165ou\u010dk\u00fd \u65e5\u672c \U0001f600 (COM10)") ||
        !port_set(&port, PORT_MANUFACTURER, L"Example manufacturer with a long full name") ||
        !port_set(&port, PORT_USB_DEVICE, L"USB\\VID_0403&PID_6001&MI_02\\EXAMPLE") ||
        !port_set(&port, PORT_INSTANCE, L"USB\\VID_0403&PID_6001&MI_02\\EXAMPLE"))
        goto failed;
    port.transport = TRANSPORT_USB;
    if (!port_list_add(list, &port))
        goto failed;
    if (!port_set(&port, PORT_NAME, L"COM2") ||
        !port_set(&port, PORT_MANUFACTURER, L"1234567890123456789012345\U0001f600"))
        goto failed;
    if (!port_list_add(list, &port))
        goto failed;
    port_list_sort(list);
    return 1;
failed:
    port_clear(&port);
    report_error(L"Creating test fixture", ERROR_NOT_ENOUGH_MEMORY);
    return 0;
}
