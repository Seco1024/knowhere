# ============ libfaiss.cmake (全部改寫後) ============

# 若需要包含一些 CMake Modules
include(ExternalProject)
include(GenerateExportHeader)

# ------------------------------------------------------------------------------
#  1. 建立 knowhere_utils (SSE/AVX/AVX512) 底層函式庫
#     原本 Knowhere 會自行編譯一些距離計算優化檔 (distances_sse.cc / avx 等)
#     這部分不一定和 Faiss 衝突，可以保留。
# ------------------------------------------------------------------------------

if(__X86_64)
  set(UTILS_SRC src/simd/distances_ref.cc src/simd/hook.cc)
  set(UTILS_SSE_SRC src/simd/distances_sse.cc)
  set(UTILS_AVX_SRC src/simd/distances_avx.cc)
  set(UTILS_AVX512_SRC src/simd/distances_avx512.cc)

  add_library(utils_sse OBJECT ${UTILS_SSE_SRC})
  add_library(utils_avx OBJECT ${UTILS_AVX_SRC})
  add_library(utils_avx512 OBJECT ${UTILS_AVX512_SRC})

  target_compile_options(utils_sse PRIVATE -msse4.2 -mpopcnt)
  target_compile_options(utils_avx PRIVATE -mfma -mf16c -mavx2 -mpopcnt)
  target_compile_options(utils_avx512 PRIVATE -mfma -mf16c -mavx512f -mavx512dq
                                              -mavx512bw -mpopcnt -mavx512vl)

  add_library(
    knowhere_utils STATIC
    ${UTILS_SRC}
    $<TARGET_OBJECTS:utils_sse>
    $<TARGET_OBJECTS:utils_avx>
    $<TARGET_OBJECTS:utils_avx512>)
  target_link_libraries(knowhere_utils PUBLIC glog::glog)
endif()

# 如果您還需要支援 __AARCH64 或 __PPC64，可以保留原本對 distances_neon.cc 或
# distances_powerpc.cc 的處理；這裡略。

# ------------------------------------------------------------------------------
#  2. 尋找 BLAS / LAPACK / OpenMP
#     Faiss 預設需要 BLAS + LAPACK + OpenMP
# ------------------------------------------------------------------------------
if(LINUX)
  set(BLA_VENDOR OpenBLAS)
endif()
if(APPLE)
  set(BLA_VENDOR Apple)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Android" AND CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
  find_package(OpenBLAS REQUIRED)
  set(BLAS_LIBRARIES OpenBLAS::OpenBLAS)
else()
  find_package(LAPACK REQUIRED)
  find_package(BLAS REQUIRED)
endif()
find_package(OpenMP REQUIRED)

# ------------------------------------------------------------------------------
#  3. 使用 ExternalProject_Add 來自 git@github.com:Seco1024/faiss.git (bfs branch)
# ------------------------------------------------------------------------------
# 這裡將 Faiss 安裝到 CMAKE_BINARY_DIR/faiss_install
# 您可改成任何路徑
# ------------------------------------------------------------------------------
set(FAISS_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/faiss_install")

ExternalProject_Add(
  external_faiss
  PREFIX "${CMAKE_BINARY_DIR}/external_faiss"
  GIT_REPOSITORY "git@github.com:Seco1024/faiss.git"
  GIT_TAG "bfs"                # 指定您要的 branch
  UPDATE_DISCONNECTED TRUE
  CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=${FAISS_INSTALL_PREFIX}
    # 如果您不需要 GPU，可加 -DFAISS_ENABLE_GPU=OFF
    -DBUILD_TESTING=OFF
    # 調整是否要動態或靜態
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DBLAS_LIBRARIES=${BLAS_LIBRARIES}
    -DLAPACK_LIBRARIES=${LAPACK_LIBRARIES}
    -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}
    -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}
  BUILD_COMMAND make -j8
  INSTALL_COMMAND make install
)

# ------------------------------------------------------------------------------
#  4. 宣告一個 IMPORTED target "faiss" 指向剛剛安裝好的 libfaiss
# ------------------------------------------------------------------------------
ExternalProject_Get_Property(external_faiss install_dir)
set(FAISS_INCLUDE_DIR "${install_dir}/include")
# 預設是 libfaiss.a，若您把 BUILD_SHARED_LIBS=ON 就改成 .so
set(FAISS_LIB_PATH    "${install_dir}/lib/libfaiss.a")

add_library(faiss STATIC IMPORTED)
set_target_properties(
  faiss
  PROPERTIES
    IMPORTED_LOCATION "${FAISS_LIB_PATH}"
    INTERFACE_INCLUDE_DIRECTORIES "${FAISS_INCLUDE_DIR}"
)

# 讓 "faiss" target 在編譯前先做 external_faiss
add_dependencies(faiss external_faiss)

# ------------------------------------------------------------------------------
#  5. 把 OpenMP + BLAS + LAPACK + knowhere_utils 等 link 到 "faiss"
# ------------------------------------------------------------------------------
target_link_libraries(
  faiss
  INTERFACE
    OpenMP::OpenMP_CXX
    ${BLAS_LIBRARIES}
    ${LAPACK_LIBRARIES}
    knowhere_utils
)

# 上面是把 faiss 設為 "INTERFACE" 連結, meaning 任何 link 到 faiss 的 target
# 會自動繼承這些依賴. 您也可以改成 PUBLIC, 取決於您要 how exporting the link.

# ------------------------------------------------------------------------------
#  6. (給 Knowhere 用) 最後在 Knowhere 的主 CMakeLists.txt 中:
#
#    include(cmake/libs/libfaiss.cmake)
#    target_link_libraries(knowhere PUBLIC faiss)
#
# 就可以把 "faiss" (您 BFS branch) 跟 Knowhere 連上。
# ------------------------------------------------------------------------------
