configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/lit.site.cfg.py.in
    ${CMAKE_CURRENT_BINARY_DIR}/lit.site.cfg.py
    @ONLY
)

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/lit.cfg.py
    ${CMAKE_CURRENT_BINARY_DIR}/lit.cfg.py
    COPYONLY
)

# Copy test files to build directory
file(GLOB TEST_FILES "${CMAKE_CURRENT_SOURCE_DIR}/tests/*.ll")
file(COPY ${TEST_FILES} DESTINATION ${CMAKE_CURRENT_BINARY_DIR}/tests/)
