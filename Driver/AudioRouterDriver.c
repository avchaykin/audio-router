// Audio Router virtual loopback device — a minimal Core Audio AudioServerPlugIn.
//
// Exposes one device, "Audio Router", with a stereo output stream and a stereo input stream.
// Whatever applications play to the output is available on the input, which Audio Router
// (or any other app) can capture.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>

// ---------------------------------------------------------------------------------------------
// Constants

#define kDeviceUID          "AudioRouterVirtualDevice_UID"
#define kDeviceModelUID     "AudioRouterVirtualDevice_ModelUID"
#define kDeviceName         "Audio Router"
#define kManufacturerName   "Audio Router"

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
};

#define kChannels               2
#define kBytesPerFrame          (sizeof(Float32) * kChannels)
#define kZeroTimeStampPeriod    16384
#define kRingFrames             65536   // power of two
#define kRingMask               (kRingFrames - 1)

static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
#define kNumSampleRates (sizeof(kSampleRates) / sizeof(kSampleRates[0]))

// ---------------------------------------------------------------------------------------------
// State

static pthread_mutex_t          gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32                   gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static Float64                  gSampleRate = 48000.0;
static UInt64                   gIOCount = 0;
static Float64                  gHostTicksPerFrame = 0;
static UInt64                   gAnchorHostTime = 0;
static UInt64                   gNumberTimeStamps = 0;
static Float32                  gRing[kRingFrames * kChannels];

// ---------------------------------------------------------------------------------------------
// Interface prototypes

static HRESULT  AR_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    AR_AddRef(void* inDriver);
static ULONG    AR_Release(void* inDriver);
static OSStatus AR_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus AR_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus AR_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus AR_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus AR_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus AR_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus AR_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  AR_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus AR_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus AR_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus AR_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus AR_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus AR_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus AR_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus AR_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus AR_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus AR_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus AR_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus AR_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    AR_QueryInterface, AR_AddRef, AR_Release,
    AR_Initialize, AR_CreateDevice, AR_DestroyDevice,
    AR_AddDeviceClient, AR_RemoveDeviceClient,
    AR_PerformDeviceConfigurationChange, AR_AbortDeviceConfigurationChange,
    AR_HasProperty, AR_IsPropertySettable, AR_GetPropertyDataSize, AR_GetPropertyData, AR_SetPropertyData,
    AR_StartIO, AR_StopIO, AR_GetZeroTimeStamp,
    AR_WillDoIOOperation, AR_BeginIOOperation, AR_DoIOOperation, AR_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef = &gInterfacePtr;

// ---------------------------------------------------------------------------------------------
// Factory (named in Info.plist CFPlugInFactories)

void* AudioRouterDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
__attribute__((visibility("default")))
void* AudioRouterDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

// ---------------------------------------------------------------------------------------------
// IUnknown

static HRESULT AR_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AR_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG AR_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

// ---------------------------------------------------------------------------------------------
// Basic operations

static void UpdateTiming(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 hostClockFrequency = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / gSampleRate;
}

static OSStatus AR_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    UpdateTiming();
    return noErr;
}

static OSStatus AR_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* out) {
    (void)d; (void)desc; (void)ci; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AR_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AR_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci) {
    (void)ci;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return noErr;
}

static OSStatus AR_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci) {
    (void)ci;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return noErr;
}

static OSStatus AR_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* info) {
    (void)info;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    bool valid = false;
    for (UInt32 i = 0; i < kNumSampleRates; ++i) if ((UInt64)kSampleRates[i] == action) valid = true;
    if (!valid) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gSampleRate = (Float64)action;
    UpdateTiming();
    memset(gRing, 0, sizeof(gRing));
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus AR_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void* info) {
    (void)action; (void)info;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return noErr;
}

// ---------------------------------------------------------------------------------------------
// Properties
//
// One routine answers both size and data queries: when outData is NULL only *outSize is set.

static AudioStreamBasicDescription MakeFormat(Float64 rate) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate       = rate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked;
    f.mBytesPerPacket   = kBytesPerFrame;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel   = 32;
    return f;
}

#define RETURN_VALUE(TYPE, VALUE) do {                                              \
        if (outData) {                                                              \
            if (inDataSize < sizeof(TYPE)) return kAudioHardwareBadPropertySizeError; \
            *(TYPE*)outData = (VALUE);                                              \
        }                                                                           \
        *outSize = sizeof(TYPE);                                                    \
        return noErr;                                                               \
    } while (0)

static OSStatus ReturnObjectList(const AudioObjectID* ids, UInt32 count, UInt32 inDataSize, UInt32* outSize, void* outData) {
    if (outData) {
        UInt32 n = inDataSize / sizeof(AudioObjectID);
        if (n > count) n = count;
        memcpy(outData, ids, n * sizeof(AudioObjectID));
        *outSize = n * sizeof(AudioObjectID);
    } else {
        *outSize = count * sizeof(AudioObjectID);
    }
    return noErr;
}

