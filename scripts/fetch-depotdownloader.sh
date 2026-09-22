#!/bin/sh
#
# fetch-depotdownloader.sh <amd64|arm64> <directory>
#
# Build-time helper for the Dockerfile: downloads the official DepotDownloader release for the given
# architecture from GitHub, verifies it against the sha256 pinned in the Dockerfile, and unpacks it
# (the binary and its LICENSE) into the directory. DD_VERSION, DD_RELEASE_URL, DD_SHA256_AMD64 and
# DD_SHA256_ARM64 arrive as Dockerfile ARGs. Nothing is built, patched or vendored: the zip is used
# exactly as SteamRE published it, and a checksum mismatch fails the build.
set -eu

arch="${1:?architecture (amd64 or arm64) required}"
dest="${2:?destination directory required}"
: "${DD_VERSION:?}" "${DD_RELEASE_URL:?}" "${DD_SHA256_AMD64:?}" "${DD_SHA256_ARM64:?}"

case "${arch}" in
    amd64) asset="DepotDownloader-linux-x64.zip";   sha256="${DD_SHA256_AMD64}" ;;
    arm64) asset="DepotDownloader-linux-arm64.zip"; sha256="${DD_SHA256_ARM64}" ;;
    *) echo "fetch-depotdownloader: unsupported architecture '${arch}' (amd64 or arm64)" >&2; exit 1 ;;
esac

url="${DD_RELEASE_URL}/${asset}"
zip="$(mktemp)"
echo "DepotDownloader ${DD_VERSION} for ${arch}: ${url}"
curl -fsSL --retry 3 --retry-delay 5 -o "${zip}" "${url}"
echo "${sha256}  ${zip}" | sha256sum -c -
mkdir -p "${dest}"
unzip -q -o "${zip}" -d "${dest}"
rm -f "${zip}"
chmod 755 "${dest}/DepotDownloader"
test -f "${dest}/LICENSE"
# What exactly was installed, for NOTICE and for anyone inspecting the image.
printf 'DepotDownloader %s (%s)\nsource: %s\nsha256: %s\n' "${DD_VERSION}" "${asset}" "${url}" "${sha256}" > "${dest}/RELEASE.txt"
