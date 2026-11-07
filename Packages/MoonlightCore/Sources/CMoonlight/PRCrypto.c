#include "include/CMoonlight.h"
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/pkcs12.h>
#include <openssl/rand.h>
#include <openssl/err.h>
#include <openssl/crypto.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

void PRFree(void *p) { free(p); }

void PRFreeSecure(void *p, size_t len) {
    if (p == NULL) return;
    OPENSSL_cleanse(p, len);
    free(p);
}

static int bioToBuffer(BIO *bio, unsigned char **out, size_t *len) {
    BUF_MEM *mem = NULL;
    *out = NULL; *len = 0;
    BIO_get_mem_ptr(bio, &mem);
    if (mem == NULL) return -1;
    unsigned char *buf = malloc(mem->length > 0 ? mem->length : 1);
    if (buf == NULL) return -1;
    memcpy(buf, mem->data, mem->length);
    *out = buf;
    *len = mem->length;
    return 0;
}

static X509 *readCert(const unsigned char *pem, size_t len) {
    if (pem == NULL || len > INT_MAX) return NULL;
    BIO *bio = BIO_new_mem_buf(pem, (int)len);
    if (bio == NULL) return NULL;
    X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    BIO_free(bio);
    return cert;
}

int PRGenerateIdentity(const char *p12Password, unsigned char **certPEM, size_t *certLen,
                       unsigned char **keyPEM, size_t *keyLen, unsigned char **p12, size_t *p12Len) {
    int rc = -1;
    *certPEM = NULL; *certLen = 0;
    *keyPEM = NULL; *keyLen = 0;
    *p12 = NULL; *p12Len = 0;
    EVP_PKEY *key = EVP_RSA_gen(2048);
    X509 *cert = X509_new();
    BIO *certBio = BIO_new(BIO_s_mem()), *keyBio = BIO_new(BIO_s_mem()), *p12Bio = BIO_new(BIO_s_mem());
    PKCS12 *bundle = NULL;
    X509_NAME *name = NULL;
    if (!key || !cert || !certBio || !keyBio || !p12Bio) goto done;
    if (!X509_set_version(cert, 2)) goto done;
    if (!ASN1_INTEGER_set(X509_get_serialNumber(cert), 0)) goto done;
    if (!X509_gmtime_adj(X509_getm_notBefore(cert), 0)) goto done;
    if (!X509_gmtime_adj(X509_getm_notAfter(cert), 60L * 60 * 24 * 365 * 20)) goto done;
    if (!X509_set_pubkey(cert, key)) goto done;
    name = X509_get_subject_name(cert);
    if (!name) goto done;
    if (!X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)"PocketRig", -1, -1, 0)) goto done;
    if (!X509_set_issuer_name(cert, name)) goto done;
    if (!X509_sign(cert, key, EVP_sha256())) goto done;
    if (!PEM_write_bio_X509(certBio, cert)) goto done;
    if (!PEM_write_bio_PrivateKey(keyBio, key, NULL, NULL, 0, NULL, NULL)) goto done;
    // iOS SecPKCS12Import needs the classic SHA1/3DES PBE + SHA1 MAC.
    bundle = PKCS12_create_ex(p12Password, "PocketRig", key, cert, NULL,
                              NID_pbe_WithSHA1And3_Key_TripleDES_CBC, NID_pbe_WithSHA1And3_Key_TripleDES_CBC,
                              2048, 1, 0, NULL, NULL);
    if (!bundle || !PKCS12_set_mac(bundle, p12Password, -1, NULL, 0, 2048, EVP_sha1())) goto done;
    if (!i2d_PKCS12_bio(p12Bio, bundle)) goto done;
    if (bioToBuffer(certBio, certPEM, certLen) || bioToBuffer(keyBio, keyPEM, keyLen) ||
        bioToBuffer(p12Bio, p12, p12Len)) goto done;
    rc = 0;
done:
    if (rc != 0) {
        PRFree(*certPEM); *certPEM = NULL; *certLen = 0;
        PRFreeSecure(*keyPEM, *keyLen); *keyPEM = NULL; *keyLen = 0;
        PRFreeSecure(*p12, *p12Len); *p12 = NULL; *p12Len = 0;
        ERR_clear_error();
    }
    PKCS12_free(bundle); BIO_free(certBio); BIO_free(keyBio); BIO_free(p12Bio);
    X509_free(cert); EVP_PKEY_free(key);
    return rc;
}

