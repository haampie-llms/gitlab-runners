#!/bin/bash
# Throwaway probe: why does ml-linux-aarch64 not concretize py-tensorflow in the
# linux-gnu image (llvm@23 is the only clang)?
set -uo pipefail
cd /work
for r in "spack $SPACK_REPOSITORY $SPACK_COMMIT" "packages $PACKAGES_REPOSITORY $PACKAGES_COMMIT"; do
  set -- $r
  git init -q $1; git -C $1 fetch -q --depth 1 "https://github.com/$2.git" $3; git -C $1 checkout -q FETCH_HEAD
done
export SPACK_DISABLE_LOCAL_CONFIG=1 SPACK_USER_CACHE_PATH=/work/cache SPACK_CI_TARGET SPACK_COLOR=never
set -a; . packages/.ci/env; set +a
. spack/share/spack/setup-env.sh
stack=/work/packages/stacks/$ML_STACK
spack env activate --without-view "$stack"
spack compiler find
spack compiler list
try() { echo; echo "### spack spec $*"; spack spec -l "$@" 2>&1 | grep -vE '^\s+\^' | tail -n 40; }
try py-libclang
try py-tensorflow
try py-tensorflow ^py-libclang@18 ^llvm@18
try "py-tensorflow %c,cxx=llvm@23"
try llvm@18 +clang
echo; echo "### py-tensorflow, with an llvm@18 external added (mimics apt clang-18)"
spack config add "packages:llvm:externals:[{spec: 'llvm@18.1.8+clang~lld~lldb', prefix: /usr, extra_attributes: {compilers: {c: /usr/bin/clang-18, cxx: /usr/bin/clang++-18}}}]"
try py-tensorflow
