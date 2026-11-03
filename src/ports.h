#ifndef COMLS_PORTS_H
#define COMLS_PORTS_H

#include <stddef.h>
#include <wchar.h>

#define COMLS_VERSION L"0.1.0"

typedef enum {
    PORT_NAME,
    PORT_DESCRIPTION,
    PORT_MANUFACTURER,
    PORT_INSTANCE,
    PORT_HARDWARE,
    PORT_SERVICE,
    PORT_LOCATION,
    PORT_DRIVER_PROVIDER,
    PORT_DRIVER_VERSION,
    PORT_PARENT,
    PORT_USB_DEVICE,
    PORT_USB_VENDOR,
    PORT_USB_PRODUCT,
    PORT_FIELD_COUNT
} PortField;

typedef enum {
    TRANSPORT_UNKNOWN,
    TRANSPORT_NATIVE,
    TRANSPORT_USB,
    TRANSPORT_VIRTUAL,
    TRANSPORT_BLUETOOTH
} Transport;

typedef struct {
    wchar_t *text[PORT_FIELD_COUNT];
    Transport transport;
} Port;

typedef struct {
    Port *items;
    size_t count;
    size_t capacity;
} PortList;

int port_name_valid(const wchar_t *name);
int port_set(Port *port, PortField field, const wchar_t *value);
void port_clear(Port *port);
int port_list_add(PortList *list, Port *port);
void port_list_sort(PortList *list);
void port_list_clear(PortList *list);
void port_observe(Port *port, const wchar_t *instance, unsigned depth);
const wchar_t *transport_name(Transport transport);
int usb_identifiers(const wchar_t *instance, unsigned *vid, unsigned *pid);
int usb_interface(const wchar_t *instance, unsigned *number);

/* Returns nonzero only when discovery completed without unexpected errors. */
int port_list_load(PortList *list);

#endif
