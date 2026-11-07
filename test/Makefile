# Run every unit test: each folder here with a Makefile and a "test" target.
TESTS := $(patsubst %/Makefile,%,$(wildcard */Makefile))

.PHONY: all $(TESTS)
all: $(TESTS)
	@echo "all unit tests passed: $(TESTS)"

$(TESTS):
	$(MAKE) -C $@ test
