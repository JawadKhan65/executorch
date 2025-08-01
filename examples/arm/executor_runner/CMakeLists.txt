# Copyright 2023-2025 Arm Limited and/or its affiliates.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

cmake_minimum_required(VERSION 3.20)
project(arm_executor_runner)

option(SEMIHOSTING "Enable semihosting" OFF)
option(ET_ARM_BAREMETAL_METHOD_ALLOCATOR_POOL_SIZE "Set ET_ARM_BAREMETAL_METHOD_ALLOCATOR_POOL_SIZE to specify memory alloction pool size" OFF)
option(ET_BUNDLE_IO "Set to compile in BundleIO support" OFF)
option(ET_ATOL "Set atol to use for BundleIO testing" OFF)
option(ET_RTOL "Set rtol to use for BundleIO testing" OFF)
option(ET_DUMP_INPUT "Dump input in log" OFF)
option(ET_DUMP_OUTPUT "Dump output in log" ON)
option(FETCH_ETHOS_U_CONTENT "Fetch ethos_u dependencies instead of relying on pre-downloads" ON)

if(NOT DEFINED ET_PTE_FILE_PATH AND NOT ${SEMIHOSTING})
  message(
    FATAL_ERROR
      "ET_PTE_FILE_PATH must specify a model .pte or .bpte, for bare metal systems the "
      "model is built into the binary."
  )
endif()

# Example ExecuTorch demo for bare metal Cortex-M based systems
set(ET_DIR_PATH
    "../../.."
    CACHE PATH "Path to ExecuTorch dir"
)
set(ET_BUILD_DIR_PATH
    "${ET_DIR_PATH}/cmake-out"
    CACHE PATH "Path to ExecuTorch build dir"
)
set(ET_INCLUDE_PATH
    "${ET_DIR_PATH}/.."
    CACHE PATH "Path to ExecuTorch headers"
)
set(ET_PTE_FILE_PATH
    ""
    CACHE PATH "Path to ExecuTorch model pte"
)
set(ETHOS_SDK_PATH
    "${ET_DIR_PATH}/examples/arm/ethos-u-scratch/ethos-u"
    CACHE PATH "Path to Ethos-U bare metal driver/env"
)
set(PYTHON_EXECUTABLE
    "python"
    CACHE PATH "Define to override python executable used"
)

if(FETCH_ETHOS_U_CONTENT)
  # Download ethos_u dependency if needed.
  file(MAKE_DIRECTORY ${ETHOS_SDK_PATH}/../ethos_u)

  include(FetchContent)
  set(ethos_u_base_tag "25.05")
  FetchContent_Declare(
    ethos_u
    GIT_REPOSITORY https://git.gitlab.arm.com/artificial-intelligence/ethos-u/ethos-u.git
    GIT_TAG ${ethos_u_base_tag}
    SOURCE_DIR ${ETHOS_SDK_PATH}
    BINARY_DIR ${ETHOS_SDK_PATH}
    SUBBUILD_DIR ${ETHOS_SDK_PATH}/../ethos_u-subbuild
    SOURCE_SUBDIR none
  )

  FetchContent_MakeAvailable(ethos_u)

  # Patch manifest to remove unused projects.
  set(patch_dir "${ET_DIR_PATH}/examples/arm/ethos-u-setup")
  set(ethos_u_base_rev "24950bd4381b6c51db0349a229f8ba86b8e1093f")
  execute_process(COMMAND bash -c "pwd && source backends/arm/scripts/utils.sh && patch_repo ${ETHOS_SDK_PATH} ${ethos_u_base_rev} ${patch_dir}"
    WORKING_DIRECTORY ${ET_DIR_PATH}
    COMMAND_ECHO STDOUT
  )

  # Get ethos_u externals only if core_platform folder does not already exist.
  if(NOT EXISTS "${ETHOS_SDK_PATH}/core_platform")
    execute_process(COMMAND ${PYTHON_EXECUTABLE} fetch_externals.py -c ${ethos_u_base_tag}.json fetch
                    WORKING_DIRECTORY ${ETHOS_SDK_PATH}
                    COMMAND_ECHO STDOUT
    )
  endif()

  # Patch core_software to remove unused projects.
  set(core_software_base_rev "55904c3da73c876c6d6c58290938ae217a8b94bd")
  execute_process(COMMAND bash -c "pwd && source backends/arm/scripts/utils.sh && patch_repo ${ETHOS_SDK_PATH}/core_software ${core_software_base_rev} ${patch_dir}"
    WORKING_DIRECTORY ${ET_DIR_PATH}
    COMMAND_ECHO STDOUT
  )

  # Always patch the core_platform repo since this is fast enough.
  set(core_platform_base_rev "1916a9c984819c35b19c9e5c4c80d47e4e866420")
  execute_process(COMMAND bash -c "pwd && source backends/arm/scripts/utils.sh && patch_repo ${ETHOS_SDK_PATH}/core_platform ${core_platform_base_rev} ${patch_dir}"
    WORKING_DIRECTORY ${ET_DIR_PATH}
    COMMAND_ECHO STDOUT
  )
