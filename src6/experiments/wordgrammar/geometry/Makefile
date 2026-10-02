CXX ?= g++
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -Werror
WPG := ../../word_constructions

.PHONY: all test clean
all: geometry_decode prepared_geometry

geometry_decode: geometry_decode.cpp geometry_residual.h
	$(CXX) $(CXXFLAGS) geometry_decode.cpp -o $@

# This links the frozen WPG2 C ABI; it does not rebuild or modify v4 sources.
prepared_geometry: prepared_geometry.cpp geometry_residual.h $(WPG)/prepared_jobs.h $(WPG)/libwpgjobs.a
	$(CXX) $(CXXFLAGS) prepared_geometry.cpp $(WPG)/libwpgjobs.a -no-pie -pthread -lm -o $@

test: all
	python3 test_residual_native.py

clean:
	rm -f geometry_decode prepared_geometry