int PRSignSHA256(const unsigned char *keyPEM, size_t keyLen, const unsigned char *data, size_t dataLen,
                 unsigned char **sig, size_t *sigLen) {
    int rc = -1;
    *sig = NULL; *sigLen = 0;
    BIO *bio = NULL;
    EVP_PKEY *key = NULL;
    EVP_MD_CTX *ctx = NULL;
    unsigned char *buf = NULL;
    size_t len = 0;
    if (keyPEM == NULL || keyLen > INT_MAX) goto done;
    bio = BIO_new_mem_buf(keyPEM, (int)keyLen);
    if (!bio) goto done;
    key = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    ctx = EVP_MD_CTX_new();
    if (!key || !ctx) goto done;
    if (EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, key) != 1) goto done;
    if (EVP_DigestSign(ctx, NULL, &len, data, dataLen) != 1) goto done;
    buf = malloc(len > 0 ? len : 1);
    if (buf == NULL) goto done;
    if (EVP_DigestSign(ctx, buf, &len, data, dataLen) != 1) goto done;
    *sig = buf; *sigLen = len; buf = NULL;
    rc = 0;
done:
    if (rc != 0) ERR_clear_error();
    free(buf);
    EVP_MD_CTX_free(ctx); EVP_PKEY_free(key); BIO_free(bio);
    return rc;
}

int PRVerifySHA256(const unsigned char *certPEM, size_t certLen, const unsigned char *data, size_t dataLen,
                   const unsigned char *sig, size_t sigLen) {
    int rc = -1;
    X509 *cert = readCert(certPEM, certLen);
    EVP_PKEY *key = cert ? X509_get_pubkey(cert) : NULL;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!key || !ctx) goto done;
    if (EVP_DigestVerifyInit(ctx, NULL, EVP_sha256(), NULL, key) != 1) goto done;
    rc = EVP_DigestVerify(ctx, sig, sigLen, data, dataLen) == 1 ? 1 : 0;
done:
    ERR_clear_error();
    EVP_MD_CTX_free(ctx); EVP_PKEY_free(key); X509_free(cert);
    return rc;
}

int PRCertSignature(const unsigned char *certPEM, size_t certLen, unsigned char **sig, size_t *sigLen) {
    *sig = NULL; *sigLen = 0;
    X509 *cert = readCert(certPEM, certLen);
    if (!cert) { ERR_clear_error(); return -1; }
    int rc = -1;
    const ASN1_BIT_STRING *bits = NULL;
    X509_get0_signature(&bits, NULL, cert);
    if (bits != NULL) {
        int n = ASN1_STRING_length(bits);
        if (n > 0) {
            unsigned char *buf = malloc((size_t)n);
            if (buf != NULL) {
                memcpy(buf, ASN1_STRING_get0_data(bits), (size_t)n);
                *sig = buf; *sigLen = (size_t)n;
                rc = 0;
            }
        }
    }
    if (rc != 0) ERR_clear_error();
    X509_free(cert);
    return rc;
}

int PRCertDER(const unsigned char *certPEM, size_t certLen, unsigned char **der, size_t *derLen) {
    *der = NULL; *derLen = 0;
    X509 *cert = readCert(certPEM, certLen);
    if (!cert) { ERR_clear_error(); return -1; }
    unsigned char *out = NULL;
    int len = i2d_X509(cert, &out);
    X509_free(cert);
    if (len <= 0) { ERR_clear_error(); return -1; }
    unsigned char *buf = malloc((size_t)len);
    if (buf == NULL) { OPENSSL_free(out); return -1; }
    memcpy(buf, out, (size_t)len);
    OPENSSL_free(out);
    *der = buf;
    *derLen = (size_t)len;
    return 0;
}

int PRAES128ECB(int encrypt, const unsigned char *key16, const unsigned char *in, size_t len, unsigned char *out) {
    if (len % 16 != 0 || len > INT_MAX) return -1;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int outLen = 0, finalLen = 0, rc = -1;
    if (!ctx) return -1;
    if (EVP_CipherInit_ex(ctx, EVP_aes_128_ecb(), NULL, key16, NULL, encrypt) != 1) goto done;
    EVP_CIPHER_CTX_set_padding(ctx, 0);
    if (EVP_CipherUpdate(ctx, out, &outLen, in, (int)len) != 1) goto done;
    if (EVP_CipherFinal_ex(ctx, out + outLen, &finalLen) != 1) goto done;
    rc = 0;
done:
    if (rc != 0) ERR_clear_error();
    EVP_CIPHER_CTX_free(ctx);
    return rc;
}
