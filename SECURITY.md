# Security

## Reporting a vulnerability

Report security concerns privately through [GitHub security advisories](https://github.com/j-khn/mutest-swift/security/advisories/new), where private reporting is available. If it is unavailable, open an issue requesting a private contact without including sensitive details.

## Running project code

Mutation runs copy project files to an isolated workspace, but the copy is not an operating-system security sandbox. Builds, plugins, scripts, and tests execute with the runner's permissions and may access the network and other files. Run untrusted projects on a disposable restricted runner without credentials or unrelated data.

## Verify a release

Import the release signing public key from a trusted source, then verify the tag in a clone:

```sh
git fetch origin --tags
git tag -v <tag>
```

Download the release archive and its checksum into the same directory, then verify them and the archive attestation:

```sh
shasum -a 256 -c <archive>.sha256
gh attestation verify <archive> --repo j-khn/mutest-swift
```

Check that the signing key and attestation workflow identity are trusted by your organization. Older releases may not have signed tags, checksums, or attestations.
