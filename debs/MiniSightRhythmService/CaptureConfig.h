#pragma once
// Source-review default: no constructor, hooks, socket, sampling or startup.
// A future explicit opt-in build needs separate user authorization to run.
#ifndef MINISIGHT_ENABLE_RHYTHM_CAPTURE
#define MINISIGHT_ENABLE_RHYTHM_CAPTURE 0
#endif
#if MINISIGHT_ENABLE_RHYTHM_CAPTURE != 0 && MINISIGHT_ENABLE_RHYTHM_CAPTURE != 1
#error MINISIGHT_ENABLE_RHYTHM_CAPTURE_must_be_0_or_1
#endif
