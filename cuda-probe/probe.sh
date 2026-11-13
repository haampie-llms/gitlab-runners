#!/bin/bash
# Throwaway probe: does relaxing py-libclang's llvm pin let the ml-linux stacks
# use the image's clang@23, and do LLVM 18's clang.cindex bindings work with
# libclang from LLVM 23?
set -uo pipefail
cd /work
for r in "spack $SPACK_REPOSITORY $SPACK_COMMIT" "packages $PACKAGES_REPOSITORY $PACKAGES_COMMIT"; do
  set -- $r
  git init -q $1; git -C $1 fetch -q --depth 1 "https://github.com/$2.git" $3; git -C $1 checkout -q FETCH_HEAD
done

echo "### LLVM 18 clang.cindex against the image's libclang"
llvm=$(dirname "$(dirname "$(readlink -f "$(command -v clang)")")")
ls -l "$llvm"/lib/libclang.so*
mkdir -p bindings/clang
for f in __init__.py cindex.py; do
  curl -fsSL "https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-18.1.8/clang/bindings/python/clang/$f" -o bindings/clang/$f
done
cat > t.cpp <<'CPP'
#include <algorithm>
#include <concepts>
#include <coroutine>
#include <format>
#include <map>
#include <memory>
#include <ranges>
#include <string>
#include <vector>
template <std::integral T> struct S { T x; auto operator<=>(const S&) const = default; };
int main() {
  std::vector<int> v{3, 1, 2};
  auto r = v | std::views::filter([](int i) { return i > 1; });
  std::ranges::sort(v);
  return std::format("{}", S<int>{1}.x).size() + std::ranges::distance(r);
}
CPP
PYTHONPATH=bindings python3 - "$llvm/lib/libclang.so" "$(cat "$llvm/bin/clang++.cfg" | grep -o -- '--gcc-install-dir=[^ ]*')" <<'PY'
import collections, sys
import clang.cindex as ci
ci.Config.set_library_file(sys.argv[1])
idx = ci.Index.create()  # loads libclang and registers all functions (compatibility_check)
tu = idx.parse("t.cpp", args=["-x", "c++", "-std=c++23", sys.argv[2]])
print("diagnostics:", [str(d) for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error][:5])
kinds, errors, n = collections.Counter(), collections.Counter(), 0
for c in tu.cursor.walk_preorder():
    n += 1
    for what, get in (("cursor", lambda: c.kind), ("type", lambda: c.type.kind)):
        try:
            kinds[(what, get().name)] += 1
        except ValueError as e:
            errors[(what, str(e))] += 1
print(f"walked {n} cursors, {len(kinds)} distinct kinds")
print("unknown kinds (ValueError):", dict(errors) or "none")
PY

echo; echo "### Concretize $ML_STACK with the relaxed py-libclang"
export SPACK_DISABLE_LOCAL_CONFIG=1 SPACK_USER_CACHE_PATH=/work/cache SPACK_CI_TARGET SPACK_COLOR=never
set -a; . packages/.ci/env; set +a
. spack/share/spack/setup-env.sh
stack=/work/packages/stacks/$ML_STACK
start=$(date +%s)
spack -e "$stack" concretize -j 4 > concretize.log 2>&1; rc=$?
echo "rc=$rc in $(( $(date +%s) - start ))s"; [ $rc = 0 ] || tail -n 40 concretize.log
spack -e "$stack" find -c --format '{name}@{version} %{compiler.name}@{compiler.version} {hash:7}' llvm py-libclang py-tensorflow py-jaxlib | sort -u
exit $rc
