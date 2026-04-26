/*
 * tty_nif.c — clear/restore IEXTEN on stdin.
 *
 * OTP 28's prim_tty raw mode clears ICANON but leaves IEXTEN set.
 * With IEXTEN enabled the kernel driver intercepts ctrl+o (VDISCARD)
 * before the byte reaches read(), so the application never sees it.
 * cfmakeraw() clears IEXTEN; we replicate just that part here.
 */

#include <erl_nif.h>
#include <termios.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;
    atom_ok    = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    return 0;
}

static ERL_NIF_TERM make_error(ErlNifEnv *env) {
    return enif_make_tuple2(env, atom_error,
                            enif_make_string(env, strerror(errno), ERL_NIF_LATIN1));
}

static ERL_NIF_TERM clear_iexten(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    struct termios t;
    if (tcgetattr(STDIN_FILENO, &t) != 0) return make_error(env);
    t.c_lflag &= ~(tcflag_t)IEXTEN;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) != 0) return make_error(env);
    return atom_ok;
}

static ERL_NIF_TERM restore_iexten(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    struct termios t;
    if (tcgetattr(STDIN_FILENO, &t) != 0) return make_error(env);
    t.c_lflag |= IEXTEN;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &t) != 0) return make_error(env);
    return atom_ok;
}

static ErlNifFunc nif_funcs[] = {
    {"clear_iexten",   0, clear_iexten,   0},
    {"restore_iexten", 0, restore_iexten, 0}
};

ERL_NIF_INIT(Elixir.OctoPi.TUI.TtyNif, nif_funcs, load, NULL, NULL, NULL)
