/*
 * fcitx-indicator.c — Native C replacement for `default/input-methods/indicator.py`.
 * Speaks the exact JSON line protocol expected by `shell/Commons/InputMethodState.qml`
 * while eliminating the persistent 24 MiB Python + PyGObject interpreter.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <glib.h>
#include <json-glib/json-glib.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define FCITX_BUS "org.fcitx.Fcitx5"
#define FCITX_PATH "/controller"
#define FCITX_IFACE "org.fcitx.Fcitx.Controller1"

typedef struct {
    char *id;
    char *name;
    char *label;
    char *language;
} ImEntry;

typedef struct {
    GPtrArray *methods; /* char* */
    char *current;
    char *name;
    char *label;
    gboolean has_label;
    char *language;
} ImState;

typedef struct {
    char *name;
    char *layout;
    int active_layout_index;
} HyprKeyboard;

typedef struct {
    GDBusConnection *bus;
    GMainLoop *loop;
    char *pending;
    char *last;
    char *previous_json;
    GHashTable *entries; /* id -> ImEntry* */
    GPtrArray *monitors; /* GFileMonitor* */
    GString *stdin_buf;
    guint timer_id;
    guint settle_id;
    guint watch_id;
    gboolean polling;
    gboolean failed;
    gboolean present;
} AppCtx;

static void im_entry_free(gpointer p) {
    ImEntry *e = (ImEntry *)p;
    if (!e) return;
    g_free(e->id);
    g_free(e->name);
    g_free(e->label);
    g_free(e->language);
    g_free(e);
}

static ImState *im_state_new(void) {
    ImState *s = g_new0(ImState, 1);
    s->methods = g_ptr_array_new_with_free_func(g_free);
    s->current = g_strdup("");
    s->name = g_strdup("");
    s->label = g_strdup("");
    s->has_label = FALSE;
    s->language = g_strdup("");
    return s;
}

static void im_state_free(ImState *s) {
    if (!s) return;
    if (s->methods) g_ptr_array_unref(s->methods);
    g_free(s->current);
    g_free(s->name);
    g_free(s->label);
    g_free(s->language);
    g_free(s);
}

static void hypr_kb_free(gpointer p) {
    HyprKeyboard *k = (HyprKeyboard *)p;
    if (!k) return;
    g_free(k->name);
    g_free(k->layout);
    g_free(k);
}

static gboolean ptr_array_contains_str(GPtrArray *arr, const char *needle) {
    if (!arr || !needle) return FALSE;
    for (guint i = 0; i < arr->len; ++i) {
        const char *s = g_ptr_array_index(arr, i);
        if (s && strcmp(s, needle) == 0) return TRUE;
    }
    return FALSE;
}

static int ptr_array_index_str(GPtrArray *arr, const char *needle) {
    if (!arr || !needle) return -1;
    for (guint i = 0; i < arr->len; ++i) {
        const char *s = g_ptr_array_index(arr, i);
        if (s && strcmp(s, needle) == 0) return (int)i;
    }
    return -1;
}

static int count_csv_parts(const char *s) {
    if (!s) return 1;
    int count = 1;
    for (const char *p = s; *p; ++p) {
        if (*p == ',') count++;
    }
    return count;
}

static int mod_pos(int a, int m) {
    if (m <= 0) return 0;
    int r = a % m;
    return r < 0 ? r + m : r;
}

static GVariant *fcitx_call(GDBusConnection *bus, const char *method, GVariant *params, GError **err) {
    return g_dbus_connection_call_sync(
        bus, FCITX_BUS, FCITX_PATH, FCITX_IFACE,
        method, params, NULL,
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, NULL, err
    );
}

