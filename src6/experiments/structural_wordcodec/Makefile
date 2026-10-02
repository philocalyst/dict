CXX ?= g++
CXXFLAGS ?= -std=c++17 -O3 -Wall -Wextra
all: swc
swc: swc.cpp
	$(CXX) $(CXXFLAGS) $< -o $@
clean:
	rm -f swc
.PHONY: all clean
