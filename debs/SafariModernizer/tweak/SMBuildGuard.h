// Compile-time guard only. No runtime PAC stripping or pointer rewriting.
// The release artifact must ALSO pass tools/verify_macho.py.
#pragma once

#ifndef __has_feature
#define __has_feature(x) 0
#endif

#if !defined(__APPLE__) || !defined(__MACH__) || !defined(__apple_build_version__)
#error SafariModernizer compatibility build requires Apple clang targeting iOS.
#endif
#if !defined(__arm64e__) || !__has_feature(ptrauth_calls)
#error SafariModernizer compatibility build requires the arm64e pointer-auth ABI.
#endif
#if !defined(SM_TARGET_ROOTHIDE) || SM_TARGET_ROOTHIDE != 1
#error SafariModernizer compatibility build requires the native RootHide scheme.
#endif

#include <TargetConditionals.h>
#include <Availability.h>
#if !TARGET_OS_IOS || TARGET_OS_SIMULATOR || TARGET_OS_MACCATALYST
#error Build for the iOS device, not the simulator or Catalyst.
#endif
#if __IPHONE_OS_VERSION_MAX_ALLOWED != 150500
#error The SDK must be exactly iPhoneOS15.5.sdk, without latest-SDK fallback.
#endif
#if __IPHONE_OS_VERSION_MIN_REQUIRED != 150000
#error The deployment target for this rebuild must be iOS 15.0.
#endif