endif()

# Selects timing adapter values matching system_config.
# Default is Ethos_U55_High_End_Embedded, simulating optimal hardware for the Corestone-300.
set(SYSTEM_CONFIG "Ethos_U55_High_End_Embedded" CACHE STRING "System config")
set(MEMORY_MODE "Shared_Sram" CACHE STRING "Vela memory mode")

message(STATUS "SYSTEM_CONFIG is ${SYSTEM_CONFIG}")
message(STATUS "MEMORY_MODE is ${MEMORY_MODE}")

get_filename_component(ET_BUILD_DIR_PATH ${ET_BUILD_DIR_PATH} REALPATH)
get_filename_component(ET_DIR_PATH ${ET_DIR_PATH} REALPATH)
get_filename_component(ET_INCLUDE_PATH ${ET_INCLUDE_PATH} REALPATH)
get_filename_component(ETHOS_SDK_PATH ${ETHOS_SDK_PATH} REALPATH)
if(NOT ${SEMIHOSTING})
  get_filename_component(ET_PTE_FILE_PATH ${ET_PTE_FILE_PATH} REALPATH)
endif()

if(SYSTEM_CONFIG MATCHES "Ethos_U55")
  add_subdirectory(${ETHOS_SDK_PATH}/core_platform/targets/corstone-300 target)
elseif(SYSTEM_CONFIG MATCHES "Ethos_U85")
  add_subdirectory(${ETHOS_SDK_PATH}/core_platform/targets/corstone-320 target)
else()
  message(FATAL_ERROR "Unsupported SYSTEM_CONFIG ${SYSTEM_CONFIG}.")
endif()

if(MEMORY_MODE MATCHES "Dedicated_Sram")
  target_compile_definitions(ethosu_target_common INTERFACE
    ETHOSU_MODEL=1
    ETHOSU_ARENA=1)
elseif(MEMORY_MODE MATCHES "Shared_Sram" OR MEMORY_MODE MATCHES "Sram_Only")
  target_compile_definitions(ethosu_target_common INTERFACE
    ETHOSU_MODEL=1
    ETHOSU_ARENA=0)
else()
  message(FATAL_ERROR "Unsupported MEMORY_MODE ${MEMORY_MODE}. Memory_mode can be Shared_Sram, Sram_Only or Dedicated_Sram(applicable for the Ethos-U85)")
endif()

# By default, use 2MB of temporary scratch buffer
# For Dedicated_Sram, use 64MB for the temporary scratch buffer and
# 384KB for the fast scratch buffer(the cache, applicable only for Ethos-U65 and Ethos-U85)
set(ET_ARM_BAREMETAL_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE 0x200000)
if(MEMORY_MODE MATCHES "Dedicated_Sram")
  set(ET_ARM_BAREMETAL_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE 0x4000000)
  set(ET_ARM_BAREMETAL_FAST_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE 0x60000)
endif()
message(STATUS "ET_ARM_BAREMETAL_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE = ${ET_ARM_BAREMETAL_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE}")
message(STATUS "ET_ARM_BAREMETAL_FAST_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE = ${ET_ARM_BAREMETAL_FAST_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE}")