static ImState *take_snapshot(GDBusConnection *bus, GError **err) {
    GVariant *grp_res = fcitx_call(bus, "CurrentInputMethodGroup", NULL, err);
    if (!grp_res) return NULL;
    const char *group = NULL;
    g_variant_get_child(grp_res, 0, "&s", &group);
    char *group_copy = g_strdup(group ? group : "");
    g_variant_unref(grp_res);

    GVariant *gi_res = fcitx_call(bus, "InputMethodGroupInfo", g_variant_new("(s)", group_copy), err);
    g_free(group_copy);
    if (!gi_res) return NULL;

    GVariant *info_res = fcitx_call(bus, "CurrentInputMethodInfo", NULL, err);
    if (!info_res) {
        g_variant_unref(gi_res);
        return NULL;
    }

    ImState *st = im_state_new();
    GVariant *items = g_variant_get_child_value(gi_res, 1);
    if (items) {
        GVariantIter iter;
        g_variant_iter_init(&iter, items);
        const char *m_id = NULL, *m_layout = NULL;
        while (g_variant_iter_next(&iter, "(&s&s)", &m_id, &m_layout)) {
            if (m_id && !ptr_array_contains_str(st->methods, m_id)) {
                g_ptr_array_add(st->methods, g_strdup(m_id));
            }
        }
        g_variant_unref(items);
    }
    g_variant_unref(gi_res);

    if (g_variant_n_children(info_res) >= 6) {
        const char *c0 = NULL, *c1 = NULL, *c4 = NULL, *c5 = NULL;
        g_variant_get_child(info_res, 0, "&s", &c0);
        g_variant_get_child(info_res, 1, "&s", &c1);
        g_variant_get_child(info_res, 4, "&s", &c4);
        g_variant_get_child(info_res, 5, "&s", &c5);
        g_free(st->current); st->current = g_strdup(c0 ? c0 : "");
        g_free(st->name);    st->name    = g_strdup(c1 ? c1 : "");
        g_free(st->label);   st->label   = g_strdup(c4 ? c4 : "");
        st->has_label = TRUE;
        g_free(st->language); st->language = g_strdup(c5 ? c5 : "");
    }
    g_variant_unref(info_res);
    return st;
}

static void populate_available_entries(AppCtx *ctx, GError **err) {
    GVariant *res = fcitx_call(ctx->bus, "AvailableInputMethods", NULL, err);
    if (!res) return;
    g_hash_table_remove_all(ctx->entries);
    GVariant *arr = g_variant_get_child_value(res, 0);
    if (arr) {
        gsize n = g_variant_n_children(arr);
        for (gsize i = 0; i < n; ++i) {
            GVariant *tup = g_variant_get_child_value(arr, i);
            if (tup && g_variant_n_children(tup) >= 6) {
                const char *e0 = NULL, *e1 = NULL, *e4 = NULL, *e5 = NULL;
                g_variant_get_child(tup, 0, "&s", &e0);
                g_variant_get_child(tup, 1, "&s", &e1);
                g_variant_get_child(tup, 4, "&s", &e4);
                g_variant_get_child(tup, 5, "&s", &e5);
                if (e0 && *e0) {
                    ImEntry *ent = g_new0(ImEntry, 1);
                    ent->id = g_strdup(e0);
                    ent->name = g_strdup(e1 ? e1 : "");
                    ent->label = g_strdup(e4 ? e4 : "");
                    ent->language = g_strdup(e5 ? e5 : "");
                    g_hash_table_replace(ctx->entries, g_strdup(e0), ent);
                }
            }
            if (tup) g_variant_unref(tup);
        }
        g_variant_unref(arr);
    }
    g_variant_unref(res);
}

static gboolean is_switchable(AppCtx *ctx, GPtrArray *methods, GError **err) {
    if (methods->len > 1) return TRUE;
    for (guint i = 0; i < methods->len; ++i) {
        const char *m = g_ptr_array_index(methods, i);
        if (!g_str_has_prefix(m, "keyboard-")) return TRUE;
    }
    GVariant *res = fcitx_call(ctx->bus, "InputMethodGroups", NULL, err);
    if (!res) return FALSE;
    GVariant *arr = g_variant_get_child_value(res, 0);
    gsize ngroups = arr ? g_variant_n_children(arr) : 0;
    if (arr) g_variant_unref(arr);
    g_variant_unref(res);
    return ngroups > 1;
}