static OSStatus GetProperty(AudioObjectID objectID, const AudioObjectPropertyAddress* addr,
                            UInt32 qualSize, const void* qual,
                            UInt32 inDataSize, UInt32* outSize, void* outData) {
    const AudioObjectPropertyScope scope = addr->mScope;

    switch (objectID) {
    // ---- Plug-in ----
    case kObjectID_PlugIn:
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:    RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:        RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(kManufacturerName));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID ids[] = { kObjectID_Device };
            return ReturnObjectList(ids, 1, inDataSize, outSize, outData);
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID result = kAudioObjectUnknown;
            if (outData) {
                if (qualSize < sizeof(CFStringRef) || qual == NULL) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = *(const CFStringRef*)qual;
                if (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) result = kObjectID_Device;
            }
            RETURN_VALUE(AudioObjectID, result);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        }
        break;

    // ---- Device ----
    case kObjectID_Device:
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:    RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:        RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:         RETURN_VALUE(CFStringRef, CFSTR(kDeviceName));
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(kManufacturerName));
        case kAudioDevicePropertyDeviceUID:    RETURN_VALUE(CFStringRef, CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID:     RETURN_VALUE(CFStringRef, CFSTR(kDeviceModelUID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain:  RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            // Selectable as an output for apps; never hijack the default microphone.
            RETURN_VALUE(UInt32, scope == kAudioObjectPropertyScopeInput ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency:      RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden:     RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioDevicePropertyNominalSampleRate: {
            pthread_mutex_lock(&gStateMutex);
            Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(Float64, rate);
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 n = kNumSampleRates;
            if (outData) {
                UInt32 fit = inDataSize / sizeof(AudioValueRange);
                if (fit < n) n = fit;
                AudioValueRange* ranges = (AudioValueRange*)outData;
                for (UInt32 i = 0; i < n; ++i) { ranges[i].mMinimum = kSampleRates[i]; ranges[i].mMaximum = kSampleRates[i]; }
            }
            *outSize = n * sizeof(AudioValueRange);
            return noErr;
        }
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID both[] = { kObjectID_Stream_Input, kObjectID_Stream_Output };
            if (scope == kAudioObjectPropertyScopeInput)  return ReturnObjectList(&both[0], 1, inDataSize, outSize, outData);
            if (scope == kAudioObjectPropertyScopeOutput) return ReturnObjectList(&both[1], 1, inDataSize, outSize, outData);
            return ReturnObjectList(both, 2, inDataSize, outSize, outData);
        }
        case kAudioObjectPropertyControlList:
            return ReturnObjectList(NULL, 0, inDataSize, outSize, outData);
        case kAudioDevicePropertyRelatedDevices: {
            AudioObjectID ids[] = { kObjectID_Device };
            return ReturnObjectList(ids, 1, inDataSize, outSize, outData);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (outData) {
                if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)outData)[0] = 1;
                ((UInt32*)outData)[1] = 2;
            }
            *outSize = 2 * sizeof(UInt32);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            if (outData) {
                if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                memset(layout, 0, size);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = kChannels;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            }
            *outSize = size;
            return noErr;
        }
        }
        break;

    // ---- Streams ----
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output: {
        const bool isInput = objectID == kObjectID_Stream_Input;
        switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:    RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:        RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: return ReturnObjectList(NULL, 0, inDataSize, outSize, outData);
        case kAudioStreamPropertyIsActive:     RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection:    RETURN_VALUE(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RETURN_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency:      RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            pthread_mutex_lock(&gStateMutex);
            AudioStreamBasicDescription f = MakeFormat(gSampleRate);
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(AudioStreamBasicDescription, f);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 n = kNumSampleRates;
            if (outData) {
                UInt32 fit = inDataSize / sizeof(AudioStreamRangedDescription);
                if (fit < n) n = fit;
                AudioStreamRangedDescription* out = (AudioStreamRangedDescription*)outData;
                for (UInt32 i = 0; i < n; ++i) {
                    out[i].mFormat = MakeFormat(kSampleRates[i]);
                    out[i].mSampleRateRange.mMinimum = kSampleRates[i];
                    out[i].mSampleRateRange.mMaximum = kSampleRates[i];
                }
            }
            *outSize = n * sizeof(AudioStreamRangedDescription);
            return noErr;
        }
        }
        break;
    }
    default:
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareUnknownPropertyError;
}

static Boolean AR_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid, const AudioObjectPropertyAddress* addr) {
    (void)pid;
    if (d != gDriverRef || addr == NULL) return false;
    UInt32 size = 0;
    // Qualifier-dependent properties still "exist" without a qualifier in size mode.
    return GetProperty(objectID, addr, 0, NULL, 0, &size, NULL) == noErr;
}

