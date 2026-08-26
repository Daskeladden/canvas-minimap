# canvas-minimap -- a minimap drawn as pixels on an Emacs 32 canvas.
# Needs Emacs 32.0.50, built from source; nothing is compiled here.

EMACS ?= emacs

.PHONY: test battery clean

# The checks that need no canvas.
test:
	$(EMACS) -Q --batch -L . -L tests \
	  -l tests/guards.el -l tests/headers.el \
	  --eval '(ert-run-tests-batch-and-exit)'

# The rest draws in a real window, so it cannot run in batch.  The flags
# keep the frame iconified and dark; drop them to watch it.  The exit
# status is how many checks failed.
battery:
	$(EMACS) -Q -rv --iconic -l tests/battery.el

clean:
	rm -f *.elc tests/*.elc
