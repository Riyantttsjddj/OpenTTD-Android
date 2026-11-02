# Android (arm64-v8a) build support.
#
# Android reuses OpenTTD's Unix code for video, sound and the filesystem.  On
# top of that it needs a different program entry point, and a browser hand-off
# that goes through the activity instead of exec'ing a process; both live in
# src/os/android.  The writable directories the game expects are created by the
# activity before it starts native code, so nothing here has to find them.
#
# The desktop OpenGL backend is deliberately unavailable: it requests a GL 3.3
# core context through <GL/gl.h>, which Android does not provide.  The SDL2
# software rasteriser is used instead.
if(NOT ANDROID)
    return()
endif()

message(STATUS "Configuring OpenTTD for Android (${ANDROID_ABI}, API ${ANDROID_PLATFORM_LEVEL})")

# The C++ runtime has to be the shared one, and has to be asked for on the cmake
# command line -- this is too late for the variable to have any effect.
#
# The toolchain turns ANDROID_STL into linker flags while it is being included,
# before this file runs, so all that is left to do here is insist that it was set
# correctly.  Passing it as -DANDROID_STL=c++_shared is what actually works.
#
# Why shared: SDL2 is a second shared library, and it was built with the
# toolchain's default of c++_static, so it carries its own copy of libc++ and
# exports operator new, the type_info vtables and the exception machinery from
# it.  If the game statically linked libc++ as well, the process would hold two
# copies of all of that, and a std::string or std::exception crossing between the
# game and SDL would be built by one and interpreted by the other.  That does not
# fail at link time; it fails later and elsewhere, as a dynamic_cast returning
# null or a catch that never matches.
if(NOT ANDROID_STL STREQUAL "c++_shared")
    message(FATAL_ERROR
        "This port must be configured with -DANDROID_STL=c++_shared (got "
        "\"${ANDROID_STL}\"), so that the game and SDL2 share one C++ runtime.")
endif()

# FindOpenGL has already run by now and may have resolved the *host's* libGL --
# a library the target can neither link nor run against.  The accelerated
# backend is unavailable on Android anyway, so the result is discarded.
set(OPENGL_FOUND FALSE)
set(OPENGL_gl_LIBRARY OPENGL_gl_LIBRARY-NOTFOUND)
set(OPENGL_opengl_LIBRARY OPENGL_opengl_LIBRARY-NOTFOUND)

# Android gives the app a private directory that is the only writable place it
# has.  Rather than nest the game's data one level below it, the personal
# directory *is* that directory: this is what the activity's environment points
# at, and Java unpacks the bundled data straight into it.
#
# The definition of PERSONAL_DIR itself is made at the bottom of the top-level
# CMakeLists, next to the one every other platform goes through, because the
# project defines it for all platforms there.  Only the cache entry is handled
# here: setting it to the "(not set)" sentinel the project itself uses to mean
# "no personal directory suffix" keeps that later block from redefining it.
set(PERSONAL_DIR "(not set)" CACHE STRING "Personal directory" FORCE)

# src/os/unix/unix_main.cpp is a desktop main().  Android starts native code
# from the activity through SDL, so the game gets its own entry point instead.
get_target_property(OPENTTD_SOURCES openttd SOURCES)
list(FILTER OPENTTD_SOURCES EXCLUDE REGEX "/os/unix/unix_main\\.cpp$")
set_target_properties(openttd PROPERTIES SOURCES "${OPENTTD_SOURCES}")

# SDLActivity dlopen()s the game library and dlsym()s "SDL_main" out of it, so
# the file has to be a shared object named libmain.so, exactly as SDL's own
# Android template names it.  The target is already a library (see the top-level
# CMakeLists); only its name needs to be the one SDL looks for.
set_target_properties(openttd PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "main"
)

# The Android linker resolves libraries by soname from the platform and from the
# app's own native library directory; there is no rpath, so nothing may be
# recorded about where this build happened to find its dependencies.
set_target_properties(openttd PROPERTIES
    BUILD_RPATH ""
    INSTALL_RPATH ""
    BUILD_WITH_INSTALL_RPATH FALSE
    SKIP_BUILD_RPATH TRUE
    INSTALL_RPATH_USE_LINK_PATH FALSE
)

# Android 15 runs on devices whose memory pages are 16 KiB rather than 4 KiB,
# and such a device refuses to map a library whose LOAD segments are only 4 KiB
# aligned.  Aligning the segments after the fact is not possible -- the
# alignment is baked into the program headers -- so the linker is asked for it.
# Nothing in the build system sets this, and the default is the smaller page.
target_link_options(openttd PRIVATE "LINKER:-z,max-page-size=16384")

target_sources(openttd PRIVATE
    ${CMAKE_SOURCE_DIR}/src/os/android/android_main.cpp
)
