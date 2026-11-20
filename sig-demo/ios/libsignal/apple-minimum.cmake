# The pinned BoringSSL CMake build otherwise inherits the active SDK minimum.
# Apply to C, C++, and assembly, including the upstream explicitly-set ASM flags.
set(CMAKE_OSX_DEPLOYMENT_TARGET "16.0" CACHE STRING "sig demo minimum iOS version" FORCE)
