#include "ports.h"
#include "output.h"

#include <initguid.h>
#include <devguid.h>
#include <devpkey.h>
#include <ntddser.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <stdlib.h>

typedef struct {
    PortList *list;
    int ok;
} Discovery;

static void failure(Discovery *discovery, const wchar_t *context, DWORD error)
{
    discovery->ok = 0;
    report_error(context, error);
}

static int missing_property(CONFIGRET status)
{
    return status == CR_NO_SUCH_VALUE || status == CR_NO_SUCH_DEVNODE;
}

static wchar_t *device_text(Discovery *discovery, DEVINST device,
                            const DEVPROPKEY *key)
{
    DEVPROPTYPE type;
    CONFIGRET status;
    ULONG bytes = 0;
    wchar_t *text;
    unsigned attempt;
    status = CM_Get_DevNode_PropertyW(device, key, &type, NULL, &bytes, 0);
    if (missing_property(status))
        return NULL;
    if (status != CR_BUFFER_SMALL) {
        if (status != CR_SUCCESS)
            failure(discovery, L"Reading device property",
                    CM_MapCrToWin32Err(status, ERROR_GEN_FAILURE));
        return NULL;
    }
    for (attempt = 0; attempt < 3; ++attempt) {
        ULONG allocated = bytes;
        text = calloc((size_t)allocated + 2 * sizeof(wchar_t), 1);
        if (!text) {
            failure(discovery, L"Allocating device property", ERROR_NOT_ENOUGH_MEMORY);
            return NULL;
        }
        status = CM_Get_DevNode_PropertyW(device, key, &type,
                                         (PBYTE)text, &bytes, 0);
        if (status == CR_BUFFER_SMALL) {
            free(text);
            continue;
        }
        if (status != CR_SUCCESS) {
            free(text);
            if (!missing_property(status))
                failure(discovery, L"Reading device property",
                        CM_MapCrToWin32Err(status, ERROR_GEN_FAILURE));
            return NULL;
        }
        if (bytes > allocated || bytes % sizeof(wchar_t) ||
            (type != DEVPROP_TYPE_STRING && type != DEVPROP_TYPE_STRING_LIST)) {
            free(text);
            failure(discovery, L"Invalid device string property", ERROR_INVALID_DATA);
            return NULL;
        }
        if (type == DEVPROP_TYPE_STRING_LIST) {
            size_t i;
            for (i = 0; i + 1 < bytes / sizeof(wchar_t); ++i) {
                if (!text[i]) {
                    if (!text[i + 1])
                        break;
                    text[i] = L';';
                }
            }
        }
        return text;
    }
    failure(discovery, L"Device property kept changing", ERROR_MORE_DATA);
    return NULL;
}

