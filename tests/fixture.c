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
    if (!port_set(&port, PORT_NAME, L"COM10") ||
        !port_set(&port, PORT_DESCRIPTION, L"USB serial \u017dlu\u0165ou\u010dk\u00fd \u65e5\u672c \U0001f600") ||
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
