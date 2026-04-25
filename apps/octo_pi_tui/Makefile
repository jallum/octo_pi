PRIV_DIR = priv
NIF_SO = $(PRIV_DIR)/tty_nif.so

ERTS_INCLUDE = $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s init stop)

CFLAGS ?= -O2 -Wall -fPIC
LDFLAGS ?= -shared

UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
  LDFLAGS += -undefined dynamic_lookup
endif

all: $(NIF_SO)

$(NIF_SO): c_src/tty_nif.c | $(PRIV_DIR)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE) $(LDFLAGS) -o $@ $<

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

clean:
	rm -f $(NIF_SO)

.PHONY: all clean
