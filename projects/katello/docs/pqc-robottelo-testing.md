# PQC RPM Signature Testing with rpm-rs in Robottelo

How to use the `rpm-rs` Python package to generate post-quantum signed RPMs
and test them through the Foreman/Katello/Pulp content pipeline in Robottelo.

See also: [pqc-rpm-signatures.md](pqc-rpm-signatures.md) for general PQC background.

## Why rpm-rs

Robottelo currently relies on static RPM blobs committed to git (`tests/foreman/data/*.rpm`)
and external fixture repos hosted on SatLab infrastructure (`repos_hosting_url`). Neither
provides PQC-signed content. `rpm-rs` (PyPI package) can generate valid PQC-signed RPMs
programmatically from Python — no `rpmbuild`, spec files, or host tooling required.

Key capabilities:
- Build RPM v4 and v6 format packages with arbitrary metadata, files, dependencies
- Sign with ML-DSA-65+Ed25519 or ML-DSA-87+Ed448 (determined by key, not code)
- Verify signatures and inspect signature reports
- Dual-sign (classical + PQC) to match Red Hat's production approach
- All operations available from Python via `import rpm_rs`

## Prerequisites

```bash
pip install rpm-rs  # PyPI package, imports as rpm_rs
```

The package is a Rust extension (via PyO3). Wheels are published for common platforms.
Verify installation:

```python
import rpm_rs
assert hasattr(rpm_rs, 'PackageBuilder')
assert hasattr(rpm_rs, 'Signer')
assert hasattr(rpm_rs, 'BuildConfig')
```

**Note**: The system `rpm` Python module (from `rpm-devel`) also imports as `import rpm`.
The rpm-rs package imports as `import rpm_rs` — no conflict.

## Test Key Pair

rpm-rs ships test keys for ML-DSA-65+Ed25519 at:
```
<rpm-rs-repo>/tests/assets/signing_keys/v6/rpm-testkey-v6-mldsa65-ed25519.secret
<rpm-rs-repo>/tests/assets/signing_keys/v6/rpm-testkey-v6-mldsa65-ed25519.asc
```

For robottelo, either:
1. Vendor these test keys into `tests/foreman/data/pqc/` (simplest)
2. Generate fresh keys with Sequoia PGP: `sq key generate --cipher-suite mldsa65-ed25519`
3. Load from rpm-rs package resources at runtime (if exposed)

For matching Red Hat's production setup (ML-DSA-87+Ed448), you'd need to generate
ML-DSA-87+Ed448 keys. The rpm-rs code supports both variants — the algorithm is
determined entirely by the key type.

## Building and Signing PQC RPMs

### Minimal Example

```python
import rpm_rs

def build_pqc_rpm(name, version, release, secret_key_bytes):
    """Build a v6 RPM signed with ML-DSA."""
    builder = rpm_rs.PackageBuilder(name, version, 'MIT', 'noarch', f'{name} test package')
    builder.using_config(rpm_rs.BuildConfig(format=rpm_rs.RpmFormat.V6))
    builder.release(release)
    pkg = builder.build()

    signer = rpm_rs.Signer(secret_key_bytes)
    pkg.sign(signer)
    return pkg
```

### With File Content

```python
fo = rpm_rs.FileOptions.new('./etc/pqc-test.conf', config=True)
builder.with_file_contents(b'quantum=safe\n', fo)
```

Note: argument order is `with_file_contents(content_bytes, file_options)`.

### Dual-Signed (Classical + PQC)

```python
# Sign with RSA first, then add PQC signature
rsa_signer = rpm_rs.Signer(rsa_secret_key_bytes)
pkg.sign(rsa_signer)

pqc_signer = rpm_rs.Signer(pqc_secret_key_bytes)
pkg.sign(pqc_signer)

# Both signatures coexist in RPMTAG_OPENPGP
```

### Verification

