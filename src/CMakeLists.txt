add_llvm_pass_plugin(CustomDSEPass
    CustomDSE.cpp
    DEPENDS
    intrinsics_gen
)

target_include_directories(CustomDSEPass PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
