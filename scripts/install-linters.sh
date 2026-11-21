#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DEST="${ROOT}/.tools/bin"
TEMP=$(mktemp -d)
trap 'rm -rf -- "${TEMP}"' EXIT
SYSTEM=$(uname -s)
ARCH=$(uname -m)
case "${SYSTEM}-${ARCH}" in
  Darwin-arm64)
    SHELL_ARCH=darwin.aarch64
    ACTION_ARCH=darwin_arm64
    SHELL_HASH=339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f
    ACTION_HASH=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    ;;
  Darwin-x86_64)
    SHELL_ARCH=darwin.x86_64
    ACTION_ARCH=darwin_amd64
    SHELL_HASH=c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51
    ACTION_HASH=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
    ;;
  Linux-x86_64)
    SHELL_ARCH=linux.x86_64
    ACTION_ARCH=linux_amd64
    SHELL_HASH=b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6
    ACTION_HASH=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    ;;
  *) printf '%s\n' 'Unsupported linter tool platform' >&2; exit 1 ;;
esac
curl --fail --location --retry 2 -o "${TEMP}/shellcheck.tar.gz" "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.${SHELL_ARCH}.tar.gz"
curl --fail --location --retry 2 -o "${TEMP}/actionlint.tar.gz" "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_${ACTION_ARCH}.tar.gz"
if command -v sha256sum >/dev/null; then
  printf '%s  %s\n' "${SHELL_HASH}" "${TEMP}/shellcheck.tar.gz" "${ACTION_HASH}" "${TEMP}/actionlint.tar.gz" | sha256sum -c -
else
  printf '%s  %s\n' "${SHELL_HASH}" "${TEMP}/shellcheck.tar.gz" "${ACTION_HASH}" "${TEMP}/actionlint.tar.gz" | shasum -a 256 -c -
fi
tar -xzf "${TEMP}/shellcheck.tar.gz" -C "${TEMP}"
tar -xzf "${TEMP}/actionlint.tar.gz" -C "${TEMP}"
mkdir -p -- "${DEST}"
cp -- "${TEMP}/shellcheck-v0.11.0/shellcheck" "${DEST}/shellcheck"
cp -- "${TEMP}/actionlint" "${DEST}/actionlint"
"${DEST}/shellcheck" --version
"${DEST}/actionlint" --version
