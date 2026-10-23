# Capture CA certificate chains

The existing root certificate import accepts a P12/PFX containing one RSA or EC
private key and multiple certificates. The certificate matching the key must be
a signing CA (`CA:TRUE`, with `keyCertSign` if key usage is present).

The proxy verifies issuer signatures, orders the chain from the signing CA to
its ancestors, and discards unrelated certificates. It saves the ordered chain
in `ca.crt` and retains it during P12 export. TLS sends the generated hostname
certificate followed by the intermediate CAs, omitting self-issued roots.
The root certificate may be absent from the imported P12; clients still need
the appropriate trust anchor. No import UI changes are required.

Run the minimum regression suite:

```sh
flutter test test/p12_verify_test.dart test/cert_san_test.dart test/ca_chain_test.dart
```

Run private EC P12 acceptance without committing the P12 or its password:

```sh
PROXYPIN_TEST_P12=/absolute/path/test.p12 \
PROXYPIN_TEST_P12_PASSWORD="$P12_PASSWORD" \
flutter test test/ca_chain_test.dart
```

This exercises the real CA importer, persistent storage, P12 re-export and
re-import, and a local TLS handshake with certificate verification enabled,
both with and without the supplied root certificate.

The `Android debugversion` Actions workflow publishes a release-mode APK with
application ID `com.network.proxy.debugversion`. Native Kotlin packages and
the Android namespace remain unchanged. The workflow reuses the successful
`zhou-kkk/proxypin-build` Android build configuration and publishes an APK
artifact and a prerelease. It uses repository signing secrets if configured,
otherwise a CI-generated test signing key, not the upstream production key.
