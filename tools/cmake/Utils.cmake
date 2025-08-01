# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

#
# This file is intended to have helper functions to keep the CMakeLists.txt
# concise. If there are any helper function can be re-used, it's recommented to
# add them here.
#
# ### Editing this file ###
#
# This file should be formatted with
# ~~~
# cmake-format -i Utils.cmake
# ~~~
# It should also be cmake-lint clean.
#

# This is the funtion to use -Wl, --whole-archive to link static library NB:
# target_link_options is broken for this case, it only append the interface link
# options of the first library.
function(executorch_kernel_link_options target_name)
  # target_link_options(${target_name} INTERFACE
  # "$<LINK_LIBRARY:WHOLE_ARCHIVE,target_name>")
  target_link_options(
    ${target_name} INTERFACE "SHELL:LINKER:--whole-archive \
    $<TARGET_FILE:${target_name}> \
    LINKER:--no-whole-archive"
  )
endfunction()

# Same as executorch_kernel_link_options but it's for MacOS linker
function(executorch_macos_kernel_link_options target_name)
  target_link_options(
    ${target_name} INTERFACE
    "SHELL:LINKER:-force_load,$<TARGET_FILE:${target_name}>"
  )
endfunction()

# Same as executorch_kernel_link_options but it's for MSVC linker
function(executorch_msvc_kernel_link_options target_name)
  target_link_options(
    ${target_name} INTERFACE
    "SHELL:LINKER:/WHOLEARCHIVE:$<TARGET_FILE:${target_name}>"
  )
endfunction()

# Ensure that the load-time constructor functions run. By default, the linker
# would remove them since there are no other references to them.
function(executorch_target_link_options_shared_lib target_name)
  if(APPLE)
    executorch_macos_kernel_link_options(${target_name})
  elseif(MSVC)
    executorch_msvc_kernel_link_options(${target_name})
  else()
    executorch_kernel_link_options(${target_name})
  endif()
endfunction()

function(target_link_options_gc_sections target_name)
  if(APPLE)
    target_link_options(${target_name} PRIVATE "LINKER:-dead_strip")
  else()
    target_link_options(${target_name} PRIVATE "LINKER:--gc-sections")
  endif()
endfunction()

# Extract source files based on toml config. This is useful to keep buck2 and
# cmake aligned. Do not regenerate if file exists.
function(extract_sources sources_file)
  if(EXISTS "${sources_file}")
    message(STATUS "executorch: Using source file list ${sources_file}")
  else()
    # A file wasn't generated. Run a script to extract the source lists from the
    # buck2 build system and write them to a file we can include.
    #
    # NOTE: This will only happen once during cmake setup, so it will not re-run
    # if the buck2 targets change.
    message(STATUS "executorch: Generating source file list ${sources_file}")
    if(EXECUTORCH_ROOT)
      set(executorch_root ${EXECUTORCH_ROOT})
    else()
      set(executorch_root ${CMAKE_CURRENT_SOURCE_DIR})
    endif()

    if(ANDROID_ABI)
      if("${ANDROID_ABI}" STREQUAL "arm64-v8a")
        set(target_platforms_arg "--target-platforms=shim_et//:android-arm64")
      elseif("${ANDROID_ABI}" STREQUAL "x86_64")
        set(target_platforms_arg "--target-platforms=shim_et//:android-x86_64")
      else()
        message(
          FATAL_ERROR
            "Unsupported ANDROID_ABI setting ${ANDROID_ABI}. Please add it here!"
        )
      endif()
    endif()
    execute_process(
      COMMAND
        ${PYTHON_EXECUTABLE} ${executorch_root}/tools/cmake/extract_sources.py
        --config=${executorch_root}/tools/cmake/cmake_deps.toml
        --out=${sources_file} --buck2=${BUCK2} ${target_platforms_arg}
      OUTPUT_VARIABLE gen_srcs_output
      ERROR_VARIABLE gen_srcs_error
      RESULT_VARIABLE gen_srcs_exit_code
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )

    if(NOT gen_srcs_exit_code EQUAL 0)
      message("Error while generating ${sources_file}. "
              "Exit code: ${gen_srcs_exit_code}"
      )
      message("Output:\n${gen_srcs_output}")
      message("Error:\n${gen_srcs_error}")
      message(FATAL_ERROR "executorch: source list generation failed")
    endif()
  endif()
