#!/bin/bash
# Throwaway probe: is CUDA usable in the linux-gnu image (glibc 2.28)?
# Inputs: PACKAGES_REPOSITORY, PACKAGES_COMMIT, SPACK_REPOSITORY, SPACK_COMMIT,
# SPACK_CI_TARGET, ML_STACK.
set -euo pipefail
section() { echo; echo "### $*"; }

workdir=/work
cd "$workdir"
for r in "spack $SPACK_REPOSITORY $SPACK_COMMIT" "packages $PACKAGES_REPOSITORY $PACKAGES_COMMIT"; do
  set -- $r
  git init -q $1
  git -C $1 fetch -q --depth 1 "https://github.com/$2.git" $3
  git -C $1 checkout -q FETCH_HEAD
done

export SPACK_DISABLE_LOCAL_CONFIG=1 SPACK_USER_CACHE_PATH=$workdir/cache SPACK_CI_TARGET
. spack/share/spack/setup-env.sh
spack config --scope site add "repos:builtin:$workdir/packages/repos/spack_repo/builtin"
spack config --scope site add "config:install_tree:root:$workdir/opt"
spack config --scope site add "config:build_stage:[$workdir/stage]"
spack compiler find --scope site
spack compiler list

section "Install cuda and kokkos +cuda with gcc@14"
spack env create -d cudaenv
spack -e cudaenv add cuda@13.4.2 "kokkos +cuda +wrapper cuda_arch=80 %gcc@14"
spack -e cudaenv config add "packages:all:require:[target=$SPACK_CI_TARGET]"
spack -e cudaenv concretize --fresh
spack -e cudaenv find -c --show-full-compiler cuda kokkos
spack -e cudaenv install --fail-fast -j "$(nproc)"
cuda=$(spack -e cudaenv location -i cuda)

section "nvcc + gcc@14: compile and link against cuBLAS, cuSOLVER, cuFFT, cuRAND"
cat > t.cu <<'EOF'
#include <cmath>
#include <cstdio>
#include <cublas_v2.h>
#include <cusolverDn.h>
#include <cufft.h>
#include <curand.h>
__global__ void k(float *x) { x[threadIdx.x] = sinpif(x[threadIdx.x]) + std::log2(2.0f); }
int main() {
  cublasHandle_t b; cusolverDnHandle_t s; cufftHandle f; curandGenerator_t g;
  float *x = nullptr;
  k<<<1, 32>>>(x);
  printf("%d %d %d %d\n", (int)cublasCreate(&b), (int)cusolverDnCreate(&s),
         (int)cufftPlan1d(&f, 8, CUFFT_C2C, 1), (int)curandCreateGenerator(&g, CURAND_RNG_PSEUDO_DEFAULT));
}
EOF
"$cuda/bin/nvcc" --version | tail -n2
"$cuda/bin/nvcc" -ccbin "$(command -v g++)" -arch=sm_80 -std=c++17 t.cu -o t \
  -lcublas -lcublasLt -lcusolver -lcufft -lcurand
echo "compiled and linked OK"

section "Newest GLIBC symbol version needed"
glibc_scan() {
  find "$@" -type f \( -name '*.so*' -o -perm -u+x \) 2>/dev/null | while read -r f; do
    file -b "$f" | grep -q ELF || continue
    v=$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -uV | tail -n1)
    [ -n "$v" ] && echo "$v $f"
  done | sort -V -k1,1
}
glibc_scan "$cuda" > cuda-glibc.txt
echo "cuda files by newest GLIBC needed:"; awk '{print $1}' cuda-glibc.txt | sort -V | uniq -c
echo "files needing > 2.28:"
awk '{print $1}' cuda-glibc.txt | sort -uV | while read -r v; do
  [ "$(printf '%s\nGLIBC_2.28\n' "$v" | sort -V | tail -n1)" = GLIBC_2.28 ] || grep "^$v " cuda-glibc.txt
done | sed "s|$cuda/||" | head -n 50
echo "test binary:"; glibc_scan ./t
echo "kokkos:"; glibc_scan "$(spack -e cudaenv location -i kokkos)" | tail -n3

section "Concretize $ML_STACK in this image"
set -a; . packages/.ci/env; set +a
start=$(date +%s)
spack -e "packages/stacks/$ML_STACK" concretize -j 4 > ml-concretize.log 2>&1 || { tail -n 80 ml-concretize.log; exit 1; }
echo "concretized in $(( $(date +%s) - start ))s"
spack --color=never -e "packages/stacks/$ML_STACK" find -c --show-full-compiler cuda py-torch | grep -v '^==>' | sort -u