static wchar_t *registry_text(Discovery *discovery, HKEY key, const wchar_t *name)
{
    DWORD bytes = 0, type;
    LSTATUS status;
    wchar_t *text;
    status = RegQueryValueExW(key, name, NULL, &type, NULL, &bytes);
    if (status == ERROR_FILE_NOT_FOUND || status == ERROR_KEY_DELETED)
        return NULL;
    if (status != ERROR_SUCCESS) {
        failure(discovery, L"Reading port registry value", (DWORD)status);
        return NULL;
    }
    text = calloc((size_t)bytes + sizeof(wchar_t), 1);
    if (!text) {
        failure(discovery, L"Allocating registry value", ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    status = RegQueryValueExW(key, name, NULL, &type, (BYTE *)text, &bytes);
    if (status != ERROR_SUCCESS || type != REG_SZ || bytes % sizeof(wchar_t)) {
        free(text);
        if (status != ERROR_FILE_NOT_FOUND && status != ERROR_KEY_DELETED)
            failure(discovery, L"Reading port name",
                    status == ERROR_SUCCESS ? ERROR_INVALID_DATA : (DWORD)status);
        return NULL;
    }
    return text;
}

static void read_last_arrival(Discovery *discovery, DEVINST device, Port *port)
{
    FILETIME time;
    DEVPROPTYPE type;
    ULONG bytes = sizeof(time);
    CONFIGRET status = CM_Get_DevNode_PropertyW(
        device, &DEVPKEY_Device_LastArrivalDate, &type, (PBYTE)&time, &bytes, 0);
    if (missing_property(status))
        return;
    if (status != CR_SUCCESS) {
        failure(discovery, L"Reading device last arrival",
                CM_MapCrToWin32Err(status, ERROR_GEN_FAILURE));
        return;
    }
    if (type != DEVPROP_TYPE_FILETIME || bytes != sizeof(time)) {
        failure(discovery, L"Invalid device last arrival property", ERROR_INVALID_DATA);
        return;
    }
    port->last_arrival = ((uint64_t)time.dwHighDateTime << 32) | time.dwLowDateTime;
    port->has_last_arrival = 1;
}

static int save_port(Discovery *discovery, Port *port)
{
    if (!port_list_add(discovery->list, port)) {
        failure(discovery, L"Saving port", ERROR_NOT_ENOUGH_MEMORY);
        port_clear(port);
        return 0;
    }
    return 1;
}

static void read_device(Discovery *discovery, HDEVINFO devices,
                        SP_DEVINFO_DATA *info)
{
    static const struct {
        PortField field;
        const DEVPROPKEY *key;
    } properties[] = {
        { PORT_DESCRIPTION, &DEVPKEY_Device_FriendlyName },
        { PORT_MANUFACTURER, &DEVPKEY_Device_Manufacturer },
        { PORT_HARDWARE, &DEVPKEY_Device_HardwareIds },
        { PORT_SERVICE, &DEVPKEY_Device_Service },
        { PORT_LOCATION, &DEVPKEY_Device_LocationInfo },
        { PORT_DRIVER_PROVIDER, &DEVPKEY_Device_DriverProvider },
        { PORT_DRIVER_VERSION, &DEVPKEY_Device_DriverVersion }
    };
    Port port = {0};
    DEVINST node = info->DevInst;
    HKEY key;
    unsigned depth;
    size_t i;
    key = SetupDiOpenDevRegKey(devices, info, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
    if (key == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        if (error != ERROR_FILE_NOT_FOUND && error != ERROR_KEY_DOES_NOT_EXIST &&
            error != ERROR_NO_SUCH_DEVINST && error != ERROR_DEV_NOT_EXIST)
            failure(discovery, L"Opening device registry key", error);
        return;
    }
    port.text[PORT_NAME] = registry_text(discovery, key, L"PortName");
    RegCloseKey(key);
    if (!port_name_valid(port.text[PORT_NAME])) {
        port_clear(&port);
        return;
    }
    read_last_arrival(discovery, node, &port);
    for (i = 0; i < ARRAYSIZE(properties); ++i)
        port.text[properties[i].field] = device_text(discovery, node, properties[i].key);
    if (!port.text[PORT_DESCRIPTION])
        port.text[PORT_DESCRIPTION] = device_text(discovery, node, &DEVPKEY_Device_DeviceDesc);
    for (depth = 0; depth < 64; ++depth) {
        DEVINST parent;
        CONFIGRET status;
        unsigned vid, pid;
        wchar_t *instance = device_text(discovery, node, &DEVPKEY_Device_InstanceId);
        port_observe(&port, instance, depth);
        if (!port.text[PORT_USB_DEVICE] && usb_identifiers(instance, &vid, &pid) &&
            !port_set(&port, PORT_USB_DEVICE, instance))
            failure(discovery, L"Saving USB identity", ERROR_NOT_ENOUGH_MEMORY);
        if (depth == 0) {
            port.text[PORT_INSTANCE] = instance;
            instance = NULL;
        } else if (depth == 1) {
            port.text[PORT_PARENT] = instance;
            instance = NULL;
        }
        free(instance);
        status = CM_Get_Parent(&parent, node, 0);
        if (status == CR_NO_SUCH_DEVNODE)
            break;
        if (status != CR_SUCCESS) {
            failure(discovery, L"Reading parent device",
                    CM_MapCrToWin32Err(status, ERROR_GEN_FAILURE));
            break;
        }
        if (parent == node) {
            failure(discovery, L"Cycle in device ancestry", ERROR_INVALID_DATA);
            break;
        }
        node = parent;
    }
    if (depth == 64)
        failure(discovery, L"Device ancestry exceeds 64 levels", ERROR_INVALID_DATA);
    save_port(discovery, &port);
}

static void read_devices(Discovery *discovery, const GUID *class_id, int interfaces)
{
    HDEVINFO devices;
    DWORD index;
    devices = SetupDiGetClassDevsW(class_id, NULL, NULL,
                                   DIGCF_PRESENT | (interfaces ? DIGCF_DEVICEINTERFACE : 0));
    if (devices == INVALID_HANDLE_VALUE) {
        failure(discovery, L"Enumerating present COM devices", GetLastError());
        return;
    }
    for (index = 0;; ++index) {
        SP_DEVINFO_DATA info = {0};
        info.cbSize = sizeof(info);
        if (!SetupDiEnumDeviceInfo(devices, index, &info)) {
            DWORD error = GetLastError();
            if (error != ERROR_NO_MORE_ITEMS)
                failure(discovery, L"Enumerating device info", error);
            break;
        }
        read_device(discovery, devices, &info);
    }
    SetupDiDestroyDeviceInfoList(devices);
}

static void read_serial_map(Discovery *discovery)
{
    HKEY key;
    DWORD max_name, max_data, index;
    wchar_t *name, *data;
    LSTATUS status = RegOpenKeyExW(HKEY_LOCAL_MACHINE,
        L"HARDWARE\\DEVICEMAP\\SERIALCOMM", 0, KEY_QUERY_VALUE, &key);
    if (status == ERROR_FILE_NOT_FOUND)
        return;
    if (status != ERROR_SUCCESS) {
        failure(discovery, L"Opening serial port map", (DWORD)status);
        return;
    }
    status = RegQueryInfoKeyW(key, NULL, NULL, NULL, NULL, NULL, NULL,
                              NULL, &max_name, &max_data, NULL, NULL);
    if (status != ERROR_SUCCESS) {
        failure(discovery, L"Reading serial port map sizes", (DWORD)status);
        RegCloseKey(key);
        return;
    }
    name = calloc((size_t)max_name + 1, sizeof(*name));
    data = calloc((size_t)max_data + sizeof(wchar_t), 1);
    if (!name || !data) {
        failure(discovery, L"Allocating serial port map", ERROR_NOT_ENOUGH_MEMORY);
    } else {
        for (index = 0;; ++index) {
            DWORD name_length = max_name + 1, data_bytes = max_data, type;
            Port port = {0};
            status = RegEnumValueW(key, index, name, &name_length, NULL, &type,
                                   (BYTE *)data, &data_bytes);
            if (status == ERROR_NO_MORE_ITEMS)
                break;
            if (status != ERROR_SUCCESS) {
                failure(discovery, L"Reading serial port map", (DWORD)status);
                break;
            }
            if (type != REG_SZ || data_bytes % sizeof(wchar_t)) {
                failure(discovery, L"Invalid serial port map entry", ERROR_INVALID_DATA);
                continue;
            }
            data[data_bytes / sizeof(wchar_t)] = L'\0';
            if (!port_name_valid(data))
                continue;
            if (!port_set(&port, PORT_NAME, data)) {
                failure(discovery, L"Saving serial port name", ERROR_NOT_ENOUGH_MEMORY);
                break;
            }
            if (!save_port(discovery, &port))
                break;
        }
    }
    free(name);
    free(data);
    RegCloseKey(key);
}

int port_list_load(PortList *list)
{
    Discovery discovery = { list, 1 };
    read_devices(&discovery, &GUID_DEVINTERFACE_COMPORT, 1);
    read_devices(&discovery, &GUID_DEVCLASS_PORTS, 0);
    read_devices(&discovery, &GUID_DEVCLASS_MODEM, 0);
    read_serial_map(&discovery);
    port_list_sort(list);
    return discovery.ok;
}
