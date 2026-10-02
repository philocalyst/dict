CXX ?= g++
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -Werror
ZIG ?= /home/agent/.local/bin/zig

all: register_decode prepared_wpg

register_decode: register_decode.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

libwpgjobs.a: prepared_jobs.zig decoder_budget.zig prepared_jobs.h
	$(ZIG) build-lib --dep bz4 -O ReleaseFast -Mroot=prepared_jobs.zig -O ReleaseFast -Mbz4=../bzip4/bz4/v3/src/root.zig -femit-bin=$@

prepared_wpg: prepared_wpg.cpp register_decode.cpp prepared_jobs.h libwpgjobs.a
	$(CXX) $(CXXFLAGS) -Wno-unused-function -no-pie prepared_wpg.cpp libwpgjobs.a -o $@ -pthread -lm

test: all
	$(ZIG) test --dep bz4 -Mroot=test_prepared_budget.zig -Mbz4=../bzip4/bz4/v3/src/root.zig
	python3 test_registers.py -v
	python3 test_archive.py -v

.PHONY: all test