# Dependencies from the Ethos-U Core This is the platform target of
# Corstone-300, that includes ethosu_core_driver and bare-metal bringup
# libraries. We link against ethosu_target_init which includes all of these
# dependencies.
if(SYSTEM_CONFIG MATCHES "Ethos_U55_High_End_Embedded")
  set(TARGET_BOARD "corstone-300")
  if(MEMORY_MODE MATCHES "Shared_Sram")
    target_compile_definitions(ethosu_target_common INTERFACE
        # Configure NPU architecture timing adapters
        # This is just example numbers and you should make this match your hardware
        # SRAM
        ETHOSU_TA_MAXR_0=8
        ETHOSU_TA_MAXW_0=8
        ETHOSU_TA_MAXRW_0=0
        ETHOSU_TA_RLATENCY_0=32
        ETHOSU_TA_WLATENCY_0=32
        ETHOSU_TA_PULSE_ON_0=3999
        ETHOSU_TA_PULSE_OFF_0=1
        ETHOSU_TA_BWCAP_0=4000
        ETHOSU_TA_PERFCTRL_0=0
        ETHOSU_TA_PERFCNT_0=0
        ETHOSU_TA_MODE_0=1
        ETHOSU_TA_HISTBIN_0=0
        ETHOSU_TA_HISTCNT_0=0
        # Flash
        ETHOSU_TA_MAXR_1=2
        ETHOSU_TA_MAXW_1=0
        ETHOSU_TA_MAXRW_1=0
        ETHOSU_TA_RLATENCY_1=64
        ETHOSU_TA_WLATENCY_1=0
        ETHOSU_TA_PULSE_ON_1=320
        ETHOSU_TA_PULSE_OFF_1=80
        ETHOSU_TA_BWCAP_1=50
        ETHOSU_TA_PERFCTRL_1=0
        ETHOSU_TA_PERFCNT_1=0
        ETHOSU_TA_MODE_1=1
        ETHOSU_TA_HISTBIN_1=0
        ETHOSU_TA_HISTCNT_1=0
        )
  elseif(MEMORY_MODE MATCHES "Sram_Only")
    target_compile_definitions(ethosu_target_common INTERFACE
      # This is just example numbers and you should make this match your hardware
      # SRAM
      ETHOSU_TA_MAXR_0=8
      ETHOSU_TA_MAXW_0=8
      ETHOSU_TA_MAXRW_0=0
      ETHOSU_TA_RLATENCY_0=32
      ETHOSU_TA_WLATENCY_0=32
      ETHOSU_TA_PULSE_ON_0=3999
      ETHOSU_TA_PULSE_OFF_0=1
      ETHOSU_TA_BWCAP_0=4000
      ETHOSU_TA_PERFCTRL_0=0
      ETHOSU_TA_PERFCNT_0=0
      ETHOSU_TA_MODE_0=1
      ETHOSU_TA_HISTBIN_0=0
      ETHOSU_TA_HISTCNT_0=0
      # Set the second Timing Adapter to SRAM latency & bandwidth
      ETHOSU_TA_MAXR_1=8
      ETHOSU_TA_MAXW_1=8
      ETHOSU_TA_MAXRW_1=0
      ETHOSU_TA_RLATENCY_1=32
      ETHOSU_TA_WLATENCY_1=32
      ETHOSU_TA_PULSE_ON_1=3999
      ETHOSU_TA_PULSE_OFF_1=1
      ETHOSU_TA_BWCAP_1=4000
      ETHOSU_TA_PERFCTRL_1=0
      ETHOSU_TA_PERFCNT_1=0
      ETHOSU_TA_MODE_1=1
      ETHOSU_TA_HISTBIN_1=0
      ETHOSU_TA_HISTCNT_1=0
      )

  else()
    message(FATAL_ERROR "Unsupported memory_mode ${MEMORY_MODE} for the Ethos-U55. The Ethos-U55 supports only Shared_Sram and Sram_Only.")
  endif()
