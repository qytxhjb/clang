#!/usr/bin/env bash
# Copyright (c) 2012 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script will check out llvm and clang into third_party/llvm and build it.

# Do NOT CHANGE this if you don't know what you're doing -- see
# https://code.google.com/p/chromium/wiki/UpdatingClang
# Reverting problematic clang rolls is safe, though.
CLANG_REVISION=217949

THIS_DIR="$(dirname "${0}")"
LLVM_DIR="${THIS_DIR}/../../../third_party/llvm"
LLVM_BUILD_DIR="${LLVM_DIR}/../llvm-build/Release+Asserts"
COMPILER_RT_BUILD_DIR="${LLVM_DIR}/../llvm-build/compiler-rt"
LLVM_BOOTSTRAP_DIR="${LLVM_DIR}/../llvm-bootstrap"
LLVM_BOOTSTRAP_INSTALL_DIR="${LLVM_DIR}/../llvm-bootstrap-install"
CLANG_DIR="${LLVM_DIR}/tools/clang"
COMPILER_RT_DIR="${LLVM_DIR}/compiler-rt"
LIBCXX_DIR="${LLVM_DIR}/projects/libcxx"
LIBCXXABI_DIR="${LLVM_DIR}/projects/libcxxabi"
ANDROID_NDK_DIR="${THIS_DIR}/../../../third_party/android_tools/ndk"
STAMP_FILE="${LLVM_DIR}/../llvm-build/cr_build_revision"

ABS_LIBCXX_DIR="${PWD}/${LIBCXX_DIR}"
ABS_LIBCXXABI_DIR="${PWD}/${LIBCXXABI_DIR}"
ABS_LLVM_DIR="${PWD}/${LLVM_DIR}"
ABS_LLVM_BUILD_DIR="${PWD}/${LLVM_BUILD_DIR}"
ABS_COMPILER_RT_DIR="${PWD}/${COMPILER_RT_DIR}"


# Use both the clang revision and the plugin revisions to test for updates.
BLINKGCPLUGIN_REVISION=\
$(grep 'set(LIBRARYNAME' "$THIS_DIR"/../blink_gc_plugin/CMakeLists.txt \
    | cut -d ' ' -f 2 | tr -cd '[0-9]')
CLANG_AND_PLUGINS_REVISION="${CLANG_REVISION}-${BLINKGCPLUGIN_REVISION}"

