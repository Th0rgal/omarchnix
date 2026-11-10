{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchzip,
  cmake,
  ninja,
  pkg-config,
  python3,
  openblas,
  vulkan-headers,
  vulkan-loader,
  shaderc,
  glslang,
  spirv-headers,
  patchelf,
}:
let
  isAarch64 = stdenv.hostPlatform.isAarch64;

  ggmlSrc = fetchFromGitHub {
    owner = "ggml-org";
    repo = "ggml";
    rev = "1b972bb754aa5f83e2d872ccf37a335717f6658d";
    hash = "sha256-fV0IJM0VgOsbRmXRDMkdThzUsePZFWo8Vv0iP4WBvOI=";
  };

  kleidiaiSrc = fetchzip {
    url = "https://github.com/ARM-software/kleidiai/releases/download/v1.24.0/kleidiai-v1.24.0-src.tar.gz";
    hash = "sha256-EqA/2Nu8/CGiBFK5EcCp6FVuBmmx6sV8x+g1Fx5HSh4=";
  };
in
stdenv.mkDerivation {
  pname = "crispasr-cohere";
  version = "0-unstable-2026-04-06";

  src = fetchFromGitHub {
    owner = "CrispStrobe";
    repo = "CrispASR";
    rev = "618f7260993f5aab4f9832689059725b4c3f2b6b";
    hash = "sha256-pr6QYKbq+WkdKQNRPjx3hKb4sgdg/GmZYFR8+zClZL0=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
    shaderc
    (shaderc.bin or shaderc)
    glslang
    patchelf
  ];

  buildInputs = [
    openblas
    vulkan-headers
    vulkan-loader
    spirv-headers
  ];

  postPatch = ''
    rm -rf ggml
    cp -r --no-preserve=mode,ownership "${ggmlSrc}" ggml

    cat > src/cohere_asr_stub.c <<'EOF'
    int crispasr_cohere_abi_anchor = 1;
    EOF

    cat >> src/CMakeLists.txt <<'EOF'
    add_library(cohere_asr SHARED cohere_asr_stub.c)
    target_link_libraries(cohere_asr PRIVATE
      -Wl,--whole-archive cohere -Wl,--no-whole-archive
      crispasr-core ggml ggml-base crispasr_link_ggml_cpu crispasr_link_ggml_vulkan
    )
    EOF
  '';

  cmakeFlags = [
    "-DBUILD_SHARED_LIBS=ON"
    "-DGGML_NATIVE=OFF"
    "-DGGML_VULKAN=ON"
    "-DGGML_BLAS=ON"
    "-DGGML_BLAS_VENDOR=OpenBLAS"
    "-DCRISPASR_BUILD_CLI=OFF"
    "-DCRISPASR_BUILD_SERVER=OFF"
    "-DCRISPASR_BUILD_EXAMPLES=OFF"
    "-DCRISPASR_BUILD_TESTS=OFF"
    "-DCRISPASR_C2PA_FETCH=OFF"
    "-DCRISPASR_NO_C2PA_NATIVE=ON"
    "-DVulkan_GLSLC_EXECUTABLE=${lib.getExe' shaderc "glslc"}"
  ]
  ++ lib.optionals isAarch64 [
    "-DGGML_CPU_KLEIDIAI=ON"
    "-DGGML_CPU_ARM_ARCH=armv8.6-a+dotprod+fp16+i8mm"
    "-DFETCHCONTENT_SOURCE_DIR_KLEIDIAI=${kleidiaiSrc}"
  ];

  ninjaFlags = [ "cohere_asr" ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/include"
    cp -a src/libcohere_asr.so* "$out/lib/"
    find ggml -name 'libggml*.so*' -exec cp -a {} "$out/lib/" \;
    install -m 0644 ../src/cohere.h "$out/include/cohere.h"

    rpath="$out/lib:${
      lib.makeLibraryPath [
        openblas
        vulkan-loader
        stdenv.cc.cc.lib
      ]
    }:/run/opengl-driver/lib"
    for f in "$out/lib/"*.so*; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then
        patchelf --set-rpath "$rpath" "$f"
      fi
    done
    runHook postInstall
  '';

  meta = {
    description = "CrispASR Cohere Transcribe C++ / GGML runtime with Apple M2 Vulkan & ARMv8.6 KleidiAI acceleration";
    homepage = "https://github.com/CrispStrobe/CrispASR";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
