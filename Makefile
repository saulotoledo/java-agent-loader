EMACS ?= emacs
CASK ?= cask

all: test

test: clean-elc
	$(EMACS) -Q -batch -f batch-byte-compile *.el

clean-elc:
	rm -f *.elc

clean: clean-elc
	rm -rf .cask

.PHONY: all test clean-elc clean
