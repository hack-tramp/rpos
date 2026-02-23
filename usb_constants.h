// usb_constants.h - Shared USB constants for all drivers

// Device classes
.equ USB_CLASS_HID,         0x03
.equ USB_CLASS_MASS_STORAGE, 0x08
.equ USB_CLASS_HUB,         0x09

// Transfer types
.equ USB_TRANSFER_CONTROL,  0
.equ USB_TRANSFER_ISOCH,    1
.equ USB_TRANSFER_BULK,     2
.equ USB_TRANSFER_INTERRUPT, 3

// Transfer status
.equ XFER_PENDING,          0
.equ XFER_COMPLETE,         1
.equ XFER_ERROR,            2
.equ XFER_CANCELLED,        3

// Endpoint directions
.equ EP_DIR_OUT,            0
.equ EP_DIR_IN,             1
