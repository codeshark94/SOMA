cmake_minimum_required(VERSION 3.16)

project(SOMANativeTracking LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(
    OBSBOT_SDK_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Reference/SDK/libdev_v2.1.0_8"
    CACHE PATH
    "Path to the supplied OBSBOT libdev_v2.1.0_8 SDK"
)
set(OBSBOT_LIBRARY_DIR "${OBSBOT_SDK_ROOT}/macos/arm64-release")
if(NOT EXISTS "${OBSBOT_LIBRARY_DIR}/libdev.dylib")
    set(OBSBOT_LIBRARY_DIR "${OBSBOT_SDK_ROOT}/macos/macos/arm64-release")
endif()

if(NOT EXISTS "${OBSBOT_SDK_ROOT}/include/dev/devs.hpp" OR NOT EXISTS "${OBSBOT_LIBRARY_DIR}/libdev.dylib")
    message(FATAL_ERROR "A macOS arm64 OBSBOT SDK is required. Set -DOBSBOT_SDK_ROOT=/path/to/libdev_v2.1.0_8")
endif()

add_executable(soma-native-track main.cpp)
target_include_directories(soma-native-track PRIVATE "${OBSBOT_SDK_ROOT}/include")
target_link_libraries(soma-native-track PRIVATE "${OBSBOT_LIBRARY_DIR}/libdev.dylib")
set_target_properties(
    soma-native-track
    PROPERTIES BUILD_RPATH "${OBSBOT_LIBRARY_DIR}"
)
