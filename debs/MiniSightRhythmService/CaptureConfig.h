#pragma once
// Source-review default: no constructor, hooks, socket, sampling or startup.
// A future explicit opt-in build needs separate user authorization to run.
#ifndef MINISIGHT_ENABLE_RHYTHM_CAPTURE
#define MINISIGHT_ENABLE_RHYTHM_CAPTURE 0
#endif
#if MINISIGHT_ENABLE_RHYTHM_CAPTURE != 0 && MINISIGHT_ENABLE_RHYTHM_CAPTURE != 1
#error MINISIGHT_ENABLE_RHYTHM_CAPTURE_must_be_0_or_1
#endif
#if MINISIGHT_ENABLE_RHYTHM_CAPTURE && (!MINISIGHT_ENABLE_RHYTHM_TRANSPORT || !MINISIGHT_RHYTHM_LIVE_BUILD)
#error LIVE_capture_requires_paired_transport_and_explicit_LIVE_build
#endif