# ${A:-a} returns $A if it's set, a else.
LLVM_REPO_URL=${LLVM_URL:-https://llvm.org/svn/llvm-project}

if [[ -z "$GYP_DEFINES" ]]; then
  GYP_DEFINES=
fi
if [[ -z "$GYP_GENERATORS" ]]; then
  GYP_GENERATORS=
fi


# Die if any command dies, error on undefined variable expansions.
set -eu

OS="$(uname -s)"

# Parse command line options.
if_needed=
force_local_build=
run_tests=
bootstrap=
with_android=yes
chrome_tools="plugins;blink_gc_plugin"
gcc_toolchain=

if [[ "${OS}" = "Darwin" ]]; then
  with_android=
fi

while [[ $# > 0 ]]; do
  case $1 in
    --bootstrap)
      bootstrap=yes
      ;;
    --if-needed)
      if_needed=yes
      ;;
    --force-local-build)
      force_local_build=yes
      ;;
    --print-revision)
      echo $CLANG_REVISION
      exit 0
      ;;
    --run-tests)
      run_tests=yes
      ;;
    --without-android)
      with_android=
      ;;
    --with-chrome-tools)
      shift
      if [[ $# == 0 ]]; then
        echo "--with-chrome-tools requires an argument."
        exit 1
      fi
      chrome_tools=$1
      ;;
    --gcc-toolchain)
      shift
      if [[ $# == 0 ]]; then
        echo "--gcc-toolchain requires an argument."
        exit 1
      fi
      if [[ -x "$1/bin/gcc" ]]; then
        gcc_toolchain=$1
      else
        echo "Invalid --gcc-toolchain: '$1'."
        echo "'$1/bin/gcc' does not appear to be valid."
        exit 1
      fi
      ;;

    --help)
      echo "usage: $0 [--force-local-build] [--if-needed] [--run-tests] "
      echo "--bootstrap: First build clang with CC, then with itself."
      echo "--force-local-build: Don't try to download prebuilt binaries."
      echo "--if-needed: Download clang only if the script thinks it is needed."
      echo "--run-tests: Run tests after building. Only for local builds."
      echo "--print-revision: Print current clang revision and exit."
      echo "--without-android: Don't build ASan Android runtime library."
      echo "--with-chrome-tools: Select which chrome tools to build." \
           "Defaults to plugins;blink_gc_plugin."
      echo "    Example: --with-chrome-tools plugins;empty-string"
      echo "--gcc-toolchain: Set the prefix for which GCC version should"
      echo "    be used for building. For example, to use gcc in"
      echo "    /opt/foo/bin/gcc, use '--gcc-toolchain '/opt/foo"
      echo
      exit 1
      ;;
    *)
      echo "Unknown argument: '$1'."
      echo "Use --help for help."
      exit 1
      ;;
  esac
  shift
done

if [[ -n "$if_needed" ]]; then
  if [[ "${OS}" == "Darwin" ]]; then
    # clang is used on Mac.
    true
  elif [[ "$GYP_DEFINES" =~ .*(clang|tsan|asan|lsan|msan)=1.* ]]; then
    # clang requested via $GYP_DEFINES.
    true
  elif [[ -d "${LLVM_BUILD_DIR}" ]]; then
    # clang previously downloaded, remove third_party/llvm-build to prevent
    # updating.
    true
  elif [[ "${OS}" == "Linux" ]]; then
    # Temporarily use clang on linux. Leave a stamp file behind, so that
    # this script can remove clang again on machines where it was autoinstalled.
    mkdir -p "${LLVM_BUILD_DIR}"
    touch "${LLVM_BUILD_DIR}/autoinstall_stamp"
    true
  else
    # clang wasn't needed, not doing anything.
    exit 0
  fi
fi


# Check if there's anything to be done, exit early if not.
if [[ -f "${STAMP_FILE}" ]]; then
  PREVIOUSLY_BUILT_REVISON=$(cat "${STAMP_FILE}")
  if [[ -z "$force_local_build" ]] && \
       [[ "${PREVIOUSLY_BUILT_REVISON}" = \
          "${CLANG_AND_PLUGINS_REVISION}" ]]; then
    echo "Clang already at ${CLANG_AND_PLUGINS_REVISION}"
    exit 0
  fi
fi
# To always force a new build if someone interrupts their build half way.
rm -f "${STAMP_FILE}"


if [[ -z "$force_local_build" ]]; then
  # Check if there's a prebuilt binary and if so just fetch that. That's faster,
  # and goma relies on having matching binary hashes on client and server too.
  CDS_URL=https://commondatastorage.googleapis.com/chromium-browser-clang
  CDS_FILE="clang-${CLANG_REVISION}.tgz"
  CDS_OUT_DIR=$(mktemp -d -t clang_download.XXXXXX)
  CDS_OUTPUT="${CDS_OUT_DIR}/${CDS_FILE}"
  if [ "${OS}" = "Linux" ]; then
    CDS_FULL_URL="${CDS_URL}/Linux_x64/${CDS_FILE}"
  elif [ "${OS}" = "Darwin" ]; then
    CDS_FULL_URL="${CDS_URL}/Mac/${CDS_FILE}"
  fi
  echo Trying to download prebuilt clang
  if which curl > /dev/null; then
    curl -L --fail "${CDS_FULL_URL}" -o "${CDS_OUTPUT}" || \
        rm -rf "${CDS_OUT_DIR}"
  elif which wget > /dev/null; then
    wget "${CDS_FULL_URL}" -O "${CDS_OUTPUT}" || rm -rf "${CDS_OUT_DIR}"
  else
    echo "Neither curl nor wget found. Please install one of these."
    exit 1
  fi
  if [ -f "${CDS_OUTPUT}" ]; then
    rm -rf "${LLVM_BUILD_DIR}"
    mkdir -p "${LLVM_BUILD_DIR}"
    tar -xzf "${CDS_OUTPUT}" -C "${LLVM_BUILD_DIR}"
    echo clang "${CLANG_REVISION}" unpacked
    echo "${CLANG_AND_PLUGINS_REVISION}" > "${STAMP_FILE}"
    rm -rf "${CDS_OUT_DIR}"
    exit 0
  else
    echo Did not find prebuilt clang at r"${CLANG_REVISION}", building
  fi
fi

if [[ -n "${with_android}" ]] && ! [[ -d "${ANDROID_NDK_DIR}" ]]; then
  echo "Android NDK not found at ${ANDROID_NDK_DIR}"
  echo "The Android NDK is needed to build a Clang whose -fsanitize=address"
  echo "works on Android. See "
  echo "http://code.google.com/p/chromium/wiki/AndroidBuildInstructions for how"
  echo "to install the NDK, or pass --without-android."
  exit 1
fi

# Check that cmake and ninja are available.
if ! which cmake > /dev/null; then
  echo "CMake needed to build clang; please install"
  exit 1
fi
if ! which ninja > /dev/null; then
  echo "ninja needed to build clang, please install"
  exit 1
fi

echo Reverting previously patched files
for i in \
      "${CLANG_DIR}/test/Index/crash-recovery-modules.m" \
      "${CLANG_DIR}/unittests/libclang/LibclangTest.cpp" \
      "${COMPILER_RT_DIR}/lib/asan/asan_rtl.cc" \
      "${COMPILER_RT_DIR}/test/asan/TestCases/Linux/new_array_cookie_test.cc" \
      ; do
  if [[ -e "${i}" ]]; then
    svn revert "${i}"
  fi;
done

echo Getting LLVM r"${CLANG_REVISION}" in "${LLVM_DIR}"
if ! svn co --force "${LLVM_REPO_URL}/llvm/trunk@${CLANG_REVISION}" \
                    "${LLVM_DIR}"; then
  echo Checkout failed, retrying
  rm -rf "${LLVM_DIR}"
  svn co --force "${LLVM_REPO_URL}/llvm/trunk@${CLANG_REVISION}" "${LLVM_DIR}"
fi

echo Getting clang r"${CLANG_REVISION}" in "${CLANG_DIR}"
svn co --force "${LLVM_REPO_URL}/cfe/trunk@${CLANG_REVISION}" "${CLANG_DIR}"

# We have moved from building compiler-rt in the LLVM tree, to a separate
# directory. Nuke any previous checkout to avoid building it.
rm -rf "${LLVM_DIR}/projects/compiler-rt"

echo Getting compiler-rt r"${CLANG_REVISION}" in "${COMPILER_RT_DIR}"
svn co --force "${LLVM_REPO_URL}/compiler-rt/trunk@${CLANG_REVISION}" \
               "${COMPILER_RT_DIR}"

# clang needs a libc++ checkout, else -stdlib=libc++ won't find includes
# (i.e. this is needed for bootstrap builds).
if [ "${OS}" = "Darwin" ]; then
  echo Getting libc++ r"${CLANG_REVISION}" in "${LIBCXX_DIR}"
  svn co --force "${LLVM_REPO_URL}/libcxx/trunk@${CLANG_REVISION}" \
                 "${LIBCXX_DIR}"
fi

# While we're bundling our own libc++ on OS X, we need to compile libc++abi
# into it too (since OS X 10.6 doesn't have libc++abi.dylib either).
if [ "${OS}" = "Darwin" ]; then
  echo Getting libc++abi r"${CLANG_REVISION}" in "${LIBCXXABI_DIR}"
  svn co --force "${LLVM_REPO_URL}/libcxxabi/trunk@${CLANG_REVISION}" \
                 "${LIBCXXABI_DIR}"
fi

# Apply patch for tests failing with --disable-pthreads (llvm.org/PR11974)
pushd "${CLANG_DIR}"
cat << 'EOF' |
--- third_party/llvm/tools/clang/test/Index/crash-recovery-modules.m	(revision 202554)
+++ third_party/llvm/tools/clang/test/Index/crash-recovery-modules.m	(working copy)
@@ -12,6 +12,8 @@
 
 // REQUIRES: crash-recovery
 // REQUIRES: shell
+// XFAIL: *
+//    (PR11974)
 
 @import Crash;
EOF
patch -p4
popd

pushd "${CLANG_DIR}"
cat << 'EOF' |
--- unittests/libclang/LibclangTest.cpp (revision 215949)
+++ unittests/libclang/LibclangTest.cpp (working copy)
@@ -431,7 +431,7 @@
   EXPECT_EQ(0U, clang_getNumDiagnostics(ClangTU));
 }

