CXX ?= g++
ZIG ?= zig
BZ4 := ../../bzip4/bz4/v3/src/root.zig

all: prepare_maximal native

experiments: prepare compile prepare_activation prepare_doublets prepare_preinline prepare_phrase prepare_phrase_after compile_sweeps compile_combined

prepare: prepare.cpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

prepare_activation: prepare_activation.cpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

prepare_maximal: prepare_maximal.cpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

reparse_context: reparse_context.cpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

prepare_nameprice: prepare_nameprice.cpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

native_nameprice: native_nameprice.zig $(wildcard ../../bzip4/bz4/v3/src/*.zig)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=native_nameprice.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

prepare_role: prepare_role.cpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

native_role: native_role.zig $(wildcard role_backend/*.zig)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=native_role.zig -O ReleaseFast -Mbz4=role_backend/root.zig -femit-bin=$@

native_role_root: native_role_root.zig $(wildcard role_root_backend/*.zig)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=native_role_root.zig -O ReleaseFast -Mbz4=role_root_backend/root.zig -femit-bin=$@

native_hoist: native_hoist.zig $(wildcard ../../bzip4/bz4/v3/src/*.zig)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=native_hoist.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

prepare_m: prepare_m.zig ../../bzip4/bz4/m_lexicon.zig
	$(ZIG) build-exe --dep lex -O ReleaseFast -Mroot=prepare_m.zig -O ReleaseFast -Mlex=../../bzip4/bz4/m_lexicon.zig -femit-bin=$@

m_reference: m_reference.zig budget.zig learner_epochs.zig lifetime_fit.zig ../../bzip4/bz4/m_lexicon.zig ../../bzip4/bz4/grammar2.zig $(wildcard ../../bzip4/bz4/v3/src/*.zig)
	$(ZIG) build-exe --dep lex --dep gram --dep bz4 -O ReleaseFast -Mroot=m_reference.zig -O ReleaseFast -Mlex=../../bzip4/bz4/m_lexicon.zig -O ReleaseFast -Mgram=../../bzip4/bz4/grammar2.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

prepare_doublets: prepare_doublets.cpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

prepare_preinline: prepare_preinline.cpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

prepare_phrase: prepare_phrase.cpp research/phrase_mdl.hpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

prepare_phrase_after: prepare_phrase_after.cpp research/phrase_mdl.hpp
	$(CXX) -std=c++17 -O3 -DNDEBUG -Wall -Wextra $< -o $@

compile: compile.zig $(BZ4)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=compile.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

compile_sweeps: compile_sweeps.zig $(BZ4)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=compile_sweeps.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

compile_combined: compile_combined.zig $(BZ4)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=compile_combined.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

native: native.zig $(wildcard ../../bzip4/bz4/v3/src/*.zig)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=native.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

native_forward: native_forward.zig $(wildcard ../../bzip4/bz4/v3/src/*.zig)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=native_forward.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

native_forward_hoist: native_forward_hoist.zig $(wildcard ../../bzip4/bz4/v3/src/*.zig)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=native_forward_hoist.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

test: all
	python3 test_pipeline.py

clean:
	rm -f prepare prepare_activation prepare_maximal prepare_nameprice prepare_doublets prepare_preinline prepare_phrase prepare_phrase_after prepare_role prepare_m prepare_m.o compile compile.o compile_sweeps compile_sweeps.o compile_combined compile_combined.o native native.o native_nameprice native_nameprice.o native_role native_role.o native_hoist native_hoist.o native_role_root native_role_root.o m_reference m_reference.o prepare_m prepare_m.o native_forward native_forward.o native_forward_hoist native_forward_hoist.o reparse_context lifetime_fit_probe lifetime_fit_probe.o

.PHONY: all experiments clean test
