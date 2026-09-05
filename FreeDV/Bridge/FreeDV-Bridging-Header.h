#ifndef FreeDV_Bridging_Header_h
#define FreeDV_Bridging_Header_h

#include <TargetConditionals.h>

/* Objective-C exception guard (all platforms, including the simulator):
   returns AVFAudio precondition NSExceptions to Swift instead of aborting. */
#import "FDVExceptionGuard.h"

#if !TARGET_OS_SIMULATOR

/* RADE C API - Swift can call these directly */
#include "rade_api.h"

/* Opus DNN - FARGAN vocoder and LPCNet feature extraction */
#include "lpcnet.h"
#include "fargan.h"

/* cpu_support.h defines opus_select_arch() as static inline,
   which Swift cannot import. Provide a non-static wrapper. */
#include "cpu_support.h"
static inline int32_t freedv_opus_select_arch(void) {
    return (int32_t)opus_select_arch();
}

/* EOO Callsign Codec - C wrapper for C++ EooCallsignDecoder */
#include "eoo_callsign_codec_c.h"

#endif /* !TARGET_OS_SIMULATOR */

#endif /* FreeDV_Bridging_Header_h */
