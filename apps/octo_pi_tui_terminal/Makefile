PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO   = $(PRIV_DIR)/tty_nif.so

CFLAGS = -O2 -Wall -Wextra -fPIC -I$(ERTS_INCLUDE_DIR)

ifeq ($(shell uname -s),Darwin)
  LDFLAGS = -dynamiclib -undefined dynamic_lookup
else
  LDFLAGS = -shared
endif

.PHONY: all clean

all:
	@mkdir -p $(PRIV_DIR)
	@if [ ! -f $(NIF_SO) ]; then $(CC) $(CFLAGS) $(LDFLAGS) -o $(NIF_SO) c_src/tty_nif.c; fi

clean:
	@rm -f $(NIF_SO)