elseif(SYSTEM_CONFIG MATCHES "Ethos_U55_Deep_Embedded")
  add_subdirectory(${ETHOS_SDK_PATH}/core_platform/targets/corstone-300 target)
  set(TARGET_BOARD "corstone-300")
  if(MEMORY_MODE MATCHES "Shared_Sram")
    target_compile_definitions(ethosu_target_common INTERFACE
        # Configure NPU architecture timing adapters
        # This is just example numbers and you should make this match your hardware
        # SRAM
        ETHOSU_TA_MAXR_0=4
        ETHOSU_TA_MAXW_0=4
        ETHOSU_TA_MAXRW_0=0
        ETHOSU_TA_RLATENCY_0=8
        ETHOSU_TA_WLATENCY_0=8
        ETHOSU_TA_PULSE_ON_0=3999
        ETHOSU_TA_PULSE_OFF_0=1
        ETHOSU_TA_BWCAP_0=4000
        ETHOSU_TA_PERFCTRL_0=0
        ETHOSU_TA_PERFCNT_0=0
        ETHOSU_TA_MODE_0=1
        ETHOSU_TA_HISTBIN_0=0
        ETHOSU_TA_HISTCNT_0=0
        # Flash
        ETHOSU_TA_MAXR_1=2
        ETHOSU_TA_MAXW_1=0
        ETHOSU_TA_MAXRW_1=0
        ETHOSU_TA_RLATENCY_1=32
        ETHOSU_TA_WLATENCY_1=0
        ETHOSU_TA_PULSE_ON_1=360
        ETHOSU_TA_PULSE_OFF_1=40
        ETHOSU_TA_BWCAP_1=25
        ETHOSU_TA_PERFCTRL_1=0
        ETHOSU_TA_PERFCNT_1=0
        ETHOSU_TA_MODE_1=1
        ETHOSU_TA_HISTBIN_1=0
        ETHOSU_TA_HISTCNT_1=0
        )
    elseif(MEMORY_MODE MATCHES "Sram_Only")
      target_compile_definitions(ethosu_target_common INTERFACE
      # Configure NPU architecture timing adapters
      # This is just example numbers and you should make this match your hardware
      # SRAM
      ETHOSU_TA_MAXR_0=4
      ETHOSU_TA_MAXW_0=4
      ETHOSU_TA_MAXRW_0=0
      ETHOSU_TA_RLATENCY_0=8
      ETHOSU_TA_WLATENCY_0=8
      ETHOSU_TA_PULSE_ON_0=3999
      ETHOSU_TA_PULSE_OFF_0=1
      ETHOSU_TA_BWCAP_0=4000
      ETHOSU_TA_PERFCTRL_0=0
      ETHOSU_TA_PERFCNT_0=0
      ETHOSU_TA_MODE_0=1
      ETHOSU_TA_HISTBIN_0=0
      ETHOSU_TA_HISTCNT_0=0
      # Set the second Timing Adapter to SRAM latency & bandwidth
      ETHOSU_TA_MAXR_1=4
      ETHOSU_TA_MAXW_1=4
      ETHOSU_TA_MAXRW_1=0
      ETHOSU_TA_RLATENCY_1=8
      ETHOSU_TA_WLATENCY_1=8
      ETHOSU_TA_PULSE_ON_1=3999
      ETHOSU_TA_PULSE_OFF_1=1
      ETHOSU_TA_BWCAP_1=4000
      ETHOSU_TA_PERFCTRL_1=0
      ETHOSU_TA_PERFCNT_1=0
      ETHOSU_TA_MODE_1=1
      ETHOSU_TA_HISTBIN_1=0
      ETHOSU_TA_HISTCNT_1=0
      )
    else()
      message(FATAL_ERROR "Unsupported memory_mode ${MEMORY_MODE} for the Ethos-U55. The Ethos-U55 supports only Shared_Sram and Sram_Only.")
  endif()
