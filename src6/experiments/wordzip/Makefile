CXX ?= c++
CXXFLAGS ?= -O3 -DNDEBUG -std=c++17 -Wall -Wextra

all: sbwt sbwt-auto sbwt-select sbwt-unicode-auto wordzip

sbwt: sbwt.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

sbwt-auto: sbwt_auto.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

sbwt-select: sbwt_select.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

sbwt-unicode-auto: sbwt_unicode_auto.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

sbwt-utf8: sbwt_utf8.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

sbwt-session: sbwt_session.cpp sbwt.cpp
	$(CXX) $(CXXFLAGS) -ffunction-sections -fdata-sections -Wl,--gc-sections $< -o $@

wordzip: wordzip.cpp
	$(CXX) $(CXXFLAGS) $< -lzstd -o $@

test: sbwt
	python3 test_codec.py

test-all: sbwt sbwt-auto sbwt-select sbwt-unicode-auto
	python3 test_codec.py
	WORDZIP_EXE="$(CURDIR)/sbwt-auto" WORDZIP_ENCODER_OPTIONS='["--auto","1"]' python3 test_codec.py
	WORDZIP_EXE="$(CURDIR)/sbwt-select" WORDZIP_ENCODER_OPTIONS='["--choice","1"]' python3 test_codec.py
	WORDZIP_EXE="$(CURDIR)/sbwt-unicode-auto" WORDZIP_ENCODER_OPTIONS='["--unicode-auto","1"]' python3 test_codec.py

test-session: sbwt sbwt-select sbwt-session
	python3 test_session.py

clean:
	rm -f sbwt wordzip sbwt-lab sbwt-auto sbwt-select sbwt-unicode-auto sbwt-utf8 sbwt-session

.PHONY: all test test-all test-session clean