static ImState *indicator_refresh(AppCtx *ctx, GError **err) {
    ImState *state = take_snapshot(ctx->bus, err);
    if (!state) return NULL;

    if (ctx->pending[0] && !ptr_array_contains_str(state->methods, ctx->pending)) {
        g_free(ctx->pending);
        ctx->pending = g_strdup("");
    }

    if (ctx->pending[0] && state->current[0]) {
        GError *set_err = NULL;
        GVariant *set_res = fcitx_call(ctx->bus, "SetCurrentIM", g_variant_new("(s)", ctx->pending), &set_err);
        if (!set_res) {
            g_propagate_error(err, set_err);
            im_state_free(state);
            return NULL;
        }
        g_variant_unref(set_res);
        im_state_free(state);
        state = take_snapshot(ctx->bus, err);
        if (!state) return NULL;
        if (strcmp(state->current, ctx->pending) == 0) {
            g_free(ctx->pending);
            ctx->pending = g_strdup("");
        }
    }

    if (state->current[0]) {
        g_free(ctx->last);
        ctx->last = g_strdup(state->current);
    } else {
        const char *chosen = "";
        if (ctx->pending[0]) chosen = ctx->pending;
        else if (ctx->last[0] && ptr_array_contains_str(state->methods, ctx->last)) chosen = ctx->last;
        else if (state->methods->len > 0) chosen = g_ptr_array_index(state->methods, 0);

        if (chosen[0] && !g_hash_table_contains(ctx->entries, chosen)) {
            GError *av_err = NULL;
            populate_available_entries(ctx, &av_err);
            if (av_err) {
                g_propagate_error(err, av_err);
                im_state_free(state);
                return NULL;
            }
        }
        ImEntry *ent = chosen[0] ? g_hash_table_lookup(ctx->entries, chosen) : NULL;
        if (ent) {
            g_free(state->current);  state->current  = g_strdup(ent->id);
            g_free(state->name);     state->name     = g_strdup(ent->name);
            g_free(state->label);    state->label    = g_strdup(ent->label);
            state->has_label = TRUE;
            g_free(state->language); state->language = g_strdup(ent->language);
        }
    }
    return state;
}

static char *serialize_state(const ImState *st) {
    JsonBuilder *b = json_builder_new();
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "methods");
    json_builder_begin_array(b);
    for (guint i = 0; i < st->methods->len; ++i) {
        json_builder_add_string_value(b, g_ptr_array_index(st->methods, i));
    }
    json_builder_end_array(b);
    json_builder_set_member_name(b, "current");
    json_builder_add_string_value(b, st->current ? st->current : "");
    json_builder_set_member_name(b, "name");
    json_builder_add_string_value(b, st->name ? st->name : "");
    if (st->has_label) {
        json_builder_set_member_name(b, "label");
        json_builder_add_string_value(b, st->label ? st->label : "");
    }
    json_builder_set_member_name(b, "language");
    json_builder_add_string_value(b, st->language ? st->language : "");
    json_builder_end_object(b);

    JsonGenerator *gen = json_generator_new();
    JsonNode *root = json_builder_get_root(b);
    json_generator_set_root(gen, root);
    char *out = json_generator_to_data(gen, NULL);
    json_node_free(root);
    g_object_unref(gen);
    g_object_unref(b);
    return out;
}

