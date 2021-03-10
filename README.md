# MS Visual Studio support for Coil Toolchain

Nix-based support for building with MSVS on Linux.

This repo allows to build QEMU VM image with installed MSVS as a sandbox-compatible Nix derivation, in fully automatic fashion.

## Implementation

The script runs in two stages.

First, MSVS packages are fetched using Nix-based reimplementation of VS installer fetching logic (inspired by [vsdownload.py](https://github.com/mstorsjo/msvc-wine/blob/master/vsdownload.py) from [mstorsjo/msvc-wine](https://github.com/mstorsjo/msvc-wine)). Downloaded packages are combined into "VS layout" package cache directory, as expected by VS installer.

Second, actual installation is performed, by running VS installer in VM in offline mode.

By downloading packages purely in Nix we avoid the need for online connection when running the installer, which would require the dreaded fixed-hash derivation hack (which is not possible anyway, as the resulting image is almost surely non-deterministic). Nix also allows for more granular caching (in case you try different workloads with overlapping package sets).

The fetching logic is (surprisingly) not very complicated. VS manifest file provides URLs and SHA256 hashes, so the script mostly just feeds those to `fetchurl` calls. The set of hardcoded hashes is small enough to be maintainable (see [fixeds.json](fixeds.json)).

## License

This repo is made available under MIT license, but note that it's only about the script itself. The proprietary stuff it downloads is subject to Microsoft's EULA.
