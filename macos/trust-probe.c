#include <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>

static int inspect_domain(SecTrustSettingsDomain domain)
{
    CFArrayRef certificates = NULL;
    OSStatus status = SecTrustSettingsCopyCertificates(domain, &certificates);
    printf("status %u %d\n", (unsigned int)domain, (int)status);
    if (status != errSecSuccess || !certificates) return 0;
    for (CFIndex index = 0; index < CFArrayGetCount(certificates); index++) {
        SecCertificateRef certificate = (SecCertificateRef)CFArrayGetValueAtIndex(certificates, index);
        CFDataRef der = SecCertificateCopyData(certificate);
        if (!der) { CFRelease(certificates); return 1; }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
        CFRelease(der);
        printf("cert %u ", (unsigned int)domain);
        for (size_t byte = 0; byte < sizeof(digest); byte++) printf("%02x", digest[byte]);
        putchar('\n');
    }
    CFRelease(certificates);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 2) return inspect_domain((SecTrustSettingsDomain)strtoul(argv[1], NULL, 10));
    const SecTrustSettingsDomain domains[] = {
        kSecTrustSettingsDomainSystem, kSecTrustSettingsDomainAdmin, kSecTrustSettingsDomainUser
    };
    for (size_t index = 0; index < sizeof(domains) / sizeof(domains[0]); index++) {
        if (inspect_domain(domains[index])) return 1;
    }
    return 0;
}
