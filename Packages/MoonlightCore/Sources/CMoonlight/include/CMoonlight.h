#pragma once
#include "../moonlight-common-c/src/Limelight.h"
#include <stddef.h>

typedef void (*PRLogSink)(const char *message);
/// Swift can't implement C variadic callbacks; this installs a C trampoline that formats and forwards.
void PRSetLogSink(PRLogSink sink);
void PRInstallLogCallback(PCONNECTION_LISTENER_CALLBACKS callbacks);

// Functions return 0 on success, non-zero on failure (PRVerifySHA256: 1 valid, 0 invalid, -1 error;
// PRFree/PRFreeSecure are void). Pointer outputs are set to NULL/0 on entry and left NULL/0 on failure.
// Free outputs with PRFree (or PRFreeSecure for key material).
int PRGenerateIdentity(const char *p12Password,
                       unsigned char **certPEM, size_t *certLen,
                       unsigned char **keyPEM, size_t *keyLen,
                       unsigned char **p12, size_t *p12Len);
int PRSignSHA256(const unsigned char *keyPEM, size_t keyLen, const unsigned char *data, size_t dataLen,
                 unsigned char **sig, size_t *sigLen);
/// Returns 1 valid, 0 invalid, -1 error.
int PRVerifySHA256(const unsigned char *certPEM, size_t certLen, const unsigned char *data, size_t dataLen,
                   const unsigned char *sig, size_t sigLen);
int PRCertSignature(const unsigned char *certPEM, size_t certLen, unsigned char **sig, size_t *sigLen);
int PRCertDER(const unsigned char *certPEM, size_t certLen, unsigned char **der, size_t *derLen);
int PRAES128ECB(int encrypt, const unsigned char *key16, const unsigned char *in, size_t len, unsigned char *out);
void PRFree(void *p);
/// Zeroes len bytes with OPENSSL_cleanse, then frees.
void PRFreeSecure(void *p, size_t len);
