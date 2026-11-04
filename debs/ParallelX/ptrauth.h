#pragma once
/* Minimal ptrauth.h for SDKs that omit it; clang provides the builtins. */
#ifdef __cplusplus
extern "C" {
#endif
typedef enum {
    ptrauth_key_asia = 0,
    ptrauth_key_asib = 1,
    ptrauth_key_asda = 2,
    ptrauth_key_asdb = 3,
    ptrauth_key_process_independent_code = ptrauth_key_asia,
    ptrauth_key_process_independent_data = ptrauth_key_asda,
    ptrauth_key_function_pointer = ptrauth_key_asia,
    ptrauth_key_return_address = ptrauth_key_asib,
    ptrauth_key_frame_pointer = ptrauth_key_asdb,
} ptrauth_key;
#define ptrauth_string_discriminator(s) __builtin_ptrauth_string_discriminator(s)
#ifdef __cplusplus
}
#endif
