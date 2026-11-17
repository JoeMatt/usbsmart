//
//  USBSmartDevice.cpp
//
//  Every command this driver can send to a drive is listed here, and nowhere else:
//
//      ATA command              opcode / feature   data
//      IDENTIFY DEVICE          ECh                512 bytes in
//      SMART READ DATA          B0h / D0h          512 bytes in
//      SMART READ THRESHOLDS    B0h / D1h          512 bytes in
//      SMART READ LOG           B0h / D5h          512 bytes in (one sector of one log)
//      SMART RETURN STATUS      B0h / DAh          none
//
//  Each is wrapped in SCSI ATA PASS-THROUGH (16), opcode 85h, built by Apple's helpers in
//  SCSIPeripheralsDriverKit. IsAllowedCDB then checks the finished command byte by byte and
//  nothing is sent unless it passes. Do not add a command that writes to the drive, starts a
//  self-test, changes a setting or touches firmware: drives read with this tool may hold the
//  only copy of someone's data.
//
//  Normal disk I/O does not pass through this file. The kernel half of the class
//  (IOUserSCSIPeripheralDeviceType00) is Apple's ordinary disk driver and handles it alone.
//

#include <os/log.h>

#include <DriverKit/DriverKit.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>

#include "USBSmartDevice.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "USBSmart: " fmt, ##__VA_ARGS__)

// ATA PASS-THROUGH (16) layout (SAT-5, 12.2.2.3).
enum
{
    kCDBOpcode          = 0,    // 85h
    kCDBProtocol        = 1,    // bits 4:1 protocol, bit 0 extend
    kCDBFlags           = 2,    // bit 5 ck_cond, bit 3 t_dir (1 = from the drive), ...
    kCDBFeatures        = 4,
    kCDBCount           = 6,
    kCDBLBALow          = 8,
    kCDBLBAMid          = 10,
    kCDBLBAHigh         = 12,
    kCDBCommand         = 14,
};

enum
{
    kATAPassThrough16       = 0x85,
    kProtocolNonData        = 3,
    kProtocolPIODataIn      = 4,
    kTDirFromDevice         = 0x08,

    kATAIdentifyDevice      = 0xEC,
    kATASmart               = 0xB0,
    kSmartReadData          = 0xD0,
    kSmartReadThresholds    = 0xD1,
    kSmartReadLog           = 0xD5,
    kSmartReturnStatus      = 0xDA,
    kSmartLBAMid            = 0x4F,
    kSmartLBAHigh           = 0xC2,
};

struct USBSmartDevice_IVars
{
    uint32_t commandsSent;
};

bool
USBSmartDevice::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(USBSmartDevice_IVars, 1);
    return ivars != nullptr;
}

void
USBSmartDevice::free()
{
    IOSafeDeleteNULL(ivars, USBSmartDevice_IVars, 1);
    super::free();
}

kern_return_t
IMPL(USBSmartDevice, Start)
{
    // The kernel half does all the disk bring-up. Nothing is sent to the drive from here.
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    Log("Start -> 0x%x", ret);
    return ret;
}