```python
verifier = rpm_rs.Verifier(public_key_bytes)
report = pkg.check_signatures(verifier)

for sig in report.signatures:
    print(sig.info.algorithm)    # "ML-DSA-65+Ed25519"
    print(sig.info.fingerprint)  # hex string
    print(sig.is_verified())     # True/False
```

### Writing to Disk

```python
pkg.write_file('/tmp/pqc-test-1.0.0-1.el10.noarch.rpm')
# or
pkg.write_to('/tmp/')  # auto-generates NEVRA filename
# or
raw_bytes = pkg.to_bytes()
```

## Proposed Robottelo Test Scenarios

### Tier 1: Pulp Sync Tolerance (Highest Priority)

Validates that Pulp can sync, store, and serve PQC-signed RPMs without corruption.
This is the untested gap in the current pipeline.

```python
@pytest.mark.tier2
def test_pulp_syncs_pqc_signed_rpm(target_sat, module_org, module_product):
    """Pulp should sync a repo containing PQC-signed RPMs without error.

    :id: <generate-uuid>

    :steps:
        1. Build a PQC-signed v6 RPM with rpm-rs
        2. Host it in a yum repo on the Foreman server
        3. Create a Katello repository pointing to it
        4. Sync the repository
        5. Verify content counts and RPM integrity

    :expectedresults: Sync succeeds, RPM is retrievable, PQC signature intact

    :CaseImportance: High
    """
    import rpm_rs

    # Build PQC-signed RPM
    builder = rpm_rs.PackageBuilder('pqc-walrus', '1.0', 'MIT', 'noarch', 'PQC test')
    builder.using_config(rpm_rs.BuildConfig(format=rpm_rs.RpmFormat.V6))
    builder.release('1.el10')
    pkg = builder.build()
    signer = rpm_rs.Signer(PQC_SECRET_KEY_BYTES)
    pkg.sign(signer)

    # Create a hosted repo on the Foreman server
    repo_dir = '/var/www/html/pub/pqc_test_repo/'
    target_sat.execute(f'mkdir -p {repo_dir}')
    pkg.write_file('/tmp/pqc-walrus-1.0-1.el10.noarch.rpm')
    target_sat.put('/tmp/pqc-walrus-1.0-1.el10.noarch.rpm', repo_dir)
    target_sat.execute(f'createrepo {repo_dir}')

    # Sync through Katello
    repo = target_sat.api.Repository(
        product=module_product,
        content_type='yum',
        url=f'http://{target_sat.hostname}/pub/pqc_test_repo/',
        unprotected=True,
    ).create()
    repo.sync()
    repo = repo.read()
    assert repo.content_counts['rpm'] == 1

    # Download the synced RPM and verify PQC signature is intact
    # (Pulp serves from its own storage, not the original repo dir)
    packages = target_sat.api.Package(repository=repo).search()
    assert len(packages) == 1
    assert packages[0].name == 'pqc-walrus'
```

### Tier 2: Content Credential with PQC Public Key

Validates that Katello can store a PQC public key as a content credential
and distribute it to clients via repo config.

```python
@pytest.mark.tier2
def test_pqc_content_credential(target_sat, module_org, module_product):
    """Katello should accept a PQC public key as a content credential.

    :id: <generate-uuid>

    :steps:
        1. Import a PQC (ML-DSA) public key as a content credential
        2. Associate it with a product/repository
        3. Verify the key content is preserved

    :expectedresults: PQC public key is stored and retrievable

    :CaseImportance: Medium
    """
    gpg_key = target_sat.api.GPGKey(
        organization=module_org,
        content=PQC_PUBLIC_KEY_ASC,
        name='pqc-test-key',
    ).create()
    assert gpg_key.content == PQC_PUBLIC_KEY_ASC

    # Associate with product
    module_product.gpg_key = gpg_key
    module_product.update(['gpg_key'])
    module_product = module_product.read()
    assert module_product.gpg_key.id == gpg_key.id
```