static char *hypr_socket_request(const char *cmd) {
    const char *rt = getenv("XDG_RUNTIME_DIR");
    const char *sig = getenv("HYPRLAND_INSTANCE_SIGNATURE");
    char rt_buf[64];
    if (!rt || !*rt) {
        snprintf(rt_buf, sizeof(rt_buf), "/run/user/%u", (unsigned)getuid());
        rt = rt_buf;
    }
    char sock_path[256] = "";
    if (sig && *sig) {
        snprintf(sock_path, sizeof(sock_path), "%s/hypr/%s/.socket.sock", rt, sig);
    } else {
        char hypr_dir[192];
        snprintf(hypr_dir, sizeof(hypr_dir), "%s/hypr", rt);
        DIR *d = opendir(hypr_dir);
        if (d) {
            struct dirent *de;
            while ((de = readdir(d)) != NULL) {
                if (de->d_name[0] == '.') continue;
                char cand[256];
                snprintf(cand, sizeof(cand), "%s/%s/.socket.sock", hypr_dir, de->d_name);
                if (access(cand, F_OK) == 0) {
                    snprintf(sock_path, sizeof(sock_path), "%s", cand);
                    break;
                }
            }
            closedir(d);
        }
    }
    if (!sock_path[0]) return NULL;

    struct sockaddr_un addr;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) return NULL;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return NULL;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sock_path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NULL;
    }
    size_t clen = strlen(cmd);
    if (send(fd, cmd, clen, MSG_NOSIGNAL) < 0) {
        close(fd);
        return NULL;
    }
    GString *resp = g_string_sized_new(4096);
    char buf[4096];
    ssize_t n;
    while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) {
        g_string_append_len(resp, buf, n);
    }
    close(fd);
    return g_string_free(resp, FALSE);
}

static GPtrArray *query_hypr_keyboards(void) {
    char *raw = hypr_socket_request("j/devices");
    if (!raw) return NULL;
    JsonParser *parser = json_parser_new();
    if (!json_parser_load_from_data(parser, raw, -1, NULL)) {
        g_object_unref(parser);
        g_free(raw);
        return NULL;
    }
    g_free(raw);
    GPtrArray *kbs = g_ptr_array_new_with_free_func(hypr_kb_free);
    JsonNode *root = json_parser_get_root(parser);
    if (root && JSON_NODE_HOLDS_OBJECT(root)) {
        JsonObject *obj = json_node_get_object(root);
        if (json_object_has_member(obj, "keyboards")) {
            JsonArray *arr = json_object_get_array_member(obj, "keyboards");
            guint len = arr ? json_array_get_length(arr) : 0;
            for (guint i = 0; i < len; ++i) {
                JsonObject *ko = json_array_get_object_element(arr, i);
                if (!ko) continue;
                HyprKeyboard *kb = g_new0(HyprKeyboard, 1);
                kb->name = g_strdup(json_object_get_string_member_with_default(ko, "name", ""));
                kb->layout = g_strdup(json_object_get_string_member_with_default(ko, "layout", ""));
                kb->active_layout_index = (int)json_object_get_int_member_with_default(ko, "active_layout_index", 0);
                g_ptr_array_add(kbs, kb);
            }
        }
    }
    g_object_unref(parser);
    return kbs;
}

static gboolean is_ignored_kb_name(const char *name) {
    return g_str_has_prefix(name, "hl-virtual-keyboard") ||
           g_str_has_prefix(name, "power-button") ||
           g_str_has_prefix(name, "sleep-button") ||
           g_str_has_prefix(name, "lid-switch") ||
           g_str_has_prefix(name, "video-bus");
}

static HyprKeyboard *find_layout_keyboard(GPtrArray *kbs) {
    if (!kbs) return NULL;
    const char *best_layout = NULL;
    int best_count = -1;
    for (guint i = 0; i < kbs->len; ++i) {
        HyprKeyboard *kb = g_ptr_array_index(kbs, i);
        if (is_ignored_kb_name(kb->name) || count_csv_parts(kb->layout) <= 1) continue;
        int cnt = 0;
        for (guint j = 0; j < kbs->len; ++j) {
            HyprKeyboard *other = g_ptr_array_index(kbs, j);
            if (strcmp(other->layout, kb->layout) == 0) cnt++;
        }
        if (cnt > best_count) {
            best_count = cnt;
            best_layout = kb->layout;
        }
    }
    if (!best_layout) return NULL;
    HyprKeyboard *chosen = NULL;
    for (guint i = 0; i < kbs->len; ++i) {
        HyprKeyboard *kb = g_ptr_array_index(kbs, i);
        if (is_ignored_kb_name(kb->name) || count_csv_parts(kb->layout) <= 1) continue;
        if (strcmp(kb->layout, best_layout) == 0) {
            if (!chosen || kb->active_layout_index > chosen->active_layout_index) {
                chosen = kb;
            }
        }
    }
    return chosen;
}