elseif(SYSTEM_CONFIG MATCHES "Ethos_U85_SYS_DRAM_Low")
  add_subdirectory(${ETHOS_SDK_PATH}/core_platform/targets/corstone-320 target)
  set(TARGET_BOARD "corstone-320")
  if(MEMORY_MODE MATCHES "Dedicated_Sram")
    target_compile_definitions(ethosu_target_common INTERFACE
        # Configure NPU architecture timing adapters
        # This is just example numbers and you should make this match your hardware
        # SRAM
        ETHOSU_TA_MAXR_0=8
        ETHOSU_TA_MAXW_0=8
        ETHOSU_TA_MAXRW_0=0
        ETHOSU_TA_RLATENCY_0=16
        ETHOSU_TA_WLATENCY_0=16
        ETHOSU_TA_PULSE_ON_0=3999
        ETHOSU_TA_PULSE_OFF_0=1
        ETHOSU_TA_BWCAP_0=4000
        ETHOSU_TA_PERFCTRL_0=0
        ETHOSU_TA_PERFCNT_0=0
        ETHOSU_TA_MODE_0=1
        ETHOSU_TA_HISTBIN_0=0
        ETHOSU_TA_HISTCNT_0=0
        # DRAM
        ETHOSU_TA_MAXR_1=24
        ETHOSU_TA_MAXW_1=12
        ETHOSU_TA_MAXRW_1=0
        ETHOSU_TA_RLATENCY_1=250
        ETHOSU_TA_WLATENCY_1=125
        ETHOSU_TA_PULSE_ON_1=4000
        ETHOSU_TA_PULSE_OFF_1=1000
        ETHOSU_TA_BWCAP_1=2344
        ETHOSU_TA_PERFCTRL_1=0
        ETHOSU_TA_PERFCNT_1=0
        ETHOSU_TA_MODE_1=1
        ETHOSU_TA_HISTBIN_1=0
        ETHOSU_TA_HISTCNT_1=0
        )
  elseif(MEMORY_MODE MATCHES "Sram_Only")
      target_compile_definitions(ethosu_target_common INTERFACE
      # Configure NPU architecture timing adapters
      # This is just example numbers and you should make this match your hardware
      # SRAM
      ETHOSU_TA_MAXR_0=8
      ETHOSU_TA_MAXW_0=8
      ETHOSU_TA_MAXRW_0=0
      ETHOSU_TA_RLATENCY_0=16
      ETHOSU_TA_WLATENCY_0=16
      ETHOSU_TA_PULSE_ON_0=3999
      ETHOSU_TA_PULSE_OFF_0=1
      ETHOSU_TA_BWCAP_0=4000
      ETHOSU_TA_PERFCTRL_0=0
      ETHOSU_TA_PERFCNT_0=0
      ETHOSU_TA_MODE_0=1
      ETHOSU_TA_HISTBIN_0=0
      ETHOSU_TA_HISTCNT_0=0
      # Set the second Timing Adapter to SRAM latency & bandwidth
      ETHOSU_TA_MAXR_1=8
      ETHOSU_TA_MAXW_1=8
      ETHOSU_TA_MAXRW_1=0
      ETHOSU_TA_RLATENCY_1=16
      ETHOSU_TA_WLATENCY_1=16
      ETHOSU_TA_PULSE_ON_1=3999
      ETHOSU_TA_PULSE_OFF_1=1
      ETHOSU_TA_BWCAP_1=4000
      ETHOSU_TA_PERFCTRL_1=0
      ETHOSU_TA_PERFCNT_1=0
      ETHOSU_TA_MODE_1=1
      ETHOSU_TA_HISTBIN_1=0
      ETHOSU_TA_HISTCNT_1=0
      )
  endif()
