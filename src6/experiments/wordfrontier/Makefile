ZIG ?= /home/agent/.local/bin/zig
WGP6 := ../wordgrammar/wgp6
WPG := ../word_constructions
GWT := ../wordgrammar/geometry

.PHONY: all test native-decoder
all:
	$(MAKE) -C $(WGP6) ZIG=$(ZIG) m_reference native native_forward native_forward_hoist reparse_context
	$(MAKE) -C $(WPG) ZIG=$(ZIG) all
	$(MAKE) -C $(GWT) all
	$(MAKE) native-decoder

native-decoder: $(WPG)/libwpgjobs.a
	bash build_native_decode.sh $(WPG)/libwpgjobs.a wordfrontier-decode

$(WPG)/libwpgjobs.a:
	$(MAKE) -C $(WPG) ZIG=$(ZIG) libwpgjobs.a

test:
	python3 test_wordfrontier.py -v
