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
set(
    OBSBOT_LIBRARY_PATH
    ""
    CACHE FILEPATH
    "Optional libdev.dylib runtime override for a device-specific official OBSBOT installation"
)

if(OBSBOT_LIBRARY_PATH)
    get_filename_component(OBSBOT_LIBRARY_DIR "${OBSBOT_LIBRARY_PATH}" DIRECTORY)
else()
    set(OBSBOT_LIBRARY_DIR "${OBSBOT_SDK_ROOT}/macos/arm64-release")
    if(NOT EXISTS "${OBSBOT_LIBRARY_DIR}/libdev.dylib")
        set(OBSBOT_LIBRARY_DIR "${OBSBOT_SDK_ROOT}/macos/macos/arm64-release")
    endif()
    set(OBSBOT_LIBRARY_PATH "${OBSBOT_LIBRARY_DIR}/libdev.dylib")
endif()

if(NOT EXISTS "${OBSBOT_SDK_ROOT}/include/dev/devs.hpp" OR NOT EXISTS "${OBSBOT_LIBRARY_PATH}")
    message(FATAL_ERROR "A macOS arm64 OBSBOT SDK is required. Set -DOBSBOT_SDK_ROOT=/path/to/libdev_v2.1.0_8")
endif()

function(configure_obsbot_target target)
    target_include_directories(${target} PRIVATE "${OBSBOT_SDK_ROOT}/include")
    target_link_libraries(${target} PRIVATE "${OBSBOT_LIBRARY_PATH}")
    set_target_properties(${target} PROPERTIES BUILD_RPATH "${OBSBOT_LIBRARY_DIR}")
endfunction()

add_executable(soma-native-track main.cpp OBSBOTDeviceAdapter.cpp)
configure_obsbot_target(soma-native-track)

add_executable(soma-obsbot-probe DeviceProbe.cpp OBSBOTDeviceAdapter.cpp)
configure_obsbot_target(soma-obsbot-probe)