static void dispatch_layout_switches(GPtrArray *kbs, int explicit_index, int step) {
    HyprKeyboard *kb = find_layout_keyboard(kbs);
    if (!kb) return;
    int nlayouts = count_csv_parts(kb->layout);
    int following = explicit_index >= 0 ? explicit_index : mod_pos(kb->active_layout_index + step, nlayouts);
    for (guint i = 0; i < kbs->len; ++i) {
        HyprKeyboard *item = g_ptr_array_index(kbs, i);
        if (item->name[0] && strcmp(item->layout, kb->layout) == 0) {
            char cmd[384];
            snprintf(cmd, sizeof(cmd), "/switchxkblayout %s %d", item->name, following);
            char *r = hypr_socket_request(cmd);
            g_free(r);
        }
    }
}

static void select_next(AppCtx *ctx, int step) {
    GPtrArray *kbs = query_hypr_keyboards();
    if (!kbs) return;

    GError *err = NULL;
    ImState *state = take_snapshot(ctx->bus, &err);
    if (!state) {
        g_clear_error(&err);
        dispatch_layout_switches(kbs, -1, step);
        g_ptr_array_unref(kbs);
        return;
    }

    const char *cur_cand = ctx->pending[0] ? ctx->pending : (state->current[0] ? state->current : ctx->last);
    char *cur = NULL;
    if (cur_cand[0] && ptr_array_contains_str(state->methods, cur_cand)) {
        cur = g_strdup(cur_cand);
    } else if (state->methods->len > 0) {
        cur = g_strdup(g_ptr_array_index(state->methods, 0));
    } else {
        cur = g_strdup("");
    }
    g_free(state->current);
    state->current = cur;

    HyprKeyboard *kb = find_layout_keyboard(kbs);
    const char *primary = NULL;
    for (guint i = 0; i < state->methods->len; ++i) {
        const char *m = g_ptr_array_index(state->methods, i);
        if (g_str_has_prefix(m, "keyboard-")) { primary = m; break; }
    }

    char *following = NULL;
    int target_index = -1;

    if (!kb || !primary) {
        int idx = ptr_array_index_str(state->methods, state->current);
        if (state->methods->len > 1 && idx >= 0) {
            int next_i = mod_pos(idx + step, (int)state->methods->len);
            following = g_strdup(g_ptr_array_index(state->methods, next_i));
        }
    } else {
        int nlayouts = count_csv_parts(kb->layout);
        typedef struct { const char *method; int index; } Choice;
        GArray *choices = g_array_new(FALSE, FALSE, sizeof(Choice));
        for (guint i = 0; i < state->methods->len; ++i) {
            const char *m = g_ptr_array_index(state->methods, i);
            if (strcmp(m, primary) == 0) {
                for (int li = 0; li < nlayouts; ++li) {
                    Choice c = { m, li };
                    g_array_append_val(choices, c);
                }
            } else {
                Choice c = { m, -1 };
                g_array_append_val(choices, c);
            }
        }
        const char *eff_cur = state->current[0] ? state->current : primary;
        int eff_idx = strcmp(eff_cur, primary) == 0 ? kb->active_layout_index : -1;
        int pos = -1;
        for (guint i = 0; i < choices->len; ++i) {
            Choice c = g_array_index(choices, Choice, i);
            if (strcmp(c.method, eff_cur) == 0 && c.index == eff_idx) {
                pos = (int)i;
                break;
            }
        }
        if (pos >= 0 && choices->len > 0) {
            Choice next_c = g_array_index(choices, Choice, mod_pos(pos + step, (int)choices->len));
            following = g_strdup(next_c.method);
            target_index = next_c.index;
        }
        g_array_unref(choices);
    }

    if (following) {
        g_free(ctx->pending);
        ctx->pending = following;
        if (target_index >= 0) {
            dispatch_layout_switches(kbs, target_index, step);
        }
    }

    im_state_free(state);
    g_ptr_array_unref(kbs);
}