-TEST_F(LibclangReparseTest, ReparseWithModule) {
+TEST_F(LibclangReparseTest, DISABLED_ReparseWithModule) {
   const char *HeaderTop = "#ifndef H\n#define H\nstruct Foo { int bar;";
   const char *HeaderBottom = "\n};\n#endif\n";
   const char *MFile = "#include \"HeaderFile.h\"\nint main() {"
EOF
patch -p0
popd

# Echo all commands.
set -x

# Set default values for CC and CXX if they're not set in the environment.
CC=${CC:-cc}
CXX=${CXX:-c++}

if [[ -n "${gcc_toolchain}" ]]; then
  # Use the specified gcc installation for building.
  CC="$gcc_toolchain/bin/gcc"
  CXX="$gcc_toolchain/bin/g++"
  # Set LD_LIBRARY_PATH to make auxiliary targets (tablegen, bootstrap compiler,
  # etc.) find the .so.
  export LD_LIBRARY_PATH="$(dirname $(${CXX} -print-file-name=libstdc++.so.6))"
fi

CFLAGS=""
CXXFLAGS=""
LDFLAGS=""

# LLVM uses C++11 starting in llvm 3.5. On Linux, this means libstdc++4.7+ is
# needed, on OS X it requires libc++. clang only automatically links to libc++
# when targeting OS X 10.9+, so add stdlib=libc++ explicitly so clang can run on
# OS X versions as old as 10.7.
# TODO(thakis): Some bots are still on 10.6, so for now bundle libc++.dylib.
# Remove this once all bots are on 10.7+, then use --enable-libcpp=yes and
# change deployment_target to 10.7.
deployment_target=""

if [ "${OS}" = "Darwin" ]; then
  # When building on 10.9, /usr/include usually doesn't exist, and while
  # Xcode's clang automatically sets a sysroot, self-built clangs don't.
  CFLAGS="-isysroot $(xcrun --show-sdk-path)"
  CPPFLAGS="${CFLAGS}"
  CXXFLAGS="-stdlib=libc++ -nostdinc++ -I${ABS_LIBCXX_DIR}/include ${CFLAGS}"

  if [[ -n "${bootstrap}" ]]; then
    deployment_target=10.6
  fi
fi

# Build bootstrap clang if requested.
if [[ -n "${bootstrap}" ]]; then
  ABS_INSTALL_DIR="${PWD}/${LLVM_BOOTSTRAP_INSTALL_DIR}"
  echo "Building bootstrap compiler"
  mkdir -p "${LLVM_BOOTSTRAP_DIR}"
  pushd "${LLVM_BOOTSTRAP_DIR}"

  cmake -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DLLVM_TARGETS_TO_BUILD=host \
      -DLLVM_ENABLE_THREADS=OFF \
      -DCMAKE_INSTALL_PREFIX="${ABS_INSTALL_DIR}" \
      -DCMAKE_C_COMPILER="${CC}" \
      -DCMAKE_CXX_COMPILER="${CXX}" \
      -DCMAKE_C_FLAGS="${CFLAGS}" \
      -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
      ../llvm

  ninja
  if [[ -n "${run_tests}" ]]; then
    ninja check-all
  fi

  ninja install
  if [[ -n "${gcc_toolchain}" ]]; then
    # Copy that gcc's stdlibc++.so.6 to the build dir, so the bootstrap
    # compiler can start.
    cp -v "$(${CXX} -print-file-name=libstdc++.so.6)" \
      "${ABS_INSTALL_DIR}/lib/"
  fi

  popd
  CC="${ABS_INSTALL_DIR}/bin/clang"
  CXX="${ABS_INSTALL_DIR}/bin/clang++"

  if [[ -n "${gcc_toolchain}" ]]; then
    # Tell the bootstrap compiler to use a specific gcc prefix to search
    # for standard library headers and shared object file.
    CFLAGS="--gcc-toolchain=${gcc_toolchain}"
    CXXFLAGS="--gcc-toolchain=${gcc_toolchain}"
  fi

  echo "Building final compiler"
fi

# Build clang (in a separate directory).
# The clang bots have this path hardcoded in built/scripts/slave/compile.py,
# so if you change it you also need to change these links.
mkdir -p "${LLVM_BUILD_DIR}"
pushd "${LLVM_BUILD_DIR}"

# Build libc++.dylib while some bots are still on OS X 10.6.
if [ "${OS}" = "Darwin" ]; then
  rm -rf libcxxbuild
  LIBCXXFLAGS="-O3 -std=c++11 -fstrict-aliasing"

  # libcxx and libcxxabi both have a file stdexcept.cpp, so put their .o files
  # into different subdirectories.
  mkdir -p libcxxbuild/libcxx
  pushd libcxxbuild/libcxx
  ${CXX:-c++} -c ${CXXFLAGS} ${LIBCXXFLAGS} "${ABS_LIBCXX_DIR}"/src/*.cpp
  popd

  mkdir -p libcxxbuild/libcxxabi
  pushd libcxxbuild/libcxxabi
  ${CXX:-c++} -c ${CXXFLAGS} ${LIBCXXFLAGS} "${ABS_LIBCXXABI_DIR}"/src/*.cpp -I"${ABS_LIBCXXABI_DIR}/include"
  popd

  pushd libcxxbuild
  ${CC:-cc} libcxx/*.o libcxxabi/*.o -o libc++.1.dylib -dynamiclib \
    -nodefaultlibs -current_version 1 -compatibility_version 1 \
    -lSystem -install_name @executable_path/libc++.dylib \
    -Wl,-unexported_symbols_list,${ABS_LIBCXX_DIR}/lib/libc++unexp.exp \
    -Wl,-force_symbols_not_weak_list,${ABS_LIBCXX_DIR}/lib/notweak.exp \
    -Wl,-force_symbols_weak_list,${ABS_LIBCXX_DIR}/lib/weak.exp
  ln -sf libc++.1.dylib libc++.dylib
  popd
  LDFLAGS+="-stdlib=libc++ -L${PWD}/libcxxbuild"
fi

rm -fv CMakeCache.txt
MACOSX_DEPLOYMENT_TARGET=${deployment_target} cmake -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_ENABLE_THREADS=OFF \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
    -DCMAKE_MODULE_LINKER_FLAGS="${LDFLAGS}" \
    "${ABS_LLVM_DIR}"
env

if [[ -n "${gcc_toolchain}" ]]; then
  # Copy in the right stdlibc++.so.6 so clang can start.
  mkdir -p lib
  cp -v "$(${CXX} ${CXXFLAGS} -print-file-name=libstdc++.so.6)" lib/
fi

ninja

STRIP_FLAGS=
if [ "${OS}" = "Darwin" ]; then
  # See http://crbug.com/256342
  STRIP_FLAGS=-x

  cp libcxxbuild/libc++.1.dylib bin/
fi
strip ${STRIP_FLAGS} bin/clang
popd

# Build compiler-rt out-of-tree.
mkdir -p "${COMPILER_RT_BUILD_DIR}"
pushd "${COMPILER_RT_BUILD_DIR}"

rm -fv CMakeCache.txt
MACOSX_DEPLOYMENT_TARGET=${deployment_target} cmake -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_ENABLE_THREADS=OFF \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DLLVM_CONFIG_PATH="${ABS_LLVM_BUILD_DIR}/bin/llvm-config" \
    "${ABS_COMPILER_RT_DIR}"

ninja

# Copy selected output to the main tree.
# Darwin doesn't support cp --parents, so pipe through tar instead.
CLANG_VERSION=$("${ABS_LLVM_BUILD_DIR}/bin/clang" --version | \
     sed -ne 's/clang version \([0-9]\.[0-9]\.[0-9]\).*/\1/p')
ABS_LLVM_CLANG_LIB_DIR="${ABS_LLVM_BUILD_DIR}/lib/clang/${CLANG_VERSION}"
tar -c *blacklist.txt | tar -C ${ABS_LLVM_CLANG_LIB_DIR} -xv
tar -c include/sanitizer | tar -C ${ABS_LLVM_CLANG_LIB_DIR} -xv
if [[ "${OS}" = "Darwin" ]]; then
  tar -c lib/darwin | tar -C ${ABS_LLVM_CLANG_LIB_DIR} -xv
else
  tar -c lib/linux | tar -C ${ABS_LLVM_CLANG_LIB_DIR} -xv
fi

popd

if [[ -n "${with_android}" ]]; then
  # Make a standalone Android toolchain.
  ${ANDROID_NDK_DIR}/build/tools/make-standalone-toolchain.sh \
      --platform=android-14 \
      --install-dir="${LLVM_BUILD_DIR}/android-toolchain" \
      --system=linux-x86_64 \
      --stl=stlport

  # Android NDK r9d copies a broken unwind.h into the toolchain, see
  # http://crbug.com/357890
  rm -v "${LLVM_BUILD_DIR}"/android-toolchain/include/c++/*/unwind.h

  # Build ASan runtime for Android in a separate build tree.
  mkdir -p ${LLVM_BUILD_DIR}/android
  pushd ${LLVM_BUILD_DIR}/android
  rm -fv CMakeCache.txt
  MACOSX_DEPLOYMENT_TARGET=${deployment_target} cmake -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DLLVM_ENABLE_THREADS=OFF \
      -DCMAKE_C_COMPILER=${PWD}/../bin/clang \
      -DCMAKE_CXX_COMPILER=${PWD}/../bin/clang++ \
      -DLLVM_CONFIG_PATH=${PWD}/../bin/llvm-config \
      -DCMAKE_C_FLAGS="--target=arm-linux-androideabi --sysroot=${PWD}/../android-toolchain/sysroot -B${PWD}/../android-toolchain" \
      -DCMAKE_CXX_FLAGS="--target=arm-linux-androideabi --sysroot=${PWD}/../android-toolchain/sysroot -B${PWD}/../android-toolchain" \
      -DANDROID=1 \
      "${ABS_COMPILER_RT_DIR}"
  ninja clang_rt.asan-arm-android

  # And copy it into the main build tree.
  cp "$(find -name libclang_rt.asan-arm-android.so)" "${ABS_LLVM_CLANG_LIB_DIR}/lib/linux/"
  popd
fi

# Build Chrome-specific clang tools. Paths in this list should be relative to
# tools/clang.
TOOL_SRC_DIR="${PWD}/${THIS_DIR}/../"
TOOL_BUILD_DIR="${ABS_LLVM_BUILD_DIR}/tools/clang/tools/chrome-extras"

rm -rf "${TOOL_BUILD_DIR}"
mkdir -p "${TOOL_BUILD_DIR}"
pushd "${TOOL_BUILD_DIR}"
rm -fv CMakeCache.txt
MACOSX_DEPLOYMENT_TARGET=${deployment_target} cmake -GNinja  \
    -DLLVM_BUILD_DIR="${ABS_LLVM_BUILD_DIR}" \
    -DLLVM_SRC_DIR="${ABS_LLVM_DIR}" \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
    -DCMAKE_MODULE_LINKER_FLAGS="${LDFLAGS}" \
    -DCMAKE_INSTALL_PREFIX="${ABS_LLVM_BUILD_DIR}" \
    -DCHROMIUM_TOOLS="${chrome_tools}" \
    "${TOOL_SRC_DIR}"
popd
ninja -C "${TOOL_BUILD_DIR}" install

if [[ -n "$run_tests" ]]; then
  # Run Chrome tool tests.
  ninja -C "${TOOL_BUILD_DIR}" check-all
  # Run the LLVM and Clang tests.
  ninja -C "${LLVM_BUILD_DIR}" check-all
fi

# After everything is done, log success for this revision.
echo "${CLANG_AND_PLUGINS_REVISION}" > "${STAMP_FILE}"
