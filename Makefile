# GNU Makefile for the aws-cloud-ops toolkit
# Usage: make [target] [variable=value] ...  -- help for all targets: make help

SHELL      := /bin/bash -o pipefail
PYTHON     ?= .venv/bin/python
PYTEST     := $(PYTHON) -m unittest
TERRAFORM  ?= $(shell command -v terraform || command -v tofu)
SHELLCHECK ?= $(shell command -v shellcheck)
PREFIX     ?= $(HOME)/.local
DESTDIR    ?= $(PREFIX)

export TF_IN_PLUGIN_DIRS += $(HOME)/.terraform.d/plugins
export TF_PLUGIN_CACHE_DIR

.PHONY: all help venv install test lint fmt fmt-check tf-fmt tf-validate tf-test scan report \
        patch-scan preflight snapshot hooks clean dist docs man ci

all: lint test

help:  # print this help message and exit successfully
	@echo "usage: make [TARGET]"
	@echo "targets:"
	@sed -n -e '/^[a-zA-Z_-]+:.*# /s/^\([a-zA-Z_-]*\):.*# \(.*\)/  \1	\2/p' $(MAKEFILE) | sort -u

venv:  # create a virtual environment (the standard environment)
	$(if $(shell command -v uv), \
	  uv venv --python 3.11 .venv, \
	  python3 -m venv .venv)

install: venv  # install the package (editable) and its dependencies
	$(if $(shell command -v uv), \
	  uv pip install --python $(abspath $(PYTHON)) -e '.[live]', \
	  .venv/bin/python -m pip install -e '.[live]')

test:  # run the test suite (stdlib-only; no network, no AWS credentials needed)
	$(PYTEST) discover -s tests -p 'test_*.py' -v

lint: lint-shell lint-python  # run all linters that are installed
lint-shell:
	$(if $(SHELLCHECK), find scripts hooks -type f -name '*.sh' -exec $(SHELLCHECK) -x {} +, \
	  echo "shellcheck not installed; skipping" )
lint-python:
	$(if $(shell command -v ruff), ruff check cloudops tests, $(PYTHON) -m compileall cloudops)

fmt: fmt-python tf-fmt  # format the sources
fmt-python:
	$(if $(shell command -v ruff), ruff format cloudops tests, echo "ruff not installed; skipping")
tf-fmt:
	$(if $(TERRAFORM), $(TERRAFORM) fmt -recursive -check . || $(TERRAFORM) fmt -recursive ., \
	  echo "terraform not installed; skipping")

tf-validate:  # validate the Terraform configurations (init first, backend disabled)
	$(if $(TERRAFORM), \
	  for d in infra/envs/*; do \
	    echo "== $$d"; $(TERRAFORM) -chdir="$$d" init -backend=false -input=false -upgrade; \
	    $(TERRAFORM) -chdir="$$d" validate; \
	  done, echo "terraform not installed; skipping")

scan:  # scan the reference fleet inventory and print the patch queue
	$(PYTHON) -m cloudops.cli scan --inventory tests/fixtures/fleet-inventory.json \
	  --eol-catalog data/eol-catalog.json --format table

report:  # write reports about the fleet status to reports/
	mkdir -p reports
	$(PYTHON) -m cloudops.cli scan --inventory tests/fixtures/fleet-inventory.json \
	  --eol-catalog data/eol-catalog.json --format csv > reports/fleet-status.csv

patch-scan:  # scan compliance of the fleet against the registered patch baselines
	bash scripts/patch-compliance-scan.sh --inventory tests/fixtures/fleet-inventory.json \
	  --dry-run

clean:  # remove all generated files and the virtual environment
	rm -rf .venv build dist *.egg-info __pycache__ .pytest_cache reports
	find . -name __pycache__ -type d -exec rm -rf '{}' +
	find . -name '*.pyc' -type f -delete

ci: lint test tf-validate  # what the continuous integration pipeline runs (see .github/workflows)