static void do_refresh(AppCtx *ctx) {
    GError *err = NULL;
    ImState *state = indicator_refresh(ctx, &err);
    if (!state) {
        g_clear_error(&err);
        ctx->failed = TRUE;
        g_free(ctx->pending); ctx->pending = g_strdup("");
        g_free(ctx->last);    ctx->last    = g_strdup("");
        state = im_state_new();
    } else {
        GError *sw_err = NULL;
        gboolean sw = is_switchable(ctx, state->methods, &sw_err);
        if (sw_err) {
            g_clear_error(&sw_err);
            ctx->failed = TRUE;
        } else {
            ctx->polling = sw;
            ctx->failed = FALSE;
        }
    }

    char *line = serialize_state(state);
    im_state_free(state);
    if (!ctx->previous_json || strcmp(line, ctx->previous_json) != 0) {
        if (fputs(line, stdout) == EOF || fputc('\n', stdout) == EOF || fflush(stdout) == EOF) {
            g_free(line);
            g_main_loop_quit(ctx->loop);
            return;
        }
        g_free(ctx->previous_json);
        ctx->previous_json = line;
    } else {
        g_free(line);
    }
}

static gboolean on_poll_timeout(gpointer user_data);

static void schedule_next(AppCtx *ctx) {
    if (ctx->timer_id) {
        g_source_remove(ctx->timer_id);
        ctx->timer_id = 0;
    }
    if (ctx->pending[0]) {
        ctx->timer_id = g_timeout_add(50, on_poll_timeout, ctx);
    } else if (ctx->polling) {
        ctx->timer_id = g_timeout_add(500, on_poll_timeout, ctx);
    } else if (ctx->failed && ctx->present) {
        ctx->timer_id = g_timeout_add(2000, on_poll_timeout, ctx);
    }
}

static gboolean on_poll_timeout(gpointer user_data) {
    AppCtx *ctx = (AppCtx *)user_data;
    ctx->timer_id = 0;
    do_refresh(ctx);
    schedule_next(ctx);
    return G_SOURCE_REMOVE;
}

static gboolean on_settled_timeout(gpointer user_data) {
    AppCtx *ctx = (AppCtx *)user_data;
    ctx->settle_id = 0;
    do_refresh(ctx);
    schedule_next(ctx);
    return G_SOURCE_REMOVE;
}

static void trigger_changed(AppCtx *ctx) {
    if (ctx->settle_id) {
        g_source_remove(ctx->settle_id);
    }
    ctx->settle_id = g_timeout_add(200, on_settled_timeout, ctx);
}

static void on_profile_changed(GFileMonitor *m, GFile *f, GFile *of, GFileMonitorEvent ev, gpointer user_data) {
    (void)m; (void)f; (void)of; (void)ev;
    trigger_changed((AppCtx *)user_data);
}