kern_return_t
IMPL(USBSmartDevice, Stop)
{
    Log("Stop");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(USBSmartDevice, UserDetermineDeviceCharacteristics)
{
    // Keep every I/O limit at the kernel's defaults, so the disk behaves as it does under
    // Apple's own driver.
    *result = true;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(USBSmartDevice, NewUserClient)
{
    IOService * client = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess || client == nullptr) {
        return ret != kIOReturnSuccess ? ret : kIOReturnError;
    }
    *userClient = OSDynamicCast(IOUserClient, client);
    if (*userClient == nullptr) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

// The last check before a command leaves the driver. `cdb` is what will be sent; `command` and
// `argument` are what was asked for. Returns true only for the five read-only commands in the
// table at the top of this file.
static bool
IsAllowedCDB(const uint8_t * cdb, uint32_t command, uint32_t argument)
{
    if (cdb[kCDBOpcode] != kATAPassThrough16) {
        return false;
    }
    const uint8_t protocol = (cdb[kCDBProtocol] >> 1) & 0x0F;
    const bool    fromDevice = (cdb[kCDBFlags] & kTDirFromDevice) != 0;
    const uint8_t ata = cdb[kCDBCommand];
    const uint8_t feature = cdb[kCDBFeatures];

    if (command == kUSBSmartReturnStatus) {
        return protocol == kProtocolNonData && ata == kATASmart && feature == kSmartReturnStatus &&
               cdb[kCDBLBAMid] == kSmartLBAMid && cdb[kCDBLBAHigh] == kSmartLBAHigh;
    }

    // Everything else reads exactly one 512-byte sector from the drive.
    if (protocol != kProtocolPIODataIn || !fromDevice || cdb[kCDBCount] != 1 || cdb[kCDBCount - 1] != 0) {
        return false;
    }
    if (command == kUSBSmartIdentify) {
        return ata == kATAIdentifyDevice;
    }
    if (ata != kATASmart || cdb[kCDBLBAMid] != kSmartLBAMid || cdb[kCDBLBAHigh] != kSmartLBAHigh) {
        return false;
    }
    switch (command) {
        case kUSBSmartReadData:         return feature == kSmartReadData;
        case kUSBSmartReadThresholds:   return feature == kSmartReadThresholds;
        case kUSBSmartReadLog:          return feature == kSmartReadLog && cdb[kCDBLBALow] == (uint8_t) argument;
        default:                        return false;
    }
}

kern_return_t
USBSmartDevice::RunCommand(uint32_t command, uint32_t argument, USBSmartReply * reply)
{
    if (reply == nullptr) {
        return kIOReturnBadArgument;
    }
    memset(reply, 0, sizeof(*reply));
    reply->version = kUSBSmartReplyVersion;
    if (command == kUSBSmartReadLog && argument > 0xFF) {
        return kIOReturnBadArgument;
    }

    uint8_t * data = IONewZero(uint8_t, kUSBSmartDataSize);
    uint8_t * sense = IONewZero(uint8_t, kUSBSmartSenseSize);
    if (data == nullptr || sense == nullptr) {
        IOSafeDeleteNULL(data, uint8_t, kUSBSmartDataSize);
        IOSafeDeleteNULL(sense, uint8_t, kUSBSmartSenseSize);
        return kIOReturnNoMemory;
    }

    SCSIType00OutParameters request = {};
    SCSIType00InParameters  response = {};
    const UInt64 dataAddress = (UInt64) (uintptr_t) data;
    const UInt64 senseAddress = (UInt64) (uintptr_t) sense;

    bool built = false;
    switch (command) {
        case kUSBSmartIdentify:
            built = SMART_Get_Identify_Data(&request, dataAddress, &response, senseAddress);
            break;
        case kUSBSmartReadData:
            built = SMART_Read_Data(&request, kUSBSmartDataSize, dataAddress, &response, senseAddress);
            break;
        case kUSBSmartReadThresholds:
            built = SMART_Read_Data_Thresholds(&request, kUSBSmartDataSize, dataAddress, &response, senseAddress);
            break;
        case kUSBSmartReturnStatus:
            built = SMART_Return_Status(&request, &response, senseAddress);
            break;
        case kUSBSmartReadLog:
            built = SMART_Read_Log_At_Address(&request, dataAddress, 1, (UInt8) argument, &response, senseAddress);
            break;
        default:
            break;
    }

    kern_return_t result = kIOReturnSuccess;
    if (!built) {
        result = kIOReturnUnsupported;
    } else {
        if (command != kUSBSmartReturnStatus) {
            // Every data command here reads one 512-byte sector. Apple's IDENTIFY helper leaves
            // the ATA sector count at 0 (seen on DriverKit 27.0: 85 08 0e 00 00 00 00 ... ec 00),
            // which with t_length = "count field" asks the bridge for no data at all. Send the
            // form smartmontools has used with every SAT bridge for years: count 1.
            if (request.fCommandDescriptorBlock[kCDBCount] == 0) {
                request.fCommandDescriptorBlock[kCDBCount] = 1;
            }
            request.fRequestedByteCountOfTransfer = kUSBSmartDataSize;
        }
        memcpy(reply->cdb, request.fCommandDescriptorBlock, sizeof(reply->cdb));
        reply->senseLength = request.fSenseLengthRequested;
        if (!IsAllowedCDB(reply->cdb, command, argument) ||
            request.fSenseLengthRequested > kUSBSmartSenseSize ||
            request.fRequestedByteCountOfTransfer > kUSBSmartDataSize) {
            // Report the command back instead of sending it, so the mismatch can be diagnosed.
            reply->refused = 1;
            Log("refused command %u: opcode %02x ata %02x feature %02x", command,
                reply->cdb[kCDBOpcode], reply->cdb[kCDBCommand], reply->cdb[kCDBFeatures]);
        } else {
            reply->sendResult = UserSendCDB(request, &response);
            ivars->commandsSent += 1;
            reply->taskStatus = (uint32_t) response.fCompletionStatus;
            reply->serviceResponse = (uint32_t) response.fServiceResponse;
            reply->realizedBytes = response.fRealizedByteCountOfTransfer;
            reply->senseValid = response.fSenseDataValid ? 1 : 0;
            memcpy(reply->sense, sense, kUSBSmartSenseSize);
            memcpy(reply->data, data, kUSBSmartDataSize);
        }
    }

    IOSafeDeleteNULL(data, uint8_t, kUSBSmartDataSize);
    IOSafeDeleteNULL(sense, uint8_t, kUSBSmartSenseSize);
    return result;
}
