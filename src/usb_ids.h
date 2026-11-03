#ifndef COMLS_USB_IDS_H
#define COMLS_USB_IDS_H

#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

typedef struct {
    const unsigned char *vendors;
    const unsigned char *products;
    const char *strings;
    uint32_t vendor_count;
    uint32_t product_count;
    uint32_t strings_size;
    void *allocation;
} UsbIds;

/* The buffer must outlive the view. Failure sets the Windows last-error code. */
int usb_ids_open(UsbIds *ids, const void *data, size_t size);
/* Unpack an MSZIP buffer into owned memory and validate the indexed database. */
int usb_ids_unpack(UsbIds *ids, const void *data, size_t size);
int usb_ids_load(UsbIds *ids);
/* Close a zero-initialized, opened, unpacked, or loaded database before reuse. */
void usb_ids_close(UsbIds *ids);
/* Successful misses return NULL names; callers free any returned names. */
int usb_ids_lookup(const UsbIds *ids, unsigned vid, unsigned pid,
                   wchar_t **vendor, wchar_t **product);

#endif
