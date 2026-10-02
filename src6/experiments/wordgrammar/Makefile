CXX ?= g++
CXXFLAGS ?= -O3 -DNDEBUG -Wall -Wextra

.PHONY: all test sanitize clean
all: wordgrammar

wordgrammar: codec.cpp
	$(CXX) -std=c++17 $(CXXFLAGS) $< -o $@

test: wordgrammar
	python3 test_codec.py

sanitize:
	$(CXX) -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer codec.cpp -o wordgrammar-sanitize
	WGR_TEST_EXE=./wordgrammar-sanitize ASAN_OPTIONS=detect_leaks=1 python3 test_codec.py

clean:
	rm -f wordgrammar wordgrammar-sanitize