static char *resolve_fcitx_profile_path(GDBusConnection *bus, gboolean query_owner) {
    char *home = NULL, *xdg = NULL, *fcitx_cfg = NULL, *cwd = NULL;
    if (query_owner) {
        GVariant *res = g_dbus_connection_call_sync(
            bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "GetConnectionUnixProcessID", g_variant_new("(s)", FCITX_BUS),
            G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, NULL, NULL
        );
        if (res) {
            guint32 pid = 0;
            g_variant_get(res, "(u)", &pid);
            g_variant_unref(res);
            if (pid > 0) {
                char env_path[64], cwd_path[64], link_buf[PATH_MAX];
                snprintf(env_path, sizeof(env_path), "/proc/%u/environ", pid);
                snprintf(cwd_path, sizeof(cwd_path), "/proc/%u/cwd", pid);
                gchar *raw = NULL;
                gsize rlen = 0;
                if (g_file_get_contents(env_path, &raw, &rlen, NULL) && raw) {
                    gsize i = 0;
                    while (i < rlen) {
                        const char *entry = raw + i;
                        gsize elen = strnlen(entry, rlen - i);
                        if (g_str_has_prefix(entry, "HOME=")) { g_free(home); home = g_strdup(entry + 5); }
                        else if (g_str_has_prefix(entry, "XDG_CONFIG_HOME=")) { g_free(xdg); xdg = g_strdup(entry + 16); }
                        else if (g_str_has_prefix(entry, "FCITX_CONFIG_HOME=")) { g_free(fcitx_cfg); fcitx_cfg = g_strdup(entry + 18); }
                        i += elen + 1;
                    }
                    g_free(raw);
                }
                ssize_t cl = readlink(cwd_path, link_buf, sizeof(link_buf) - 1);
                if (cl > 0) {
                    link_buf[cl] = '\0';
                    cwd = g_strdup(link_buf);
                }
            }
        }
    }
    if (!home || !*home) { g_free(home); home = g_strdup(g_get_home_dir()); }
    if (!cwd || !*cwd)   { g_free(cwd);  cwd  = g_get_current_dir(); }

    char *dir = NULL;
    if (fcitx_cfg && *fcitx_cfg) {
        dir = g_path_is_absolute(fcitx_cfg) ? g_strdup(fcitx_cfg) : g_build_filename(cwd, fcitx_cfg, NULL);
    } else if (xdg && *xdg) {
        dir = g_path_is_absolute(xdg) ? g_build_filename(xdg, "fcitx5", NULL) : g_build_filename(home, xdg, "fcitx5", NULL);
    } else {
        dir = g_build_filename(home, ".config", "fcitx5", NULL);
    }
    char *profile = g_build_filename(dir, "profile", NULL);
    g_free(dir);
    g_free(home);
    g_free(xdg);
    g_free(fcitx_cfg);
    g_free(cwd);
    return profile;
}

static void bind_profile_monitors(AppCtx *ctx, gboolean query_owner) {
    for (guint i = 0; i < ctx->monitors->len; ++i) {
        GFileMonitor *m = g_ptr_array_index(ctx->monitors, i);
        g_file_monitor_cancel(m);
    }
    g_ptr_array_set_size(ctx->monitors, 0);

    char *path = resolve_fcitx_profile_path(ctx->bus, query_owner);
    char real_buf[PATH_MAX];
    const char *real = realpath(path, real_buf);

    const char *paths[2] = { path, (real && strcmp(real, path) != 0) ? real : NULL };
    for (int i = 0; i < 2; ++i) {
        if (!paths[i]) continue;
        GFile *gf = g_file_new_for_path(paths[i]);
        GFileMonitor *mon = g_file_monitor_file(gf, G_FILE_MONITOR_WATCH_MOVES, NULL, NULL);
        g_object_unref(gf);
        if (mon) {
            g_signal_connect(mon, "changed", G_CALLBACK(on_profile_changed), ctx);
            g_ptr_array_add(ctx->monitors, mon);
        }
    }
    g_free(path);
}

static void on_name_appeared(GDBusConnection *c, const gchar *name, const gchar *owner, gpointer user_data) {
    (void)c; (void)name; (void)owner;
    AppCtx *ctx = (AppCtx *)user_data;
    ctx->present = TRUE;
    bind_profile_monitors(ctx, TRUE);
    trigger_changed(ctx);
}