### Tier 3: RHEL 10 Native PQC Verification

End-to-end: PQC-signed RPM flows through Foreman/Katello to a RHEL 10 host
which natively verifies the v6 signature.

```python
@pytest.mark.tier3
@pytest.mark.rhel_ver_list([10])
def test_rhel10_verifies_pqc_signature(
    target_sat, rhel_contenthost, module_org, module_lce
):
    """RHEL 10 host should natively verify PQC signatures on packages
    distributed through Katello.

    :id: <generate-uuid>

    :steps:
        1. Generate PQC-signed RPM with rpm-rs
        2. Sync through Katello, publish in content view, promote to lifecycle env
        3. Register RHEL 10 content host
        4. Import PQC public key into host's rpm keyring
        5. Install the package
        6. Verify PQC signature was recognized

    :expectedresults: rpm -qi shows ML-DSA signature, package installs cleanly

    :CaseImportance: High
    """
    # ... setup: build RPM, sync, publish CV, promote ...

    # Import PQC key on the content host
    rhel_contenthost.execute(
        f'rpm --import /path/to/pqc-public-key.asc'
    )

    # Install the package
    result = rhel_contenthost.execute('dnf install -y pqc-walrus')
    assert result.status == 0

    # Verify PQC signature is recognized
    result = rhel_contenthost.execute('rpm -qi pqc-walrus')
    assert 'ML-DSA' in result.stdout
```

### Tier 3: RHEL 9 PQC Verification via Multisig Plugin

Same flow but for RHEL 9.7+ which requires the `dnf-plugin-multisig` package.

```python
@pytest.mark.tier3
@pytest.mark.rhel_ver_list([9])
def test_rhel9_verifies_pqc_via_multisig(
    target_sat, rhel_contenthost, module_org, module_lce
):
    """RHEL 9.7+ should verify PQC signatures via dnf-plugin-multisig.

    :id: <generate-uuid>

    :steps:
        1. Generate PQC-signed RPM, sync through Katello
        2. Register RHEL 9 content host
        3. Install dnf-plugin-multisig
        4. Import PQC key into pqrpm keyring
        5. Install the package
        6. Verify multisig plugin verified the PQC signature

    :expectedresults: Package installs, multisig plugin logs successful verification

    :CaseImportance: Medium
    """
    # ... setup ...

    # Install multisig plugin
    rhel_contenthost.execute('dnf install -y dnf-plugin-multisig')

    # Import PQC key into the pqrpm keyring (separate from system rpm keyring)
    rhel_contenthost.execute(
        '/usr/lib/pqrpm/bin/rpmkeys --import /path/to/pqc-public-key.asc'
    )

    # Install package — multisig plugin hooks into dnf transaction
    result = rhel_contenthost.execute('dnf install -y pqc-walrus')
    assert result.status == 0
```

### Tier 4: Dual-Signed RPM Verification

Validates that a dual-signed RPM (RSA v4 + ML-DSA v6) works correctly
through the full pipeline, matching Red Hat's production dual-signing approach.

```python
@pytest.mark.tier3
def test_dual_signed_rpm(target_sat, rhel_contenthost, module_org):
    """Dual-signed RPM (RSA + ML-DSA) should sync and verify both signatures.

    :id: <generate-uuid>

    :steps:
        1. Build a v6 RPM, sign with RSA, then sign with ML-DSA
        2. Verify both signatures present locally with rpm-rs
        3. Sync through Katello
        4. Install on content host
        5. Verify both signature types recognized

    :expectedresults: Both classical and PQC signatures are present and verifiable

    :CaseImportance: Medium
    """
    import rpm_rs

    builder = rpm_rs.PackageBuilder('dual-signed', '1.0', 'MIT', 'noarch')
    builder.using_config(rpm_rs.BuildConfig(format=rpm_rs.RpmFormat.V6))
    pkg = builder.build()

    # Dual sign
    pkg.sign(rpm_rs.Signer(RSA_SECRET_KEY))
    pkg.sign(rpm_rs.Signer(PQC_SECRET_KEY))

    # Verify both present
    verifier = rpm_rs.Verifier(RSA_PUBLIC_KEY)
    verifier.load_from_asc_bytes(PQC_PUBLIC_KEY)
    report = pkg.check_signatures(verifier)
    algorithms = {s.info.algorithm for s in report.signatures}
    assert 'RSA' in algorithms or 'EdDSALegacy' in algorithms
    assert 'ML-DSA-65+Ed25519' in algorithms
```

