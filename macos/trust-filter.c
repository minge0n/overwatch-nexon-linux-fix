#include <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "pinned-root.h"

static const unsigned char self_signed_g4[CC_SHA256_DIGEST_LENGTH] = {
    0x55,0x2f,0x7b,0xdc,0xf1,0xa7,0xaf,0x9e,0x6c,0xe6,0x72,0x01,0x7f,0x4f,0x12,0xab,
    0xf7,0x72,0x40,0xc7,0x8e,0x76,0x1a,0xc2,0x03,0xd1,0xd9,0xd2,0x0a,0xc8,0x99,0x88
};

static void record_event(const char *event, unsigned int domain, unsigned int removed)
{
    const char *path = getenv("OW_NEXON_FILTER_LOG");
    if (!path) return;
    FILE *file = fopen(path, "a");
    if (!file) return;
    fprintf(file, "%s pid=%d domain=%u removed=%u\n", event, getpid(), domain, removed);
    fclose(file);
}

__attribute__((constructor)) static void loaded(void)
{
    record_event("loaded", 0, 0);
}

static OSStatus filtered_certificates(SecTrustSettingsDomain domain, CFArrayRef *certificates)
{
    OSStatus status = SecTrustSettingsCopyCertificates(domain, certificates);
    if (status != errSecSuccess || !certificates || !*certificates) return status;

    CFMutableArrayRef filtered = CFArrayCreateMutableCopy(NULL, 0, *certificates);
    if (!filtered) {
        CFRelease(*certificates);
        *certificates = NULL;
        return errSecAllocate;
    }
    unsigned int removed = 0;
    for (CFIndex index = CFArrayGetCount(filtered); index > 0; index--) {
        SecCertificateRef certificate = (SecCertificateRef)CFArrayGetValueAtIndex(filtered, index - 1);
        CFDataRef der = SecCertificateCopyData(certificate);
        if (!der) continue;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
        CFRelease(der);
        if (memcmp(digest, self_signed_g4, sizeof(digest)) == 0) {
            CFArrayRemoveValueAtIndex(filtered, index - 1);
            removed++;
        }
    }
    if (domain == kSecTrustSettingsDomainSystem) {
        CFDataRef data = CFDataCreate(NULL, pinned_root_der, sizeof(pinned_root_der));
        SecCertificateRef pinned = data ? SecCertificateCreateWithData(NULL, data) : NULL;
        if (data) CFRelease(data);
        if (!pinned) {
            CFRelease(filtered);
            CFRelease(*certificates);
            *certificates = NULL;
            return errSecAllocate;
        }
        if (!CFArrayContainsValue(filtered, CFRangeMake(0, CFArrayGetCount(filtered)), pinned)) {
            CFArrayAppendValue(filtered, pinned);
            record_event("pinned-added", (unsigned int)domain, 0);
        }
        CFRelease(pinned);
    }
    CFRelease(*certificates);
    *certificates = filtered;

    record_event("filtered", (unsigned int)domain, removed);
    return status;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interpose = {
    (const void *)filtered_certificates, (const void *)SecTrustSettingsCopyCertificates
};