elseif(SYSTEM_CONFIG STREQUAL "Ethos_U85_SYS_DRAM_Mid" OR SYSTEM_CONFIG STREQUAL "Ethos_U85_SYS_DRAM_High")
  set(TARGET_BOARD "corstone-320")
  if(MEMORY_MODE MATCHES "Dedicated_Sram")
    target_compile_definitions(ethosu_target_common INTERFACE
        # Configure NPU architecture timing adapters
        # This is just example numbers and you should make this match your hardware
        # SRAM
        ETHOSU_TA_MAXR_0=8
        ETHOSU_TA_MAXW_0=8
        ETHOSU_TA_MAXRW_0=0
        ETHOSU_TA_RLATENCY_0=32
        ETHOSU_TA_WLATENCY_0=32
        ETHOSU_TA_PULSE_ON_0=3999
        ETHOSU_TA_PULSE_OFF_0=1
        ETHOSU_TA_BWCAP_0=4000
        ETHOSU_TA_PERFCTRL_0=0
        ETHOSU_TA_PERFCNT_0=0
        ETHOSU_TA_MODE_0=1
        ETHOSU_TA_HISTBIN_0=0
        ETHOSU_TA_HISTCNT_0=0
        # DRAM
        ETHOSU_TA_MAXR_1=64
        ETHOSU_TA_MAXW_1=32
        ETHOSU_TA_MAXRW_1=0
        ETHOSU_TA_RLATENCY_1=500
        ETHOSU_TA_WLATENCY_1=250
        ETHOSU_TA_PULSE_ON_1=4000
        ETHOSU_TA_PULSE_OFF_1=1000
        ETHOSU_TA_BWCAP_1=3750
        ETHOSU_TA_PERFCTRL_1=0
        ETHOSU_TA_PERFCNT_1=0
        ETHOSU_TA_MODE_1=1
        ETHOSU_TA_HISTBIN_1=0
        ETHOSU_TA_HISTCNT_1=0
        )
  elseif(MEMORY_MODE MATCHES "Sram_Only")
    target_compile_definitions(ethosu_target_common INTERFACE
    # Configure NPU architecture timing adapters
    # This is just example numbers and you should make this match your hardware
    # SRAM
    ETHOSU_TA_MAXR_0=8
    ETHOSU_TA_MAXW_0=8
    ETHOSU_TA_MAXRW_0=0
    ETHOSU_TA_RLATENCY_0=32
    ETHOSU_TA_WLATENCY_0=32
    ETHOSU_TA_PULSE_ON_0=3999
    ETHOSU_TA_PULSE_OFF_0=1
    ETHOSU_TA_BWCAP_0=4000
    ETHOSU_TA_PERFCTRL_0=0
    ETHOSU_TA_PERFCNT_0=0
    ETHOSU_TA_MODE_0=1
    ETHOSU_TA_HISTBIN_0=0
    ETHOSU_TA_HISTCNT_0=0
    # Set the second Timing Adapter to SRAM latency & bandwidth
    ETHOSU_TA_MAXR_1=8
    ETHOSU_TA_MAXW_1=8
    ETHOSU_TA_MAXRW_1=0
    ETHOSU_TA_RLATENCY_1=32
    ETHOSU_TA_WLATENCY_1=32
    ETHOSU_TA_PULSE_ON_1=3999
    ETHOSU_TA_PULSE_OFF_1=1
    ETHOSU_TA_BWCAP_1=4000
    ETHOSU_TA_PERFCTRL_1=0
    ETHOSU_TA_PERFCNT_1=0
    ETHOSU_TA_MODE_1=1
    ETHOSU_TA_HISTBIN_1=0
    ETHOSU_TA_HISTCNT_1=0
    )
  endif()
else()
  message(FATAL_ERROR "Unsupported SYSTEM_CONFIG: ${SYSTEM_CONFIG}")
endif()

# The REGIONCFG registers of the Ethos-U control whether the NPU
# reads/writes data through the SRAM or the external memory.
# By default, the Ethos-U driver provides REGIONCFG configuration for Shared Sram memory mode.
# For Sram_Only and Dedicated_Sram memory modes, we need to change the settings for optimal performance.
#
# Currently, the convention used by Vela and the Ethos-U driver is that the NPU uses:
# Region 0 for traffic of the Read-Only data(weights & biases)
# Region 1 for traffic of of the intermediate Read/Write buffers required for the computation
# Region 2 for traffic of of the cache in Dedicated_Sram memory mode(not applicable in Sram_Only or Shared_Sram)
#
# NOTE: The above convention is determined by the Vela compiler and the Ethos-U driver and can change in the future.
#
# Common definitions:
# For Ethos-U55/U65/U85, region configs are set as:
#   0 or 1 = AXI0 (Ethos-U55 or Ethos-U65) or AXI_SRAM(Ethos-U85)
#   2 or 3 = AXI1 (Ethos-U55 or Ethos-U65) or AXI_EXT(Ethos-U85)
#
# When we compile a model for Sram_Only, the memory traffic for Region 0 and Region 1 should pass via the SRAM(hence regioncfg = 1)
# When we compile a model for Dedicated_Sram, the memory traffic for Region 0 should pass via the external memory(3),
# the memory traffic of Region 1 should pass via the external memory(3) and the traffic for Region 2 should pass via the SRAM(0)
#

