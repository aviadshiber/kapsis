# Kapsis top-level Makefile
#
# Currently covers kapsis-ctl (Phase 1, issue #266).
# The K8s operator has its own Makefile under operator/.

KAPSIS_VERSION ?= dev
GOFLAGS := -trimpath -ldflags="-s -w -X main.version=$(KAPSIS_VERSION)"
CTL_SRC  := ./cmd/kapsis-ctl
CTL_BIN  := ./bin/kapsis-ctl

.PHONY: build-ctl test-ctl vet-ctl clean-ctl all-ctl

## Build the kapsis-ctl binary into bin/
build-ctl:
	@mkdir -p bin
	cd $(CTL_SRC) && go build $(GOFLAGS) -o ../../$(CTL_BIN) .

## Run kapsis-ctl unit tests
test-ctl:
	cd $(CTL_SRC) && go test ./...

## Run go vet on kapsis-ctl
vet-ctl:
	cd $(CTL_SRC) && go vet ./...

## Remove built binary
clean-ctl:
	rm -f $(CTL_BIN)

## Build, vet, and test kapsis-ctl
all-ctl: vet-ctl test-ctl build-ctl
