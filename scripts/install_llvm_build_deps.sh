#!/usr/bin/env bash
set -euo pipefail

LLVM_MAJOR_VERSION=22
LLVM_SYS_PREFIX_ENV="LLVM_SYS_221_PREFIX"

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return
    fi

    sudo "$@"
}

record_llvm_prefix() {
    local prefix="$1"

    export "${LLVM_SYS_PREFIX_ENV}=${prefix}"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf '%s=%s\n' "${LLVM_SYS_PREFIX_ENV}" "${prefix}" >> "${GITHUB_ENV}"
    fi
}

install_macos() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required to install llvm@${LLVM_MAJOR_VERSION} on macOS" >&2
        exit 1
    fi

    if ! brew --prefix "llvm@${LLVM_MAJOR_VERSION}" >/dev/null 2>&1; then
        brew install "llvm@${LLVM_MAJOR_VERSION}"
    fi

    record_llvm_prefix "$(brew --prefix "llvm@${LLVM_MAJOR_VERSION}")"
}

install_dnf() {
    local prefix="/opt/llvm-${LLVM_MAJOR_VERSION}"
    if [ -x "${prefix}/bin/llvm-config" ]; then
        record_llvm_prefix "${prefix}"
        return
    fi

    run_as_root dnf install -y cmake ninja-build libffi-devel zlib-devel libxml2-devel libzstd-devel
    local version="22.1.8"
    local archive="llvm-project-${version}.src.tar.xz"
    local build_root
    build_root="$(mktemp -d)"
    curl --proto '=https' --tlsv1.2 -fsSL \
        "https://github.com/llvm/llvm-project/releases/download/llvmorg-${version}/${archive}" \
        -o "${build_root}/${archive}"
    echo "922f1817a0df7b1489272d18134ee0087a8b068828f87ac63b9861b1a9965888  ${build_root}/${archive}" \
        | sha256sum --check --status
    tar -xJf "${build_root}/${archive}" -C "${build_root}"
    # Build against the manylinux image's libc to preserve the wheel's ABI floor.
    cmake -S "${build_root}/llvm-project-${version}.src/llvm" -B "${build_root}/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${prefix}" \
        -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV;LoongArch" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF
    cmake --build "${build_root}/build" --parallel 2
    run_as_root cmake --install "${build_root}/build"
    rm -rf "${build_root}"
    record_llvm_prefix "${prefix}"
}

install_apt() {
    run_as_root apt-get update

    if ! apt-cache show "llvm-${LLVM_MAJOR_VERSION}-dev" >/dev/null 2>&1; then
        local llvm_script
        llvm_script="$(mktemp)"
        curl --proto '=https' --tlsv1.2 -fsSL https://apt.llvm.org/llvm.sh -o "${llvm_script}"
        run_as_root bash "${llvm_script}" "${LLVM_MAJOR_VERSION}"
        rm -f "${llvm_script}"
    fi

    run_as_root apt-get install -y \
        "llvm-${LLVM_MAJOR_VERSION}-dev" \
        libffi-dev \
        libxml2-dev \
        libzstd-dev \
        zlib1g-dev
    record_llvm_prefix "/usr/lib/llvm-${LLVM_MAJOR_VERSION}"
}

case "$(uname -s)" in
    Darwin)
        install_macos
        ;;
    Linux)
        if command -v dnf >/dev/null 2>&1; then
            install_dnf
        elif command -v apt-get >/dev/null 2>&1; then
            install_apt
        else
            echo "Unable to install LLVM build dependencies on this Linux distribution" >&2
            exit 1
        fi
        ;;
    *)
        echo "Unsupported platform: $(uname -s)" >&2
        exit 1
        ;;
esac