if(MEMORY_MODE MATCHES "Sram_Only")
  target_compile_definitions(ethosu_core_driver PRIVATE
      NPU_QCONFIG=1
      NPU_REGIONCFG_0=1
      NPU_REGIONCFG_1=0
      NPU_REGIONCFG_2=0
      NPU_REGIONCFG_3=0
      NPU_REGIONCFG_4=0
      NPU_REGIONCFG_5=0
      NPU_REGIONCFG_6=0
      NPU_REGIONCFG_7=0)
  elseif(MEMORY_MODE MATCHES "Dedicated_Sram")
    target_compile_definitions(ethosu_core_driver PRIVATE
      NPU_QCONFIG=3
      NPU_REGIONCFG_0=3
      NPU_REGIONCFG_1=3
      NPU_REGIONCFG_2=0
      NPU_REGIONCFG_3=0
      NPU_REGIONCFG_4=0
      NPU_REGIONCFG_5=0
      NPU_REGIONCFG_6=0
      NPU_REGIONCFG_7=0)
endif()


# Dependencies from the ExecuTorch build
add_library(executorch STATIC IMPORTED)
set_property(
  TARGET executorch PROPERTY IMPORTED_LOCATION
                             "${ET_BUILD_DIR_PATH}/libexecutorch.a"
)

add_library(executorch_core STATIC IMPORTED)
set_property(
  TARGET executorch_core
  PROPERTY IMPORTED_LOCATION "${ET_BUILD_DIR_PATH}/libexecutorch_core.a"
)
target_link_libraries(executorch INTERFACE executorch_core)

add_library(executorch_delegate_ethos_u STATIC IMPORTED)
set_property(
  TARGET executorch_delegate_ethos_u
  PROPERTY IMPORTED_LOCATION
           "${ET_BUILD_DIR_PATH}/backends/arm/libexecutorch_delegate_ethos_u.a"
)

add_library(portable_ops_lib STATIC IMPORTED)
set_property(
  TARGET portable_ops_lib
  PROPERTY IMPORTED_LOCATION
           "${ET_BUILD_DIR_PATH}/examples/arm/libarm_portable_ops_lib.a"
)
add_library(portable_kernels STATIC IMPORTED)
set_property(
  TARGET portable_kernels
  PROPERTY IMPORTED_LOCATION
           "${ET_BUILD_DIR_PATH}/kernels/portable/libportable_kernels.a"
)
add_library(quantized_ops_lib STATIC IMPORTED)
set_property(
  TARGET quantized_ops_lib
  PROPERTY IMPORTED_LOCATION
           "${ET_BUILD_DIR_PATH}/kernels/quantized/libquantized_ops_lib.a"
)
add_library(quantized_kernels STATIC IMPORTED)
set_property(
  TARGET quantized_kernels
  PROPERTY IMPORTED_LOCATION
           "${ET_BUILD_DIR_PATH}/kernels/quantized/libquantized_kernels.a"
)
add_library(cortex_m_ops_lib STATIC IMPORTED)
set_property(
  TARGET cortex_m_ops_lib
  PROPERTY IMPORTED_LOCATION
           "${ET_BUILD_DIR_PATH}/backends/cortex_m/libcortex_m_ops_lib.a"
)
add_library(cortex_m_kernels STATIC IMPORTED)
set_property(
  TARGET cortex_m_kernels
  PROPERTY IMPORTED_LOCATION
           "${ET_BUILD_DIR_PATH}/backends/cortex_m/libcortex_m_kernels.a"
)
add_library(extension_runner_util STATIC IMPORTED)
set_property(
  TARGET extension_runner_util
  PROPERTY
    IMPORTED_LOCATION
    "${ET_BUILD_DIR_PATH}/extension/runner_util/libextension_runner_util.a"
)

# Convert pte to header
if(NOT ${SEMIHOSTING})
  add_custom_target(
    gen_model_header DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/model_pte.h
  )

  add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/model_pte.h
    COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_SOURCE_DIR}/pte_to_header.py --pte
            ${ET_PTE_FILE_PATH} --outdir ${CMAKE_CURRENT_BINARY_DIR}
    DEPENDS ${ET_PTE_FILE_PATH}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  )
endif()

# The arm_executor_runner executable
add_executable(arm_executor_runner)

target_sources(
  arm_executor_runner PRIVATE arm_executor_runner.cpp arm_perf_monitor.cpp arm_memory_allocator.cpp
)

# Include the target's bare-metal linker script
ethosu_eval_link_options(arm_executor_runner)

