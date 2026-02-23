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

// USB device structure offsets
.equ USB_DEV_ADDR,          0
.equ USB_DEV_SPEED,         4
.equ USB_DEV_STATE,         8
.equ USB_DEV_VID,           12
.equ USB_DEV_PID,           14
.equ USB_DEV_CLASS,         16
.equ USB_DEV_MAX_PACKET,    20
.equ USB_DEV_CONFIGS,       24
.equ USB_DEV_DRIVER,        28
.equ USB_DEV_PRIVATE,       32
.equ USB_DEV_ENDPOINTS,     36
.equ USB_DEV_PARENT,        40
.equ USB_DEV_PORT,          44
.equ USB_DEV_TOGGLE_RESET,  48
.equ USB_DEV_SIZE,          128

// USB endpoint structure offsets
.equ USB_EP_NUM,            0
.equ USB_EP_TYPE,           4
.equ USB_EP_DIR,            8
.equ USB_EP_MAX_PKT,        12
.equ USB_EP_INTERVAL,       16
.equ USB_EP_DEVICE,         20
.equ USB_EP_TOGGLE,         24
.equ USB_EP_HALTED,         25
.equ USB_EP_SIZE,           32

// USB request block (URB) offsets
.equ URB_DEVICE,            0
.equ URB_ENDPOINT,          4
.equ URB_TYPE,              8
.equ URB_DIR,               12
.equ URB_BUFFER,            16
.equ URB_LENGTH,            20
.equ URB_ACTUAL,            24
.equ URB_STATUS,            28
.equ URB_CALLBACK,          32
.equ URB_PRIVATE,           36
.equ URB_NEXT,              40
.equ URB_CHANNEL,           44
.equ URB_PID,               45
.equ URB_SPLIT,             46
.equ URB_HUB_ADDR,          47
.equ URB_PORT_NUM,          48
.equ URB_SIZE,              52

// HID request types and HID instance offsets
.equ HID_REQ_SET_IDLE,      0x0A
.equ HID_REQ_SET_PROTOCOL,  0x0B

.equ HID_DEVICE,            0
.equ HID_INTERFACE,         4
.equ HID_EP_IN,             8
.equ HID_REPORT_SIZE,       12
.equ HID_REPORT_DESC,       16
.equ HID_STATE,             20
.equ HID_BUFFER,            24
.equ HID_URB,               28
.equ HID_CALLBACK,          32
.equ HID_PRIVATE,           36
.equ HID_IDLE,              40
.equ HID_PROTOCOL,          44
