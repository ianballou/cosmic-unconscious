# Post-Quantum Cryptography (PQC) for RPM Signatures

General reference on PQC RPM signature support across the Foreman/Katello ecosystem,
RHEL 9, and RHEL 10. Updated June 2026.

## Background

NIST finalized three post-quantum cryptographic standards in 2024:
- **FIPS 203 (ML-KEM)** — key encapsulation (replaces RSA/ECDH key exchange)
- **FIPS 204 (ML-DSA)** — digital signatures (replaces RSA/ECDSA/EdDSA signing)
- **FIPS 205 (SLH-DSA)** — stateless hash-based signatures (backup to ML-DSA)

For RPM signatures, **ML-DSA** is the relevant standard. RPMs use OpenPGP signatures,
and the IETF is standardizing PQC in OpenPGP via
[draft-ietf-openpgp-pqc](https://datatracker.ietf.org/doc/draft-ietf-openpgp-pqc/)
(active Standards Track, revision 17+ as of June 2026, not yet an RFC).

## ML-DSA Variants Used in RPM

| Variant | Security Level | Signature Size | Used By |
|---------|---------------|----------------|---------|
| ML-DSA-65+Ed25519 | NIST Level 3 (~128-bit PQ) | ~3.3 KB | rpm-rs test fixtures, lighter option |
| ML-DSA-87+Ed448 | NIST Level 5 (~256-bit PQ) | ~4.6 KB | **Red Hat production** signing |

Both are "composite" algorithms — the signature contains both a classical (Ed25519 or Ed448)
and a post-quantum (ML-DSA) component. Verification requires both to pass.

## RPM Format: v4 vs v6 Signatures

PQC signatures use the new **RPM v6 signature format** (`RPMTAG_OPENPGP`, tag 278):

| Feature | RPM v4 (legacy) | RPM v6 (new) |
|---------|-----------------|--------------|
| Signature tag | `RPMSIGTAG_RSA` / `RPMSIGTAG_DSA` (binary) | `RPMTAG_OPENPGP` (base64 string array) |
| Multiple signatures | No (one per package) | Yes (independent signatures, any algorithm) |
| PQC support | No | Yes — algorithm-agnostic, delegates to OpenPGP |
| Header-only signing | No (header+payload) | Yes (header-only, no rewriting needed to add sigs) |
| Backward compat | — | v6 packages can carry a v4 legacy signature too |

Key upstream tracking:
- [rpm#3385](https://github.com/rpm-software-management/rpm/issues/3385) — RFE for multiple OpenPGP signatures (merged in rpm 6.0-alpha)
- [rpm#3713](https://github.com/rpm-software-management/rpm/issues/3713) — Backport multiple signature support to RPM 4.20 (RHEL 10's rpm version)
- [rpm#3715](https://github.com/rpm-software-management/rpm/pull/3715) — Backport PR (merged)

## Red Hat's Dual-Signing Approach

Starting with RHEL 9.7, Red Hat **dual-signs all shipped packages** with both classical
and post-quantum signatures:

```
Header V6 ML-DSA-87+Ed448/SHA512 Signature, key ID 05707a62: OK
Header V4 RSA/SHA256 Signature, key ID fd431d51: OK
```

Two GPG keys ship with `redhat-release`:
- `/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release` — classical RSA
- `/etc/pki/rpm-gpg/RPM-GPG-KEY-PQC-redhat-release` — post-quantum ML-DSA-87+Ed448

## RHEL 9: PQC Verification via Plugin

**Documentation**: [RHEL 9 Security Hardening — Verifying RPM packages with post-quantum signatures](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/verifying-rpm-packages-with-post-quantum-signatures_security-hardening)

RHEL 9.7+ supports PQC RPM signature verification through a **dnf plugin**:

```bash
# Install the multisig plugin and PQC RPM tools
dnf install dnf-plugin-multisig

# Import PQC public key into the dedicated pqrpm keyring
/usr/lib/pqrpm/bin/rpmkeys --import /etc/pki/rpm-gpg/RPM-GPG-KEY-PQC-redhat-release

# After this, dnf operations automatically verify v6 PQC signatures
# via the multisig plugin — no changes to existing workflows
```

The plugin hooks into dnf's transaction pipeline and verifies v6 signatures
using a separate `pqrpm` binary (a standalone rpm build with PQC-capable
crypto backend). The classical v4 signature is verified by the system rpm
as usual.

## RHEL 10: Native PQC Verification

**Documentation**: [RHEL 10 Security Hardening — Verifying RPM packages with post-quantum signatures](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/security_hardening/verifying-rpm-packages-with-post-quantum-signatures_security-hardening)

RHEL 10.1+ has **native** v6 signature support in the system rpm — no plugin needed:

```bash
# Import the PQC public key into the standard rpm keyring
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-PQC-redhat-release

# Verification happens automatically
# rpm --checksig shows both signature types
rpm --checksig package.rpm
# package.rpm: ... V6 ML-DSA-87+Ed448/SHA512 ... OK
```

When a package has a v6 signature, RHEL 10 verifies it automatically and
ignores any legacy v4 signatures. The `rpm -qi` output shows:
```
Signature: ML-DSA-87+Ed448/SHA512, <date>, Key ID <fingerprint>
```

## Pulp / Katello / Foreman Impact

Pulp's role in the RPM signature chain is primarily **content proxy**, not signature verifier:

1. **Sync**: Pulp downloads RPMs and stores them as opaque blobs. It does not verify
   individual RPM OpenPGP signatures during sync. PQC-signed RPMs should sync without issues.

2. **Content Credentials (GPG Keys)**: When a GPG key is added to a Katello product,
   it's passed to clients via `gpgkey=` in repo config files. Clients use it for
   verification. The key content is treated as opaque text by Katello.

3. **Package Signing Service**: Pulp 3.26+ has Tech Preview for signing RPMs on upload
   via `RpmPackageSigningService`, but this uses `rpmsign` under the hood and is separate
   from the sync-and-distribute flow.

4. **Repodata metadata signing**: `createrepo_c` / `gpg` sign repodata (`repomd.xml.asc`),
   which is separate from individual RPM signatures.

The key question for Foreman/Katello is whether `createrepo_c` and Pulp's metadata
generation correctly handle RPMs containing `RPMTAG_OPENPGP` v6 signature tags without
stripping or corrupting them. This is an area that needs testing.

**Current status**: Foreman/Katello documentation does not explicitly claim PQC support
or non-support. The RPM pass-through architecture suggests it should work, but no
automated test coverage exists.

## rpm-rs: The Tooling Bridge

[rpm-rs](https://github.com/rpm-rs/rpm-rs) is a pure-Rust RPM library with Python bindings
(`rpm-rs` on PyPI). It is the most accessible tool for generating PQC-signed RPMs
programmatically:

- Supports ML-DSA-65+Ed25519 and ML-DSA-87+Ed448 signing and verification
- Uses the `pgp` Rust crate with `draft-pqc` feature flag
- Can build v4 and v6 format RPMs with any combination of classical + PQC signatures
- Python API exposes `Signer`, `Verifier`, `PackageBuilder`, `BuildConfig`
- Ships test key pairs and pre-signed fixture RPMs for ML-DSA-65+Ed25519

### Verified Working (June 2026)

```python
import rpm_rs

# Build a v6 RPM
builder = rpm_rs.PackageBuilder('pqc-test', '1.0.0', 'MIT', 'noarch', 'PQC test')
builder.using_config(rpm_rs.BuildConfig(format=rpm_rs.RpmFormat.V6))
builder.release('1.el10')
pkg = builder.build()

# Sign with ML-DSA-65+Ed25519
signer = rpm_rs.Signer(secret_key_bytes)
pkg.sign(signer)

# Verify
verifier = rpm_rs.Verifier(public_key_bytes)
report = pkg.check_signatures(verifier)
sig = report.signatures[0]
# sig.info.algorithm == "ML-DSA-65+Ed25519"
# sig.is_verified() == True

# System rpm recognizes the signature:
# rpm -qip pqc-test.rpm →
#   Signature: ML-DSA-65+Ed25519/SHA256, ..., Key ID 23cde04477b8bbcf
#   (NOTTRUSTED only because key not in keyring — crypto is fully parsed)
```

### Upstream PQC Readiness Signals to Watch

1. **rpm-rs `tests/compat.rs`** — contains `TODO: add ML-DSA to matrix once support exists`
   for CentOS Stream 10 and Fedora. When resolved, the C rpm tool on those distros
   can fully verify ML-DSA signatures in the test matrix.

2. **Sequoia-PGP** — ML-DSA is implemented but the main PQC merge request
   ([MR !1789](https://gitlab.com/sequoia-pgp/sequoia/-/merge_requests/1789))
   is still in draft, waiting for v6/crypto-refresh merge. The Nettle backend
   (used by some distros) lacks ML-DSA — OpenSSL backend is required.
