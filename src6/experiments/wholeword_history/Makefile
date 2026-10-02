ZIG ?= zig
BZ4 := ../bzip4/bz4/v3/src/root.zig
LEX := ../bzip4/bz4/m_lexicon.zig
GRAM := ../bzip4/bz4/grammar2.zig

all: m_whole whole_reader

m_whole: m_whole.zig budget.zig learner_epochs.zig lifetime_fit.zig $(LEX) $(GRAM) $(wildcard ../bzip4/bz4/v3/src/*.zig)
	$(ZIG) build-exe --dep lex --dep gram --dep bz4 -O ReleaseFast -Mroot=m_whole.zig -O ReleaseFast -Mlex=$(LEX) -O ReleaseFast -Mgram=$(GRAM) -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

whole_reader: whole_reader.zig budget.zig $(wildcard ../bzip4/bz4/v3/src/*.zig)
	$(ZIG) build-exe --dep bz4 -O ReleaseFast -Mroot=whole_reader.zig -O ReleaseFast -Mbz4=$(BZ4) -femit-bin=$@

.PHONY: all
