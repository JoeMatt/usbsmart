//
//  USBSmartUserClient.cpp
//

#include <DriverKit/DriverKit.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSCollections.h>

#include "USBSmartDevice.h"
#include "USBSmartUserClient.h"

struct USBSmartUserClient_IVars
{
    USBSmartDevice * device;
};

bool
USBSmartUserClient::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(USBSmartUserClient_IVars, 1);
    return ivars != nullptr;
}

void
USBSmartUserClient::free()
{
    if (ivars != nullptr) {
        OSSafeReleaseNULL(ivars->device);
        IOSafeDeleteNULL(ivars, USBSmartUserClient_IVars, 1);
    }
    super::free();
}

kern_return_t
IMPL(USBSmartUserClient, Start)
{
    ivars->device = OSDynamicCast(USBSmartDevice, provider);
    if (ivars->device == nullptr) {
        return kIOReturnBadArgument;
    }
    ivars->device->retain();
    return Start(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(USBSmartUserClient, Stop)
{
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
USBSmartUserClient::ExternalMethod(uint64_t selector,
                                   IOUserClientMethodArguments * arguments,
                                   const IOUserClientMethodDispatch * dispatch,
                                   OSObject * target,
                                   void * reference)
{
    if (selector != 0 || arguments == nullptr || arguments->structureInput == nullptr ||
        arguments->structureInput->getLength() < sizeof(USBSmartRequest) ||
        arguments->structureOutputMaximumSize < sizeof(USBSmartReply) ||
        ivars == nullptr || ivars->device == nullptr) {
        return kIOReturnBadArgument;
    }
    USBSmartRequest request;
    memcpy(&request, arguments->structureInput->getBytesNoCopy(), sizeof(request));

    USBSmartReply * reply = IONewZero(USBSmartReply, 1);
    if (reply == nullptr) {
        return kIOReturnNoMemory;
    }
    kern_return_t result = ivars->device->RunCommand(request.command, request.argument, reply);
    if (result == kIOReturnSuccess) {
        arguments->structureOutput = OSData::withBytes(reply, sizeof(*reply));
        if (arguments->structureOutput == nullptr) {
            result = kIOReturnNoMemory;
        }
    }
    IOSafeDeleteNULL(reply, USBSmartReply, 1);
    return result;
}
