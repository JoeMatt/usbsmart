//
//  USBSmartShared.h
//
//  The wire format between the `usbsmart` command and the driver. The command is written in
//  Swift and reads these structures by offset, so keep USBSmartReply's layout in step with
//  Reply in CLI/Driver.swift.
//

#ifndef USBSmartShared_h
#define USBSmartShared_h

#include <stdint.h>

// The complete list of things the driver can be asked to do. Five read from the drive. The
// sixth asks the drive to run (or stop) one of its own built-in self-tests in the background,
// which reads the drive's surface and never writes user data. There is no command here that
// writes, changes a setting or touches firmware, and the driver refuses to send anything else
// (see USBSmartDevice::IsAllowedCDB).
enum USBSmartCommand : uint32_t
{
    kUSBSmartIdentify       = 0,    // IDENTIFY DEVICE (ECh)
    kUSBSmartReadData       = 1,    // SMART READ DATA (B0h / D0h)
    kUSBSmartReadThresholds = 2,    // SMART READ THRESHOLDS (B0h / D1h)
    kUSBSmartReturnStatus   = 3,    // SMART RETURN STATUS (B0h / DAh), no data
    kUSBSmartReadLog        = 4,    // SMART READ LOG (B0h / D5h), argument = log address, 1 sector
    kUSBSmartSelfTest       = 5,    // SMART EXECUTE OFF-LINE IMMEDIATE (B0h / D4h), no data,
                                    // argument = USBSmartSelfTest
};

// The only subcommands kUSBSmartSelfTest accepts: the off-line (background) tests and abort.
// The captive forms (81h-84h) hold the drive busy and are refused.
enum USBSmartSelfTest : uint32_t
{
    kUSBSmartSelfTestShort      = 0x01,
    kUSBSmartSelfTestExtended   = 0x02,
    kUSBSmartSelfTestConveyance = 0x03,
    kUSBSmartSelfTestAbort      = 0x7F,
};

// Selector 0 input.
struct USBSmartRequest
{
    uint32_t command;       // USBSmartCommand
    uint32_t argument;      // log address for kUSBSmartReadLog, USBSmartSelfTest for
                            // kUSBSmartSelfTest, otherwise 0
};

#define kUSBSmartReplyVersion   1
#define kUSBSmartSenseSize      32
#define kUSBSmartDataSize       512

// Selector 0 output. 592 bytes, no implicit padding.
struct USBSmartReply
{
    uint32_t version;                       //   0  kUSBSmartReplyVersion
    int32_t  sendResult;                    //   4  what UserSendCDB returned
    uint32_t taskStatus;                    //   8  SCSITaskStatus
    uint32_t serviceResponse;               //  12  SCSIServiceResponse
    uint64_t realizedBytes;                 //  16  bytes the device actually transferred
    uint8_t  senseValid;                    //  24
    uint8_t  senseLength;                   //  25  what was requested
    uint8_t  cdb[16];                       //  26  the exact command sent (or refused)
    uint8_t  sense[kUSBSmartSenseSize];     //  42
    uint8_t  refused;                       //  74  1 if the driver's own check rejected the CDB
    uint8_t  reserved[5];                   //  75
    uint8_t  data[kUSBSmartDataSize];       //  80
};

#endif /* USBSmartShared_h */
