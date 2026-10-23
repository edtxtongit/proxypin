import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../crypto.dart';
import 'cert_data.dart';
import 'key_usage.dart';
import 'x509.dart';

class CaCertificateChain {
  final String keyPem;
  final PrivateKey privateKey;
  final List<String> certificates;

  CaCertificateChain._(this.keyPem, this.privateKey, this.certificates);

  static List<String> splitPem(String pem) {
    return RegExp(r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----')
        .allMatches(pem)
        .map((match) => match.group(0)!)
        .toList();
  }

  factory CaCertificateChain.fromPems(List<String> pems) {
    final keys = pems.where((pem) => pem.contains('PRIVATE KEY')).toList();
    var certificatePems = pems;
    if (keys.isEmpty && pems.isNotEmpty) {
      CryptoUtils.privateKeyFromPem(pems.first);
      keys.add(X509Utils.encodeASN1ObjectToPem(
          _sequence(pems.first), CryptoUtils.BEGIN_PRIVATE_KEY, CryptoUtils.END_PRIVATE_KEY));
      certificatePems = pems.sublist(1);
    }
    final certificates = certificatePems.expand(splitPem).toSet().toList();
    if (keys.length != 1 || certificates.isEmpty) {
      throw ArgumentError('CA PKCS12 must contain one private key and at least one certificate');
    }
    final key = CryptoUtils.privateKeyFromPem(keys.single);
    final matching = certificates
        .where((pem) => X509Utils.x509CertificateFromPem(pem).extensions?.cA == true && _matchesKey(pem, key))
        .toList();
    if (matching.length != 1) {
      throw ArgumentError('CA PKCS12 must contain exactly one certificate matching its private key');
    }
    final ordered = <String>[matching.single];
    _requireCa(X509Utils.x509CertificateFromPem(ordered.first));
    final remaining = certificates.where((pem) => pem != ordered.first).toList();
    while (!_sameBytes(_name(ordered.last, false), _name(ordered.last, true))) {
      final parents = remaining.where((pem) => _isIssuer(ordered.last, pem)).toList();
      if (parents.isEmpty) {
        if (ordered.any((pem) => _isIssuer(ordered.last, pem))) {
          throw ArgumentError('CA certificate chain contains a cycle');
        }
        break;
      }
      if (parents.length != 1) {
        throw ArgumentError('CA certificate chain has ambiguous issuers');
      }
      final parent = parents.single;
      final details = X509Utils.x509CertificateFromPem(parent);
      _requireCa(details);
      final pathLength = details.extensions?.pathLenConstraint;
      if (pathLength != null && ordered.length > pathLength) {
        throw ArgumentError('CA certificate chain exceeds path length constraint');
      }
      ordered.add(parent);
      remaining.remove(parent);
    }
    return CaCertificateChain._(keys.single, key, List.unmodifiable(ordered));
  }

  String get pem => certificates.join('\n');

  String get handshakePem => certificates.where((pem) => !_sameBytes(_name(pem, false), _name(pem, true))).join('\n');

  static void _requireCa(X509CertificateData certificate) {
    if (certificate.extensions?.cA != true) {
      throw ArgumentError('Signing certificate must have CA:TRUE');
    }
    final usage = certificate.extensions?.keyUsage;
    if (usage != null && !usage.contains(KeyUsage.KEY_CERT_SIGN)) {
      throw ArgumentError('Signing certificate must permit certificate signing');
    }
  }

  static ASN1Sequence _sequence(String pem) {
    return ASN1Parser(CryptoUtils.getBytesFromPEMString(pem)).nextObject() as ASN1Sequence;
  }

  static ASN1Sequence _publicKeyInfo(String pem) {
    final certificate = _sequence(pem).elements!.first as ASN1Sequence;
    final offset = certificate.elements!.first is ASN1Integer ? -1 : 0;
    return certificate.elements![6 + offset] as ASN1Sequence;
  }

  static PublicKey _publicKey(String pem) {
    final info = _publicKeyInfo(pem);
    final algorithm = info.elements!.first as ASN1Sequence;
    final identifier = (algorithm.elements!.first as ASN1ObjectIdentifier).objectIdentifierAsString;
    if (identifier == '1.2.840.113549.1.1.1') {
      return CryptoUtils.rsaPublicKeyFromDERBytes(info.encode());
    }
    if (identifier == '1.2.840.10045.2.1') {
      final curve = algorithm.elements![1] as ASN1ObjectIdentifier;
      final parameters = CryptoUtils.ecParametersFromOid(curve.objectIdentifierAsString!);
      final encoded = info.elements![1] as ASN1BitString;
      return ECPublicKey(parameters.curve.decodePoint(Uint8List.fromList(encoded.stringValues!)), parameters);
    }
    throw ArgumentError('Unsupported CA public key algorithm: $identifier');
  }

  static bool _matchesKey(String pem, PrivateKey privateKey) {
    final publicKey = _publicKey(pem);
    if (privateKey is RSAPrivateKey && publicKey is RSAPublicKey) {
      return privateKey.modulus == publicKey.modulus;
    }
    if (privateKey is ECPrivateKey && publicKey is ECPublicKey) {
      return privateKey.parameters!.G * privateKey.d == publicKey.Q;
    }
    return false;
  }

  static Uint8List _name(String pem, bool subject) {
    final certificate = _sequence(pem).elements!.first as ASN1Sequence;
    final offset = certificate.elements!.first is ASN1Integer ? -1 : 0;
    return certificate.elements![(subject ? 5 : 3) + offset].encode();
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  static bool _isIssuer(String child, String parent) {
    if (!_sameBytes(_name(child, false), _name(parent, true))) return false;
    final certificate = _sequence(child);
    final algorithm = certificate.elements![1] as ASN1Sequence;
    final identifier = (algorithm.elements!.first as ASN1ObjectIdentifier).objectIdentifierAsString;
    final digest = switch (identifier) {
      '1.2.840.113549.1.1.5' || '1.2.840.10045.4.1' => 'SHA-1',
      '1.2.840.113549.1.1.14' || '1.2.840.10045.4.3.1' => 'SHA-224',
      '1.2.840.113549.1.1.11' || '1.2.840.10045.4.3.2' => 'SHA-256',
      '1.2.840.113549.1.1.12' || '1.2.840.10045.4.3.3' => 'SHA-384',
      '1.2.840.113549.1.1.13' || '1.2.840.10045.4.3.4' => 'SHA-512',
      _ => throw ArgumentError('Unsupported CA certificate signature: $identifier'),
    };
    final publicKey = _publicKey(parent);
    final encodedSignature = certificate.elements![2] as ASN1BitString;
    final bytes = Uint8List.fromList(encodedSignature.stringValues!);
    final Signature signature;
    final Signer signer;
    if (publicKey is RSAPublicKey) {
      signer = Signer('$digest/RSA')..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
      signature = RSASignature(bytes);
    } else if (publicKey is ECPublicKey) {
      signer = Signer('$digest/ECDSA')..init(false, PublicKeyParameter<ECPublicKey>(publicKey));
      final values = ASN1Parser(bytes).nextObject() as ASN1Sequence;
      signature = ECSignature(
        (values.elements![0] as ASN1Integer).integer!,
        (values.elements![1] as ASN1Integer).integer!,
      );
    } else {
      return false;
    }
    return signer.verifySignature(certificate.elements!.first.encode(), signature);
  }
}