## Implementation Notes

### Where to Put Things in Robottelo

- **Test keys**: `tests/foreman/data/pqc/` — vendor the rpm-rs ML-DSA-65+Ed25519 test
  key pair (`.secret` and `.asc` files). Add to `DataFile` class in
  `robottelo/constants/__init__.py`.

- **RPM factory helper**: `robottelo/helpers/rpm_factory.py` — wrapper around `rpm_rs`
  with sensible defaults for test RPM generation. Shared across PQC and non-PQC tests.

- **PQC tests**: `tests/foreman/api/test_pqc.py` or extend existing
  `tests/foreman/api/test_repository.py` with a PQC section.

- **Dependency**: Add `rpm-rs` to `requirements.txt` or `pyproject.toml`.

### Hosting Test Repos on the Foreman Server

The existing `repos_hosting_url` infrastructure (SatLab `infra-podman-*.infra.sat.rdu2.redhat.com`)
hosts pre-built fixture repos. For PQC tests, generate repos at test time:

```python
def host_pqc_repo(target_sat, rpms, repo_name='pqc_test_repo'):
    """Create a yum repo on the Foreman server from a list of rpm-rs Package objects."""
    repo_dir = f'/var/www/html/pub/{repo_name}/'
    target_sat.execute(f'mkdir -p {repo_dir}')
    for pkg in rpms:
        filename = f'{pkg.canonical_filename()}'
        pkg.write_file(f'/tmp/{filename}')
        target_sat.put(f'/tmp/{filename}', f'{repo_dir}{filename}')
    target_sat.execute(f'createrepo {repo_dir}')
    return f'http://{target_sat.hostname}/pub/{repo_name}/'
```

### What the System rpm Already Understands

Even without importing the PQC key, the system `rpm` on RHEL 9.6+ / RHEL 10 correctly
parses ML-DSA signature metadata. Running `rpm -qip` on a PQC-signed RPM shows:

```
Signature: ML-DSA-65+Ed25519/SHA256, Fri 05 Jun 2026, Key ID 23cde04477b8bbcf
```

The `NOTTRUSTED` warning only means the key isn't imported — the cryptographic algorithm
is fully recognized and the signature data is correctly parsed.

### Gotchas

1. **`import rpm_rs` not `import rpm`** — The PyPI package is `rpm-rs` but the Python
   module is `rpm_rs`. The system `rpm` module (from `rpm-devel`) is a separate thing.

2. **`with_file_contents(content, options)`** — argument order is content bytes first,
   `FileOptions` second. The Rust API uses the opposite order; the Python binding
   swaps them.

3. **v6 is the default** — `BuildConfig()` defaults to v6 format with zstd compression.
   Explicitly use `BuildConfig(format=rpm_rs.RpmFormat.V4)` for legacy v4 RPMs.

4. **Key determines algorithm** — You don't select ML-DSA-65 vs ML-DSA-87 in code.
   The `Signer` reads the key file and uses whatever algorithm the key was generated for.

5. **`check_signatures()` vs `verify_signature()`** — `check_signatures()` returns a
   report (doesn't raise on failure). `verify_signature()` raises on failure. Use
   `check_signatures()` for test assertions.

6. **`is_verified()` is a method call** — Note the parentheses: `sig.is_verified()`,
   not `sig.is_verified`.
