# PQC Readiness: Katello Internal Certificate Handling

Tracking remaining work to make Katello's internal cert/key handling
algorithm-agnostic for post-quantum cryptography (PQC) support.

Updated: July 2026

## Status

### Done: Key Parsing (OpenSSL::PKey.read)

PR in progress. All 7 production occurrences of `OpenSSL::PKey::RSA.new(pem_data)`
changed to `OpenSSL::PKey.read(pem_data)` for algorithm-agnostic key loading.

Files changed:
- `app/services/cert/certs.rb` -- Foreman-to-Pulp client key
- `app/lib/actions/katello/cdn_configuration/update.rb` -- CDN debug cert keypair
- `app/lib/katello/resources/candlepin/owner.rb` -- ueber cert for PKCS12
- `app/lib/katello/resources/candlepin.rb` -- Candlepin REST client SSL key
- `app/lib/katello/resources/cdn.rb` (2 sites) -- product key for Red Hat and custom CDN
- `app/services/katello/pxe_files_downloader.rb` -- ueber cert key for PXE download

Test code (`OpenSSL::PKey::RSA.new(2048)` for key generation) left unchanged --
those create RSA test fixtures, not parse arbitrary keys.

### Remaining: PKCS12 Creation with Hardcoded Algorithms

`app/lib/katello/resources/candlepin/owner.rb` line 117:

```ruby
def get_ueber_cert_pkcs12(key, name = nil, password = nil)
  certs = get_ueber_cert(key)
  c = OpenSSL::X509::Certificate.new certs["cert"]
  p = OpenSSL::PKey.read certs["key"]
  OpenSSL::PKCS12.create(password, name, p, c, nil, "PBE-SHA1-3DES", "PBE-SHA1-3DES")
end
```

Problems:
1. PKCS12 is an RSA-era container format. `OpenSSL::PKCS12.create` may not accept
   PQC key types depending on the OpenSSL version.
2. The `PBE-SHA1-3DES` encryption algorithms are classical crypto tied to the
   PKCS12 legacy format.
3. If PQC keys are used for ueber certs, this method will likely raise an error
   at PKCS12 creation time even though the key parsing now succeeds.

Possible fix: switch to PEM-based cert transport instead of PKCS12, or use
a PKCS12 encryption algorithm compatible with PQC keys (if one exists in the
OpenSSL version on the host). Needs investigation into what consumers of
`get_ueber_cert_pkcs12` actually require.

## Stack-Wide Dependencies

Katello code changes alone are not sufficient. Full PQC cert support requires:

| Layer | What's Needed | Status |
|-------|---------------|--------|
| Host OpenSSL | 3.5+ or oqs-provider for ML-DSA support | Not yet in RHEL packages |
| Ruby openssl gem | Must be compiled against PQC-capable OpenSSL | Depends on host OpenSSL |
| Pulp 3 (Python) | TLS client must handle PQC certs | Unknown |
| Candlepin (Java) | SSL stack needs PQC-aware JCE providers | Unknown |
| Apache/Nginx | Reverse proxy TLS termination | Depends on host OpenSSL |
| puppet-certs / katello-certs-check | Must generate PQC certs | Unknown |

## Notes

- `OpenSSL::PKey.read` returns the same subclass as the type-specific constructors
  (e.g., `OpenSSL::PKey::RSA` for RSA keys). It is a safe drop-in replacement for
  key parsing -- confirmed in Ruby console testing.
- No `OpenSSL::PKey::EC.new` or `OpenSSL::PKey::DSA.new` calls exist in Katello
  production code. The RSA assumption was the only type-specific key loading.
- Foreman core only had `OpenSSL::PKey::RSA.new` in test code (OIDC JWT tests),
  not production code.
- See also: `pqc-rpm-signatures.md` for RPM-level PQC signature support (separate concern).