endfunction()

# Sets the value of the BUCK2 variable by searching for a buck2 binary with the
# correct version.
#
# The resolve_buck.py script uses the following logic to find buck2: 1) If BUCK2
# argument is set explicitly, use it. Warn if the version is incorrect. 2) Look
# for a binary named buck2 on the system path. Take it if it is the correct
# version. 3) Check for a previously downloaded buck2 binary (from step 4). 4)
# Download and cache correct version of buck2.
function(resolve_buck2)
  if(EXECUTORCH_ROOT)
    set(executorch_root ${EXECUTORCH_ROOT})
  else()
    set(executorch_root ${CMAKE_CURRENT_SOURCE_DIR})
  endif()

  set(resolve_buck2_command
      ${PYTHON_EXECUTABLE} ${executorch_root}/tools/cmake/resolve_buck.py
      --cache_dir=${executorch_root}/buck2-bin
  )

  if(NOT ${BUCK2} STREQUAL "")
    list(APPEND resolve_buck2_command --buck2=${BUCK2})
  endif()

  execute_process(
    COMMAND ${resolve_buck2_command}
    OUTPUT_VARIABLE resolve_buck2_output
    ERROR_VARIABLE resolve_buck2_error
    RESULT_VARIABLE resolve_buck2_exit_code
    WORKING_DIRECTORY ${executorch_root}
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )

  # $BUCK2 is a copy of the var from the parent scope. This block will set
  # $buck2 to the value we want to return.
  if(resolve_buck2_exit_code EQUAL 0)
    set(buck2 ${resolve_buck2_output})
    message(STATUS "Resolved buck2 as ${resolve_buck2_output}.")
  elseif(resolve_buck2_exit_code EQUAL 2)
    # Wrong buck version used. Stop here to ensure that the user sees the error.
    message(FATAL_ERROR "Failed to resolve buck2.\n${resolve_buck2_error}")
  else()
    # Unexpected failure of the script. Warn.
    message(WARNING "Failed to resolve buck2.")
    message(WARNING "${resolve_buck2_error}")

    if("${BUCK2}" STREQUAL "")
      set(buck2 "buck2")
    endif()
  endif()

  # Update the var in the parent scope. Note that this does not modify our local
  # $BUCK2 value.
  set(BUCK2
      "${buck2}"
      PARENT_SCOPE
  )

  # The buck2 daemon can get stuck. Killing it can help.
  message(STATUS "Killing buck2 daemon")
  execute_process(
    # Note that we need to use the local buck2 variable. BUCK2 is only set in
    # the parent scope, and can still be empty in this scope.
    COMMAND "${buck2} killall"
    WORKING_DIRECTORY ${executorch_root} COMMAND_ECHO STDOUT
  )
endfunction()

# Sets the value of the PYTHON_EXECUTABLE variable to 'python' if in an active
# (non-base) conda environment, and 'python3' otherwise. This maintains
# backwards compatibility for non-conda users and avoids conda users needing to
# explicitly set PYTHON_EXECUTABLE=python.
function(resolve_python_executable)
  # Counter-intuitively, CONDA_DEFAULT_ENV contains the name of the active
  # environment.
  if(DEFINED ENV{CONDA_DEFAULT_ENV} AND NOT $ENV{CONDA_DEFAULT_ENV} STREQUAL
                                        "base"
  )
    set(PYTHON_EXECUTABLE
        python
        PARENT_SCOPE
    )
  elseif(DEFINED ENV{VIRTUAL_ENV})
    set(PYTHON_EXECUTABLE
        $ENV{VIRTUAL_ENV}/bin/python3
        PARENT_SCOPE
    )
  else()
    set(PYTHON_EXECUTABLE
        python3
        PARENT_SCOPE
    )
  endif()
endfunction()

