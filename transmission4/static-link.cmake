# Read after project() through CMAKE_PROJECT_INCLUDE (assemble-payload.sh):
# the binaries are linked fully static, so find only static libraries. The
# platform files set this variable during project(), which is why it can't
# simply be passed with -D.
set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
