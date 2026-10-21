cmake_minimum_required(VERSION 3.18...3.31 FATAL_ERROR)

project(easyrpg_godot
    VERSION 0.0.1
    DESCRIPTION "EasyRPG / ynoengine GDExtension for Godot 4"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(EASYRPG_BUILD_WEB "Build for Emscripten/WASM (Godot Web export)" OFF)

set(YNOENGINE_DIR  "${CMAKE_CURRENT_SOURCE_DIR}/ynoengine-master")
set(GODOTCPP_DIR   "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp-master")
set(GDEXT_SRC_DIR  "${CMAKE_CURRENT_SOURCE_DIR}/gdextension/src")

set(PLAYER_TARGET_PLATFORM "godot" CACHE STRING "Platform: godot"  FORCE)
set(PLAYER_AUDIO_BACKEND   "godot" CACHE STRING "Audio: godot"     FORCE)
set(PLAYER_HAS_AUDIO       ON      CACHE BOOL   "Enable audio"     FORCE)
set(PLAYER_BUILD_LIBLCF    ON      CACHE BOOL   "Build liblcf from source" FORCE)
set(BUILD_SHARED_LIBS      ON      CACHE BOOL   "Build shared libraries"     FORCE)

set(PLAYER_ENABLE_DRWAV    ON  CACHE BOOL "Built-in WAV decoder (dr_wav)"    FORCE)
set(PLAYER_ENABLE_FMMIDI   ON  CACHE BOOL "Built-in MIDI sequencer (fmmidi)" FORCE)
set(PLAYER_WITH_OPUS       ON  CACHE BOOL "Enable Opus via opusfile"         FORCE)
set(PLAYER_WITH_MPG123     ON  CACHE BOOL "Enable libmpg123 (MP3 support)" FORCE)
set(PLAYER_WITH_LIBSNDFILE ON  CACHE BOOL "Enable libsndfile"  FORCE)
set(PLAYER_WITH_OGGVORBIS  ON  CACHE BOOL "Enable libvorbis"   FORCE)
set(PLAYER_WITH_WILDMIDI   ON  CACHE BOOL "Enable wildmidi"    FORCE)
set(PLAYER_WITH_FLUIDSYNTH ON  CACHE BOOL "Enable fluidsynth"  FORCE)
set(PLAYER_WITH_FLUIDLITE  ON  CACHE BOOL "Enable fluidlite"   FORCE)
set(PLAYER_WITH_XMP        ON  CACHE BOOL "Enable libxmp"      FORCE)

add_subdirectory(${YNOENGINE_DIR} ynoengine_build EXCLUDE_FROM_ALL)

set(YNOENGINE_TARGET EasyRPG_Player)

target_compile_definitions(${YNOENGINE_TARGET} PUBLIC
    PLAYER_MULTIPLAYER_CALLBACK_ONLY=1
)

add_subdirectory(${GODOTCPP_DIR} godotcpp_build)

set(GDEXT_SOURCES
    ${GDEXT_SRC_DIR}/register_types.cpp
    ${GDEXT_SRC_DIR}/rpgmaker_player.cpp
)

add_library(easyrpg_godot SHARED ${GDEXT_SOURCES})

target_link_libraries(easyrpg_godot PRIVATE
    godot-cpp
    ${YNOENGINE_TARGET}
)

target_include_directories(easyrpg_godot PRIVATE
    ${GDEXT_SRC_DIR}
    ${YNOENGINE_DIR}/src
    ${YNOENGINE_DIR}/src/platform/godot
)

# Position-independent code (required for shared libraries)
set_property(TARGET easyrpg_godot PROPERTY POSITION_INDEPENDENT_CODE ON)
set_property(TARGET ${YNOENGINE_TARGET} PROPERTY POSITION_INDEPENDENT_CODE ON)

set(GDE_OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/demo/bin")

set_target_properties(easyrpg_godot PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY          "${GDE_OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY          "${GDE_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG    "${GDE_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE  "${GDE_OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY_DEBUG    "${GDE_OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY_RELEASE  "${GDE_OUTPUT_DIR}"
)

if(EMSCRIPTEN OR EASYRPG_BUILD_WEB)
    set_target_properties(easyrpg_godot PROPERTIES
        PREFIX  ""
        SUFFIX  ".wasm"
        LINK_FLAGS "-sSIDE_MODULE=1"
    )
    target_compile_definitions(easyrpg_godot PRIVATE EMSCRIPTEN=1)
elseif(WIN32)
    set_target_properties(easyrpg_godot PROPERTIES
        PREFIX ""
        SUFFIX ".dll"
        WINDOWS_EXPORT_ALL_SYMBOLS ON
    )
elseif(APPLE)
    if(CMAKE_BUILD_TYPE STREQUAL "Debug" OR CMAKE_BUILD_TYPE STREQUAL "")
        set(_BUILD_SUFFIX "debug")
    else()
        set(_BUILD_SUFFIX "release")
    endif()
    set_target_properties(easyrpg_godot PROPERTIES
        PREFIX       "lib"
        SUFFIX       ".dylib"
        OUTPUT_NAME  "easyrpg_godot.macos.${_BUILD_SUFFIX}"
    )
elseif(ANDROID)
    set_target_properties(easyrpg_godot PROPERTIES
        PREFIX "lib"
        SUFFIX "_arm64.so"
        DEBUG_POSTFIX "d"
    )
else()
    # Linux
    set_target_properties(easyrpg_godot PROPERTIES
        PREFIX "lib"
        SUFFIX ".so"
    )
endif()

message(STATUS "")
message(STATUS "=== EasyRPG Godot GDExtension ===")
message(STATUS "  ynoengine dir : ${YNOENGINE_DIR}")
message(STATUS "  godot-cpp dir : ${GODOTCPP_DIR}")
message(STATUS "  Output dir    : ${CMAKE_CURRENT_SOURCE_DIR}/demo/bin")
message(STATUS "  Web build     : ${EASYRPG_BUILD_WEB}")
message(STATUS "")