static void on_name_vanished(GDBusConnection *c, const gchar *name, gpointer user_data) {
    (void)c; (void)name;
    AppCtx *ctx = (AppCtx *)user_data;
    ctx->present = FALSE;
    trigger_changed(ctx);
}

static gboolean on_stdin_ready(gint fd, GIOCondition cond, gpointer user_data) {
    AppCtx *ctx = (AppCtx *)user_data;
    if (cond & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)) {
        char tmp[64];
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n <= 0) {
            g_main_loop_quit(ctx->loop);
            return G_SOURCE_REMOVE;
        }
        g_string_append_len(ctx->stdin_buf, tmp, n);
    } else if (cond & G_IO_IN) {
        char buf[1024];
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) {
            g_main_loop_quit(ctx->loop);
            return G_SOURCE_REMOVE;
        }
        g_string_append_len(ctx->stdin_buf, buf, n);
    }

    char *nl;
    while ((nl = memchr(ctx->stdin_buf->str, '\n', ctx->stdin_buf->len)) != NULL) {
        size_t line_len = (size_t)(nl - ctx->stdin_buf->str);
        char *line = g_strndup(ctx->stdin_buf->str, line_len);
        g_string_erase(ctx->stdin_buf, 0, (gssize)(line_len + 1));
        if (strcmp(line, "cycle") == 0 || strcmp(line, "cycle back") == 0) {
            select_next(ctx, strcmp(line, "cycle back") == 0 ? -1 : 1);
            do_refresh(ctx);
        }
        g_free(line);
    }
    schedule_next(ctx);
    return G_SOURCE_CONTINUE;
}

static gboolean on_term_signal(gpointer user_data) {
    AppCtx *ctx = (AppCtx *)user_data;
    g_main_loop_quit(ctx->loop);
    return G_SOURCE_REMOVE;
}

int main(void) {
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (getppid() == 1) return 0;
    signal(SIGPIPE, SIG_IGN);

    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        if (err) {
            fprintf(stderr, "%s\n", err->message);
            g_error_free(err);
        }
        return 1;
    }

    AppCtx ctx = { 0 };
    ctx.bus = bus;
    ctx.loop = g_main_loop_new(NULL, FALSE);
    ctx.pending = g_strdup("");
    ctx.last = g_strdup("");
    ctx.entries = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, im_entry_free);
    ctx.monitors = g_ptr_array_new_with_free_func(g_object_unref);
    ctx.stdin_buf = g_string_sized_new(256);
    ctx.present = TRUE;

    g_unix_signal_add(SIGTERM, on_term_signal, &ctx);
    g_unix_signal_add(SIGINT, on_term_signal, &ctx);
    g_unix_fd_add(STDIN_FILENO, G_IO_IN | G_IO_HUP | G_IO_ERR, on_stdin_ready, &ctx);

    bind_profile_monitors(&ctx, FALSE);
    ctx.watch_id = g_bus_watch_name_on_connection(
        bus, FCITX_BUS, G_BUS_NAME_WATCHER_FLAGS_NONE,
        on_name_appeared, on_name_vanished, &ctx, NULL
    );

    on_poll_timeout(&ctx);
    g_main_loop_run(ctx.loop);

    if (ctx.timer_id) g_source_remove(ctx.timer_id);
    if (ctx.settle_id) g_source_remove(ctx.settle_id);
    if (ctx.watch_id) g_bus_unwatch_name(ctx.watch_id);
    for (guint i = 0; i < ctx.monitors->len; ++i) {
        g_file_monitor_cancel(g_ptr_array_index(ctx.monitors, i));
    }
    g_ptr_array_unref(ctx.monitors);
    g_hash_table_unref(ctx.entries);
    g_string_free(ctx.stdin_buf, TRUE);
    g_free(ctx.pending);
    g_free(ctx.last);
    g_free(ctx.previous_json);
    g_main_loop_unref(ctx.loop);
    g_object_unref(bus);
    return 0;
}
