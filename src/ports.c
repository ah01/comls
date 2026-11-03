#include "ports.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int port_name_valid(const wchar_t *name)
{
    const wchar_t *digit;
    if (!name || _wcsnicmp(name, L"COM", 3) != 0 ||
        name[3] < L'1' || name[3] > L'9')
        return 0;
    for (digit = name + 4; *digit; ++digit) {
        if (*digit < L'0' || *digit > L'9')
            return 0;
    }
    return 1;
}

int port_set(Port *port, PortField field, const wchar_t *value)
{
    wchar_t *copy;
    if (!value || !*value)
        return 1;
    copy = _wcsdup(value);
    if (!copy)
        return 0;
    free(port->text[field]);
    port->text[field] = copy;
    return 1;
}

void port_clear(Port *port)
{
    size_t field;
    for (field = 0; field < PORT_FIELD_COUNT; ++field)
        free(port->text[field]);
    memset(port, 0, sizeof(*port));
}

int port_list_add(PortList *list, Port *port)
{
    size_t i, field;
    Port *grown;
    if (!port_name_valid(port->text[PORT_NAME]))
        return 0;
    for (i = 0; i < list->count; ++i) {
        Port *existing = &list->items[i];
        if (_wcsicmp(existing->text[PORT_NAME], port->text[PORT_NAME]) != 0)
            continue;
        for (field = 0; field < PORT_FIELD_COUNT; ++field) {
            if (!existing->text[field]) {
                existing->text[field] = port->text[field];
                port->text[field] = NULL;
            }
        }
        if (existing->transport < port->transport)
            existing->transport = port->transport;
        if (!existing->has_last_arrival && port->has_last_arrival) {
            existing->last_arrival = port->last_arrival;
            existing->has_last_arrival = 1;
        }
        port_clear(port);
        return 1;
    }
    if (list->count == list->capacity) {
        size_t capacity = list->capacity ? list->capacity * 2 : 8;
        if (capacity < list->capacity || capacity > SIZE_MAX / sizeof(*grown))
            return 0;
        grown = realloc(list->items, capacity * sizeof(*grown));
        if (!grown)
            return 0;
        list->items = grown;
        list->capacity = capacity;
    }
    list->items[list->count++] = *port;
    memset(port, 0, sizeof(*port));
    return 1;
}

static int port_compare(const void *left, const void *right)
{
    const wchar_t *a = ((const Port *)left)->text[PORT_NAME] + 3;
    const wchar_t *b = ((const Port *)right)->text[PORT_NAME] + 3;
    size_t a_length = wcslen(a), b_length = wcslen(b);
    if (a_length != b_length)
        return a_length < b_length ? -1 : 1;
    return wcscmp(a, b);
}

void port_list_sort(PortList *list)
{
    if (list->count > 1)
        qsort(list->items, list->count, sizeof(*list->items), port_compare);
}

static int port_time_compare(const void *left, const void *right)
{
    const Port *a = left, *b = right;
    if (a->has_last_arrival != b->has_last_arrival)
        return a->has_last_arrival ? -1 : 1;
    if (a->has_last_arrival && a->last_arrival != b->last_arrival)
        return a->last_arrival > b->last_arrival ? -1 : 1;
    return port_compare(left, right);
}

void port_list_sort_by_time(PortList *list)
{
    if (list->count > 1)
        qsort(list->items, list->count, sizeof(*list->items), port_time_compare);
}

void port_list_clear(PortList *list)
{
    size_t i;
    for (i = 0; i < list->count; ++i)
        port_clear(&list->items[i]);
    free(list->items);
    memset(list, 0, sizeof(*list));
}

int port_is_recent(const Port *port, uint64_t now)
{
    return port->has_last_arrival && port->last_arrival <= now &&
        now - port->last_arrival <= UINT64_C(300) * 10000000;
}

static int starts_with(const wchar_t *text, const wchar_t *prefix)
{
    return _wcsnicmp(text, prefix, wcslen(prefix)) == 0;
}

void port_observe(Port *port, const wchar_t *instance, unsigned depth)
{
    Transport found = TRANSPORT_UNKNOWN;
    if (!instance)
        return;
    if (starts_with(instance, L"BTHENUM\\") ||
        starts_with(instance, L"BTHMODEM\\") ||
        starts_with(instance, L"BTHLEDEVICE\\") ||
        starts_with(instance, L"BTH\\"))
        found = TRANSPORT_BLUETOOTH;
    else if (starts_with(instance, L"USB\\"))
        found = TRANSPORT_USB;
    else if (starts_with(instance, L"VMBUS\\") ||
             starts_with(instance, L"SWD\\") ||
             starts_with(instance, L"ROOT\\COM0COM") ||
             starts_with(instance, L"ROOT\\VIRTUAL") ||
             starts_with(instance, L"ROOT\\VSERIAL"))
        found = TRANSPORT_VIRTUAL;
    else if (depth == 0 &&
             (starts_with(instance, L"PCI\\") ||
              starts_with(instance, L"ACPI\\PNP0500\\") ||
              starts_with(instance, L"ACPI\\PNP0501\\")))
        found = TRANSPORT_NATIVE;
    if (found > port->transport)
        port->transport = found;
}

const wchar_t *transport_name(Transport transport)
{
    switch (transport) {
    case TRANSPORT_NATIVE: return L"Native";
    case TRANSPORT_USB: return L"USB";
    case TRANSPORT_VIRTUAL: return L"Virtual";
    case TRANSPORT_BLUETOOTH: return L"Bluetooth";
    default: return L"Unknown";
    }
}

static int hex_field(const wchar_t *instance, const wchar_t *tag,
                     unsigned digits, unsigned *result)
{
    const wchar_t *p;
    size_t length = wcslen(tag);
    /* Only inspect the device-ID segment, not a serial/instance suffix. */
    p = wcschr(instance, L'\\');
    if (!p)
        return 0;
    for (++p; *p && *p != L'\\'; ++p) {
        unsigned value = 0, i;
        if (p[-1] != L'\\' && p[-1] != L'&')
            continue;
        if (_wcsnicmp(p, tag, length) != 0)
            continue;
        for (i = 0; i < digits; ++i) {
            wchar_t c = p[length + i];
            unsigned nibble;
            if (c >= L'0' && c <= L'9')
                nibble = (unsigned)(c - L'0');
            else if (c >= L'A' && c <= L'F')
                nibble = (unsigned)(c - L'A') + 10;
            else if (c >= L'a' && c <= L'f')
                nibble = (unsigned)(c - L'a') + 10;
            else
                return 0;
            value = (value << 4) | nibble;
        }
        if (p[length + digits] != L'&' && p[length + digits] != L'\\' &&
            p[length + digits] != L'\0')
            return 0;
        *result = value;
        return 1;
    }
    return 0;
}

int usb_identifiers(const wchar_t *instance, unsigned *vid, unsigned *pid)
{
    return instance && starts_with(instance, L"USB\\") &&
        hex_field(instance, L"VID_", 4, vid) &&
        hex_field(instance, L"PID_", 4, pid);
}

int usb_interface(const wchar_t *instance, unsigned *number)
{
    return instance && starts_with(instance, L"USB\\") &&
        hex_field(instance, L"MI_", 2, number);
}
