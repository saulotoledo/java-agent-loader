EMACS ?= emacs
CASK ?= cask

JAL_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

all: test

compile: clean-elc
	$(EMACS) -Q -batch -L $(JAL_DIR) -f batch-byte-compile $(JAL_DIR)*.el

test: compile ert

ert:
	$(EMACS) -Q -batch \
	  -L $(JAL_DIR) \
	  -l $(JAL_DIR)tests/jal-test.el \
	  -f ert-run-tests-batch-and-exit

clean-elc:
	rm -f $(JAL_DIR)*.elc

clean: clean-elc
	rm -rf .cask

.PHONY: all compile test ert clean-elc clean
