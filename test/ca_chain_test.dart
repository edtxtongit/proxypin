import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pointycastle/export.dart';
import 'package:proxypin/network/util/cert/basic_constraints.dart';
import 'package:proxypin/network/util/cert/ca_chain.dart';
import 'package:proxypin/network/util/cert/key_usage.dart';
import 'package:proxypin/network/util/cert/pkcs12.dart';
import 'package:proxypin/network/util/cert/x509.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/network/util/crypto.dart';

class _TestPaths extends PathProviderPlatform {
  final String path;

  _TestPaths(this.path);

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late String rootPem;
  late String rootKey;
  late String signingPem;
  late String signingKey;
  late String extraLeaf;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('proxypin-ca-chain-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    rootPem = await File('assets/certs/ca.crt').readAsString();
    rootKey = await File('assets/certs/ca_key.pem').readAsString();
    rootKey =
        rootKey.replaceAll('BEGIN CERTIFICATE', 'BEGIN PRIVATE KEY').replaceAll('END CERTIFICATE', 'END PRIVATE KEY');
    final pair = CryptoUtils.generateRSAKeyPair();
    signingKey = CryptoUtils.encodeRSAPrivateKeyToPem(pair.privateKey as RSAPrivateKey);
    signingPem = X509Utils.generateSelfSignedCertificate(
      X509Utils.x509CertificateFromPem(rootPem),
      pair.publicKey as RSAPublicKey,
      CryptoUtils.privateKeyFromPem(rootKey),
      365,
      subject: {'2.5.4.3': 'ProxyPin intermediate test CA'},
      issuerRawBytes: X509Utils.subjectDnBytesFromPem(rootPem),
      keyUsage: ExtensionKeyUsage(ExtensionKeyUsage.keyCertSign),
      basicConstraints: BasicConstraints(isCA: true, pathLenConstraint: 0),
    );
    extraLeaf = CertificateManager.generate(
      X509Utils.x509CertificateFromPem(signingPem),
      pair.publicKey as RSAPublicKey,
      CryptoUtils.privateKeyFromPem(signingKey),
      'unrelated.example',
    );
  });

  tearDown(() => CertificateManager.cleanCache());

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  Future<void> handshake(String trustedPem) async {
    final context = await CertificateManager.getCertificateContext('localhost');
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
    final trust = SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(trustedPem.codeUnits);
    final accepted = server.first;
    SecureSocket? client;
    SecureSocket? peer;
    try {
      client = await SecureSocket.connect('localhost', server.port, context: trust);
      peer = await accepted;
      peer.write('ca-chain-ok');
      await peer.flush();
      expect(String.fromCharCodes(await client.first), 'ca-chain-ok');
    } finally {
      client?.destroy();
      peer?.destroy();
      await server.close();
    }
  }

  test('single RSA CA remains compatible', () async {
    final p12 = Pkcs12.generatePkcs12(rootKey, [rootPem], password: 'test');
    await CertificateManager.importPkcs12(p12, 'test');
    expect(CaCertificateChain.splitPem(await CertificateManager.certificatePem()), hasLength(1));
    await handshake(rootPem);
  });

  test('sorts CA chain, filters extra leaf, reloads and exports full chain', () async {
    final p12 = Pkcs12.generatePkcs12(signingKey, [rootPem, extraLeaf, signingPem], password: 'test');
    await CertificateManager.importPkcs12(p12, 'test');
    final saved = CaCertificateChain.splitPem(await CertificateManager.certificatePem());
    expect(saved.map(CryptoUtils.getBytesFromPEMString), [signingPem, rootPem].map(CryptoUtils.getBytesFromPEMString));
    final exported = Pkcs12.parsePkcs12(await CertificateManager.generatePkcs12('roundtrip'), password: 'roundtrip');
    expect(exported.sublist(1), saved);
    await CertificateManager.importPkcs12(await CertificateManager.generatePkcs12('roundtrip'), 'roundtrip');
    await handshake(rootPem);
  });

  test('rejects invalid CA before overwriting existing configuration', () async {
    final before = await CertificateManager.certificatePem();
    final p12 = Pkcs12.generatePkcs12(signingKey, [extraLeaf], password: 'test');
    await expectLater(CertificateManager.importPkcs12(p12, 'test'), throwsArgumentError);
    expect(await CertificateManager.certificatePem(), before);
    expect(() => CaCertificateChain.fromPems([rootKey, signingKey, rootPem]), throwsArgumentError);
    expect(() => CaCertificateChain.fromPems([signingKey, rootPem]), throwsArgumentError);
  });

  final samplePath = Platform.environment['PROXYPIN_TEST_P12'];
  final samplePassword = Platform.environment['PROXYPIN_TEST_P12_PASSWORD'];
  test('supplied EC P12: import, reload, root omission and verified TLS handshake', () async {
    final bytes = await File(samplePath!).readAsBytes();
    final decoded = Pkcs12.parsePkcs12(bytes, password: samplePassword);
    final chain = CaCertificateChain.fromPems(decoded);
    expect(chain.privateKey, isA<ECPrivateKey>());
    expect(chain.certificates, hasLength(3));
    expect(CaCertificateChain.splitPem(chain.handshakePem), hasLength(2));
    await CertificateManager.importPkcs12(bytes, samplePassword);
    expect(CaCertificateChain.splitPem(await CertificateManager.certificatePem()), chain.certificates);
    final exported = await CertificateManager.generatePkcs12(samplePassword);
    await CertificateManager.importPkcs12(exported, samplePassword);
    await handshake(chain.certificates.last);
    final withoutRoot = Pkcs12.generatePkcs12(
        chain.keyPem, chain.certificates.sublist(0, chain.certificates.length - 1),
        password: samplePassword);
    await CertificateManager.importPkcs12(withoutRoot, samplePassword);
    expect(CaCertificateChain.splitPem(await CertificateManager.certificatePem()), hasLength(2));
    await handshake(chain.certificates.last);
  }, skip: samplePath == null ? 'Set PROXYPIN_TEST_P12 and PROXYPIN_TEST_P12_PASSWORD for private acceptance' : false);
}
