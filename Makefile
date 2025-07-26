# Synergy Makefile

EXE					:= synergy
WIN32_EMACSCLIENT	:= $(HOME)/Programs/emacs/bin/emacsclient.exe
VERSION				:= $(shell git describe --tags --abbrev=0)
ZIPFILE				:= synergy-$(VERSION).zip

# Define the list of files for distribution
DIST_FILES := $(EXE) inf-synergy.el README.pod README.html Makefile MANIFEST

# The MANIFEST file itself is part of DIST_FILES, but its content is
# derived from other DIST_FILES (excluding itself initially) For
# checksum, we list the core source files that define the
# distribution.  README.html and MANIFEST are generated, so they are
# not checksummed directly from source control.
MANIFEST_SOURCES := inf-synergy.el Makefile README.pod README.html $(EXE)

all: test install

readme: podcheck
	@podselect $(EXE) > README.pod

readme-html: readme
	@pod2html README.pod > README.html

install:
	@mkdir -p $$HOME/bin && \
	cp $(EXE) $$HOME/bin/$(EXE) && \
	chmod 755 $$HOME/bin/$(EXE) && \
	emacsclient -q --no-wait --eval '(load-file "inf-synergy.el")'

lint:
	@perl -wc $(EXE)

critique:
	@perlcritic $(EXE)

podcheck:
	@podchecker $(EXE)

bat:
	@pl2bat $(EXE)

# On Windows, try `(setq server-use-tcp t)`
winstall: bat
	cp $(EXE).bat $(HOME)/bin/ && \
	$(WIN32_EMACSCLIENT) --eval "(load-file \"inf-synergy.el\")"

manifest: checksum

checksum: clean readme-html
	@shasum $(MANIFEST_SOURCES) > MANIFEST

clean:
	@rm -f *{~,.elc,.bat,.html,.zip,.tmp} MANIFEST README.pod README.html || true

test:
	prove

dist: tarball

tarball: clean sanitize-script readme-html manifest
	@zip -q $(ZIPFILE) $(DIST_FILES)

sanitize-script:
	@awk 'BEGIN {in_prompt=0; found_history=0} \
	/\$$system_prompt = <<\"EOPROMPT\";/ {print; print "# AI Persona and instructions removed for distribution"; print "# Add your own system prompt; be sure to keep the \\@convo and \\@context blocks!"; in_prompt=1; next} \
	in_prompt && /^Here is the history of the conversation to this point:/ {found_history=1; print; next} \
	in_prompt && !found_history {next} \
	/^EOPROMPT$$/ {in_prompt=0; found_history=0; print; next} \
	!in_prompt || found_history {print}' $(EXE) > $(EXE).tmp
	@mv $(EXE).tmp $(EXE)

# eof
