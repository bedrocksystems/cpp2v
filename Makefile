#
# Copyright (C) BedRock Systems Inc. 2019-2020
#
# SPDX-License-Identifier: LGPL-2.1 WITH BedRock Exception for use over network, see repository root for details.
#

default_target: coq cpp2v
.PHONY: default_target

CMAKE=$$(which cmake)
COQMAKEFILE=$(COQBIN)coq_makefile

CPPMK := $(MAKE) -C build
COQMK := $(MAKE) -f Makefile.coq
DOCMK := $(MAKE) -C doc

ROOT := $(shell pwd)
include doc/old/Makefile.doc

OPAM_PREFIX := $(shell opam config var prefix)
BINDIR = $(OPAM_PREFIX)/bin



all: coq cpp2v test
.PHONY: all





# Build the `cpp2v` tool


# On Darwin, customize the cmake build system to use homebrew's llvm.
SYS := $(shell uname)

BUILDARG=
ifeq ($(SYS),Darwin)
# Not needed under Nix.
ifeq ($(CLANG_DIR),)
	BUILDARG +=-D'CMAKE_SHARED_LINKER_FLAGS=-L/usr/local/opt/llvm/lib -lclangSerialization -lclangASTMatchers -lclangSema -lclangAnalysis -lclangRewriteFrontend -lclangEdit -lclangParse -lclangFrontend -lclangBasic -lclangDriver -lclangAST -lclangLex -lz -lcurses' -DCMAKE_EXE_LINKER_FLAGS=-L/usr/local/opt/llvm/lib
endif
endif

BUILD_TYPE ?= Release

build/Makefile: Makefile CMakeLists.txt
	$(CMAKE) -B build $(BUILDARG) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE)

tocoq: build/Makefile
	+$(CPPMK) tocoq
.PHONY: tocoq

cpp2v: tocoq
	+$(CPPMK) cpp2v
.PHONY: cpp2v



# Build Coq theories

Makefile.coq Makefile.coq.conf: _CoqProject Makefile
	+$(COQMAKEFILE) -f _CoqProject -o Makefile.coq

coq: Makefile.coq
	+$(COQMK)
.PHONY: coq

# Pass a few useful targets on to the Coq makefile
%.vo %.required_vo: Makefile.coq
	+@$(COQMK) $@




# Tests for `cpp2v`

test: test-cpp2v test-coq
.PHONY: test

build-minimal: Makefile.coq
	+@$(COQMK) theories/lang/cpp/parser.vo
	mkdir -p build
	rm -f build/bedrock
	ln -s $(ROOT)/theories build/bedrock
.PHONY: build-minimal

test-cpp2v: build-minimal cpp2v
	+@$(MAKE) -C cpp2v-tests CPP2V=$(ROOT)/build/cpp2v
.PHONY: test-cpp2v

test-coq: cpp2v coq
	+@$(MAKE) -C tests CPP2V=$(ROOT)/build/cpp2v
.PHONY: test-cpp2v


# Build Coq docs

html doc: coq doc_extra
	rm -rf public
	rm -rf html
	$(COQMK) html
	mkdir -p doc/old/html
	mv html/* doc/old/html && rmdir html
	cp -r doc_extra/extra/resources/* doc/old/html
	$(DOCMK) html # generates html files in `doc/old/html`
.PHONY: html doc

doc_extra:
	git clone --depth 1 https://github.com/coq-community/coqdocjs.git doc_extra

public: html
	mv doc/sphinx/_build/html public
.PHONY: public






# Install targets (coq, cpp2v, or both)

install-coq: coq
	+$(COQMK) install
.PHONY: install-coq

install-cpp2v: cpp2v
	install -m 0755 build/cpp2v "$(BINDIR)"
.PHONY: install-cpp2v

install: install-coq install-cpp2v
.PHONY: install




# Clean

clean:
	rm -rf build
	+@$(DOCMK) $@
	+@$(MAKE) -C cpp2v-tests clean
	+@if test -f Makefile.coq; then $(COQMK) cleanall; fi
	rm -f Makefile.coq Makefile.coq.conf
	find . ! -path '*/.git/*' -name '.lia.cache' -type f -print0 | xargs -0 rm -f
.PHONY: clean






# Packaging

link: coq
	mkdir -p build
	rm -f build/bedrock
	ln -s $(ROOT)/theories build/bedrock
.PHONY: link



release: coq cpp2v
	rm -rf cpp2v
	mkdir cpp2v
	cp -p build/cpp2v cpp2v
	cp -pr theories cpp2v/bedrock
.PHONY: release




touch_deps:
	touch `find -iname *.vo`  || true
	touch `find -iname *.vok` || true
	touch `find -iname *.vos` || true
	touch `find -iname *.glob` || true
	touch `find -iname *.aux` || true
	touch `find tests/cpp2v-parser/ -iname *.v` || true
	touch `find build` || true
.PHONY: touch_deps




deps.pdf: _CoqProject
	coqdep -f _CoqProject -dumpgraphbox deps.dot > /dev/null
	dot -Tpdf -o deps.pdf deps.dot
