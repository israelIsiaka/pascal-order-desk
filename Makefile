# ---------------------------------------------------------------------
# Makefile for the order desk
#
#   make            compile both programs into bin/
#   make debug      compile with debug information and run-time checks
#   make db         create the tables, procedures and sample data
#   make test       reset the database and run every test
#   make run        start the order desk
#   make clean      delete everything the compiler produced
#
# The database commands read the standard PostgreSQL environment
# variables. The defaults below match docker-compose.yml.
# ---------------------------------------------------------------------

FPC      ?= fpc
SRC      := src
BIN      := bin
OBJ      := build

export PGHOST     ?= 127.0.0.1
export PGPORT     ?= 5432
export PGDATABASE ?= orderdesk
export PGUSER     ?= orderdesk
export PGPASSWORD ?= orderdesk

PSQL := psql -v ON_ERROR_STOP=1 -q

# Compiler flags
#   -Mobjfpc -Sh   Object Pascal dialect, long strings
#   -FE / -FU      where to put the programs / the compiled units
#   -Fu            where to look for our units
#   -vewn          show errors, warnings and notes
# Release adds:
#   -O2            optimise
#   -Xs            strip symbols from the program
# Debug adds:
#   -g -gl         debug information, and line numbers in crash reports
#   -gw3           DWARF 3 debug format, the one gdb reads best
#   -O-            no optimisation, so stepping follows the source
#   -Cr -Co -Ct    range, overflow and stack checks at run time
#   -Ci            check the result of every file operation
#   -Sa            keep Assert() calls in the program
#   -gh            report memory that was allocated and never freed
COMMON  := -Mobjfpc -Sh -Fu$(SRC) -FE$(BIN) -FU$(OBJ) -vewn
RELEASE := -O2 -Xs
DEBUG   := -g -gl -gw3 -O- -Cr -Co -Ct -Ci -Sa -gh

# macOS: Homebrew keeps libpq outside the default library path, and
# Free Pascal needs to be told where the system SDK is. Both are looked
# up here so the same "make" works on Linux and on a Mac.
ifeq ($(shell uname -s),Darwin)
  PGLIBDIR := $(shell pg_config --libdir 2>/dev/null)
  MACSDK   := $(shell xcrun --show-sdk-path 2>/dev/null)
  COMMON   += $(if $(PGLIBDIR),-Fl$(PGLIBDIR)) $(if $(MACSDK),-XR$(MACSDK))
  RELEASE  := -O2
endif

UNITS := $(wildcard $(SRC)/*.pas)

.PHONY: all debug db test run clean

all: FLAGS := $(COMMON) $(RELEASE)
all: $(BIN)/orderdesk $(BIN)/stress

debug: FLAGS := $(COMMON) $(DEBUG)
debug: clean $(BIN)/orderdesk $(BIN)/stress

$(BIN)/orderdesk: $(UNITS) | $(BIN) $(OBJ)
	$(FPC) $(FLAGS) $(SRC)/orderdesk.pas

$(BIN)/stress: $(UNITS) | $(BIN) $(OBJ)
	$(FPC) $(FLAGS) $(SRC)/stress.pas

$(BIN) $(OBJ):
	mkdir -p $@

db:
	$(PSQL) -f db/01_schema.sql
	$(PSQL) -f db/02_procedures.sql
	$(PSQL) -f db/03_seed.sql

test: all
	sh tests/run_tests.sh

run: all
	$(BIN)/orderdesk

clean:
	rm -rf $(BIN) $(OBJ)
