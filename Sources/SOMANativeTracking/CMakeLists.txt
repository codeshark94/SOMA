cmake_minimum_required(VERSION 3.16)

project(SOMANativeTracking LANGUAGES CXX)

include(CTest)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_library(IOKIT_FRAMEWORK IOKit REQUIRED)
find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)

function(configure_open_obsbot_target target)
    target_link_libraries(
        ${target}
        PRIVATE
        "${IOKIT_FRAMEWORK}"
        "${COREFOUNDATION_FRAMEWORK}"
    )
endfunction()

add_executable(
    soma-native-track
    OpenOBSBOTBridge.cpp
    OpenOBSBOTUVCTransport.cpp
)
configure_open_obsbot_target(soma-native-track)

add_executable(
    soma-obsbot-probe
    OpenOBSBOTProbe.cpp
    OpenOBSBOTUVCTransport.cpp
)
configure_open_obsbot_target(soma-obsbot-probe)

if(BUILD_TESTING)
    add_executable(
        soma-open-obsbot-protocol-tests
        OpenOBSBOTProtocolTests.cpp
    )
    add_test(
        NAME soma-open-obsbot-protocol-tests
        COMMAND soma-open-obsbot-protocol-tests
    )
endif()
