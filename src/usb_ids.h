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
} UsbIds;

/* The buffer must outlive the view. Failure sets the Windows last-error code. */
int usb_ids_open(UsbIds *ids, const void *data, size_t size);
int usb_ids_load(UsbIds *ids);
/* Successful misses return NULL names; callers free any returned names. */
int usb_ids_lookup(const UsbIds *ids, unsigned vid, unsigned pid,
                   wchar_t **vendor, wchar_t **product);

#endif
