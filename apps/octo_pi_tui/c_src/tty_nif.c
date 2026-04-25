#include <erl_nif.h>
#include <sys/ioctl.h>
#include <unistd.h>

static ERL_NIF_TERM window_size(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  struct winsize ws;
  if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == -1)
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "enotty"));
  return enif_make_tuple2(
      env, enif_make_atom(env, "ok"),
      enif_make_tuple2(env, enif_make_int(env, ws.ws_col),
                       enif_make_int(env, ws.ws_row)));
}

static ErlNifFunc nif_funcs[] = {
    {"window_size", 0, window_size, 0},
};

ERL_NIF_INIT(Elixir.OctoPi.TUI.TTY, nif_funcs, NULL, NULL, NULL, NULL)