set(arm_executor_runner_link)
list(APPEND arm_executor_runner_link
  extension_runner_util
  ethosu_target_init
  executorch
  "-Wl,--whole-archive"
  executorch_delegate_ethos_u
  cortex_m_ops_lib
  quantized_ops_lib
  portable_ops_lib
  quantized_kernels
  cortex_m_kernels
  portable_kernels
  "-Wl,--no-whole-archive"
  -Xlinker -Map=arm_executor_runner.map
)

if(EXECUTORCH_ENABLE_EVENT_TRACER)
  target_compile_options(arm_executor_runner PUBLIC -DET_EVENT_TRACER_ENABLED)

  add_library(etdump STATIC IMPORTED)
  set_property(
      TARGET etdump
      PROPERTY IMPORTED_LOCATION
            "${ET_BUILD_DIR_PATH}/lib/libetdump.a"
  )

  add_library(flatccrt STATIC IMPORTED)
  set_property(
      TARGET flatccrt
      PROPERTY IMPORTED_LOCATION
            "${ET_BUILD_DIR_PATH}/lib/libflatccrt.a"
  )

  list(APPEND arm_executor_runner_link
    etdump
    flatccrt
  )
endif()

if(ET_BUNDLE_IO)
  add_library(bundled_program STATIC IMPORTED)
  set_property(
    TARGET bundled_program
    PROPERTY IMPORTED_LOCATION
        "${ET_BUILD_DIR_PATH}/lib/libbundled_program.a"
  )
  list(APPEND arm_executor_runner_link
    bundled_program
  )
endif()

# Need whole-archive to ensure C++ ctor's are called - this may be wasteful for
# bin size as we link in a number of other symbols
target_link_libraries(
  arm_executor_runner
  ${arm_executor_runner_link}
)

target_link_options( arm_executor_runner PUBLIC LINKER:-Map=arm_executor_runner.map )

# ET headers and generated headers includes
target_include_directories(
  arm_executor_runner PRIVATE ${ET_INCLUDE_PATH} ${ET_DIR_PATH}/runtime/core/portable_type/c10 ${CMAKE_CURRENT_BINARY_DIR}
)
target_compile_definitions(arm_executor_runner PRIVATE C10_USING_CUSTOM_GENERATED_MACROS)

if(SEMIHOSTING)
  target_compile_definitions(arm_executor_runner PUBLIC SEMIHOSTING)
else()
  add_dependencies(arm_executor_runner gen_model_header)
endif()

if(ET_ARM_BAREMETAL_METHOD_ALLOCATOR_POOL_SIZE)
  target_compile_definitions(arm_executor_runner PUBLIC ET_ARM_BAREMETAL_METHOD_ALLOCATOR_POOL_SIZE=${ET_ARM_BAREMETAL_METHOD_ALLOCATOR_POOL_SIZE})
endif()

target_compile_definitions(arm_executor_runner PUBLIC ET_ARM_BAREMETAL_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE=${ET_ARM_BAREMETAL_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE})
if(DEFINED ET_ARM_BAREMETAL_FAST_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE)
  target_compile_definitions(arm_executor_runner PUBLIC ET_ARM_BAREMETAL_FAST_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE=${ET_ARM_BAREMETAL_FAST_SCRATCH_TEMP_ALLOCATOR_POOL_SIZE})
endif()

if(ET_BUNDLE_IO)
  target_compile_definitions(arm_executor_runner PUBLIC -DET_BUNDLE_IO)
endif()

if(ET_ATOL)
  target_compile_definitions(arm_executor_runner PUBLIC ET_ATOL=${ET_ATOL})
endif()

if(ET_RTOL)
  target_compile_definitions(arm_executor_runner PUBLIC ET_RTOL=${ET_RTOL})
endif()

if(ET_DUMP_INPUT)
  target_compile_definitions(arm_executor_runner PUBLIC -DET_DUMP_INPUT)
endif()

if(ET_DUMP_OUTPUT)
  target_compile_definitions(arm_executor_runner PUBLIC -DET_DUMP_OUTPUT)
endif()

# Fixup compilation of retarget.c
if(SEMIHOSTING)
  # Remove this when MLBEDSW-8910 is closed.
  set_source_files_properties(
    ${ETHOS_SDK_PATH}/core_platform/targets/${TARGET_BOARD}/retarget.c
    PROPERTIES HEADER_FILE_ONLY TRUE
  )
endif()