static OSStatus AR_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                                      const AudioObjectPropertyAddress* addr, Boolean* outIsSettable) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (addr == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus status = GetProperty(objectID, addr, 0, NULL, 0, &size, NULL);
    if (status != noErr) return status;
    *outIsSettable =
        (objectID == kObjectID_Device && addr->mSelector == kAudioDevicePropertyNominalSampleRate) ||
        ((objectID == kObjectID_Stream_Input || objectID == kObjectID_Stream_Output) &&
         (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat));
    return noErr;
}

static OSStatus AR_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                                       const AudioObjectPropertyAddress* addr, UInt32 qualSize, const void* qual, UInt32* outSize) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (addr == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(objectID, addr, qualSize, qual, 0, outSize, NULL);
}

static OSStatus AR_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                                   const AudioObjectPropertyAddress* addr, UInt32 qualSize, const void* qual,
                                   UInt32 inDataSize, UInt32* outSize, void* outData) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (addr == NULL || outSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(objectID, addr, qualSize, qual, inDataSize, outSize, outData);
}

static OSStatus RequestSampleRate(Float64 rate) {
    bool valid = false;
    for (UInt32 i = 0; i < kNumSampleRates; ++i) if (kSampleRates[i] == rate) valid = true;
    if (!valid) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    Float64 current = gSampleRate;
    pthread_mutex_unlock(&gStateMutex);
    if (current == rate || gHost == NULL) return noErr;
    return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)rate, NULL);
}

static OSStatus AR_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t pid,
                                   const AudioObjectPropertyAddress* addr, UInt32 qualSize, const void* qual,
                                   UInt32 inDataSize, const void* inData) {
    (void)pid; (void)qualSize; (void)qual;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (addr == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    if (objectID == kObjectID_Device && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return RequestSampleRate(*(const Float64*)inData);
    }
    if ((objectID == kObjectID_Stream_Input || objectID == kObjectID_Stream_Output) &&
        (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
        if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != kChannels || f->mBitsPerChannel != 32)
            return kAudioDeviceUnsupportedFormatError;
        return RequestSampleRate(f->mSampleRate);
    }
    UInt32 size = 0;
    OSStatus status = GetProperty(objectID, addr, 0, NULL, 0, &size, NULL);
    return status == noErr ? kAudioHardwareUnsupportedOperationError : status;
}

// ---------------------------------------------------------------------------------------------
// IO

static OSStatus AR_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID) {
    (void)clientID;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        memset(gRing, 0, sizeof(gRing));
    }
    ++gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus AR_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID) {
    (void)clientID;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) --gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus AR_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID,
                                    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)clientID;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 nextHostTime = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerPeriod);
    if (nextHostTime <= now) ++gNumberTimeStamps;
    *outSampleTime = (Float64)(gNumberTimeStamps * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus AR_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID, UInt32 op,
                                     Boolean* outWillDo, Boolean* outInPlace) {
    (void)clientID;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    bool willDo = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = willDo;
    if (outInPlace) *outInPlace = true;
    return noErr;
}

static OSStatus AR_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID, UInt32 op,
                                    UInt32 frames, const AudioServerPlugInIOCycleInfo* info) {
    (void)clientID; (void)op; (void)frames; (void)info;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return noErr;
}

static OSStatus AR_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID streamID, UInt32 clientID,
                                 UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info,
                                 void* mainBuffer, void* secondaryBuffer) {
    (void)clientID; (void)secondaryBuffer;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (mainBuffer == NULL || info == NULL) return noErr;
    Float32* buffer = (Float32*)mainBuffer;

    if (op == kAudioServerPlugInIOOperationWriteMix && streamID == kObjectID_Stream_Output) {
        // Mixed output of all client apps -> loopback ring, indexed by sample time.
        SInt64 start = (SInt64)info->mOutputTime.mSampleTime;
        for (UInt32 i = 0; i < frames; ++i) {
            UInt64 idx = (UInt64)(start + i) & kRingMask;
            gRing[idx * kChannels]     = buffer[i * kChannels];
            gRing[idx * kChannels + 1] = buffer[i * kChannels + 1];
        }
    } else if (op == kAudioServerPlugInIOOperationReadInput && streamID == kObjectID_Stream_Input) {
        // Input time lags output time, so these frames were already written. Clear after reading
        // so the input goes silent (instead of looping stale audio) when nothing is playing.
        SInt64 start = (SInt64)info->mInputTime.mSampleTime;
        for (UInt32 i = 0; i < frames; ++i) {
            UInt64 idx = (UInt64)(start + i) & kRingMask;
            buffer[i * kChannels]     = gRing[idx * kChannels];
            buffer[i * kChannels + 1] = gRing[idx * kChannels + 1];
            gRing[idx * kChannels]     = 0;
            gRing[idx * kChannels + 1] = 0;
        }
    }
    return noErr;
}

static OSStatus AR_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 clientID, UInt32 op,
                                  UInt32 frames, const AudioServerPlugInIOCycleInfo* info) {
    (void)clientID; (void)op; (void)frames; (void)info;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return noErr;
}