# find_package(Torch CONFIG REQUIRED) replacement for targets that have a
# header-only Torch dependency.
#
# Unlike find_package(Torch ...), this will only set TORCH_INCLUDE_DIRS in the
# parent scope. In particular, it will NOT set any of the following: -
# TORCH_FOUND - TORCH_LIBRARY - TORCH_CXX_FLAGS
function(find_package_torch_headers)
  # We implement this way rather than using find_package so that
  # cross-compilation can still use the host's installed copy of torch, since
  # the headers should be fine.
  get_torch_base_path(TORCH_BASE_PATH)
  set(TORCH_INCLUDE_DIRS
      "${TORCH_BASE_PATH}/include;${TORCH_BASE_PATH}/include/torch/csrc/api/include"
      PARENT_SCOPE
  )
endfunction()

# Return the base path to the installed Torch Python library in outVar.
function(get_torch_base_path outVar)
  if(NOT PYTHON_EXECUTABLE)
    resolve_python_executable()
  endif()
  execute_process(
    COMMAND
      "${PYTHON_EXECUTABLE}" -c
      "import importlib.util; print(importlib.util.find_spec('torch').submodule_search_locations[0])"
    OUTPUT_VARIABLE _tmp_torch_path
    ERROR_VARIABLE _tmp_torch_path_error
    RESULT_VARIABLE _tmp_torch_path_result COMMAND_ECHO STDERR
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  if(NOT _tmp_torch_path_result EQUAL 0)
    message("Error while adding torch to CMAKE_PREFIX_PATH. "
            "Exit code: ${_tmp_torch_path_result}"
    )
    message("Output:\n${_tmp_torch_path}")
    message(FATAL_ERROR "Error:\n${_tmp_torch_path_error}")
  endif()
  set(${outVar}
      ${_tmp_torch_path}
      PARENT_SCOPE
  )
endfunction()

# Add the Torch CMake configuration to CMAKE_PREFIX_PATH so that find_package
# can find Torch.
function(add_torch_to_cmake_prefix_path)
  get_torch_base_path(_tmp_torch_path)
  list(APPEND CMAKE_PREFIX_PATH "${_tmp_torch_path}")
  set(CMAKE_PREFIX_PATH
      "${CMAKE_PREFIX_PATH}"
      PARENT_SCOPE
  )
endfunction()

# Replacement for find_package(Torch CONFIG REQUIRED); sets up CMAKE_PREFIX_PATH
# first and only does the find once. If you have a header-only Torch dependency,
# use find_package_torch_headers instead!
macro(find_package_torch)
  if(NOT TARGET torch)
    add_torch_to_cmake_prefix_path()
    find_package(Torch CONFIG REQUIRED)
  endif()
endmacro()

# Modify ${targetName}'s INTERFACE_INCLUDE_DIRECTORIES by wrapping each entry in
# $<BUILD_INTERFACE:...> so that they work with CMake EXPORT.
function(executorch_move_interface_include_directories_to_build_time_only
         targetName
)
  get_property(
    OLD_INTERFACE_INCLUDE_DIRECTORIES
    TARGET "${targetName}"
    PROPERTY INTERFACE_INCLUDE_DIRECTORIES
  )
  set(FIXED_INTERFACE_INCLUDE_DIRECTORIES)
  foreach(dir ${OLD_INTERFACE_INCLUDE_DIRECTORIES})
    list(APPEND FIXED_INTERFACE_INCLUDE_DIRECTORIES $<BUILD_INTERFACE:${dir}>)
  endforeach()
  set_property(
    TARGET "${targetName}" PROPERTY INTERFACE_INCLUDE_DIRECTORIES
                                    ${FIXED_INTERFACE_INCLUDE_DIRECTORIES}
  )
endfunction()

function(executorch_add_prefix_to_public_headers targetName prefix)
  get_property(
    OLD_PUBLIC_HEADERS
    TARGET "${targetName}"
    PROPERTY PUBLIC_HEADER
  )
  set(FIXED_PUBLIC_HEADERS)
  foreach(header ${OLD_PUBLIC_HEADERS})
    list(APPEND FIXED_PUBLIC_HEADERS "${prefix}${header}")
  endforeach()
  set_property(
    TARGET "${targetName}" PROPERTY PUBLIC_HEADER ${FIXED_PUBLIC_HEADERS}
  )
endfunction()
