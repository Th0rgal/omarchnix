/*
 * touchid-monitor.c — Native C replacement for `touchid-monitor.py` + `gdbus monitor`.
 * Subscribes directly to `net.reactivated.Fprint` on the system D-Bus via GIO
 * (0 Python interpreters, 0 `gdbus` child processes, 0 `hyprctl` forks).
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <glib.h>
#include <json-glib/json-glib.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct {
    int pid;
    int ppid;
    int ruid;
    char *comm;
    GPtrArray *argv; /* char* */
} ProcInfo;

typedef struct {
    gboolean suppressed;
    char *caller_app;
    char *caller_subtitle;
    int cancel_pid;
} CallerInfo;

typedef struct {
    GDBusConnection *bus;
    GMainLoop *loop;
    guint sub_id;
    gboolean session_active;
    gboolean session_suppressed;
} MonitorCtx;

static void proc_info_free(gpointer p) {
    ProcInfo *pi = (ProcInfo *)p;
    if (!pi) return;
    g_free(pi->comm);
    if (pi->argv) g_ptr_array_unref(pi->argv);
    g_free(pi);
}

static void caller_info_clear(CallerInfo *ci) {
    g_free(ci->caller_app);
    g_free(ci->caller_subtitle);
    memset(ci, 0, sizeof(*ci));
}

static void emit_json_str(MonitorCtx *ctx, JsonBuilder *b) {
    JsonGenerator *gen = json_generator_new();
    JsonNode *root = json_builder_get_root(b);
    json_generator_set_root(gen, root);
    char *out = json_generator_to_data(gen, NULL);
    json_node_free(root);
    g_object_unref(gen);
    g_object_unref(b);
    if (fputs(out, stdout) == EOF || fputc('\n', stdout) == EOF || fflush(stdout) == EOF) {
        g_free(out);
        g_main_loop_quit(ctx->loop);
        return;
    }
    g_free(out);
}

static void emit_simple_event(MonitorCtx *ctx, const char *ev) {
    JsonBuilder *b = json_builder_new();
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "event");
    json_builder_add_string_value(b, ev);
    json_builder_end_object(b);
    emit_json_str(ctx, b);
}

static void emit_start_event(MonitorCtx *ctx, const char *finger, const CallerInfo *ci) {
    JsonBuilder *b = json_builder_new();
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "event");
    json_builder_add_string_value(b, "start");
    json_builder_set_member_name(b, "finger");
    json_builder_add_string_value(b, finger ? finger : "");
    json_builder_set_member_name(b, "callerApp");
    json_builder_add_string_value(b, ci->caller_app ? ci->caller_app : "");
    json_builder_set_member_name(b, "callerSubtitle");
    json_builder_add_string_value(b, ci->caller_subtitle ? ci->caller_subtitle : "");
    json_builder_set_member_name(b, "cancelPid");
    json_builder_add_int_value(b, ci->cancel_pid);
    json_builder_end_object(b);
    emit_json_str(ctx, b);
}

static void emit_done_event(MonitorCtx *ctx, const char *ev, const char *reason, gboolean done) {
    JsonBuilder *b = json_builder_new();
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "event");
    json_builder_add_string_value(b, ev);
    if (reason) {
        json_builder_set_member_name(b, "reason");
        json_builder_add_string_value(b, reason);
    }
    json_builder_set_member_name(b, "done");
    json_builder_add_boolean_value(b, done);
    json_builder_end_object(b);
    emit_json_str(ctx, b);
}

static gboolean is_suppressed_comm(const char *s) {
    if (!s || !*s) return FALSE;
    return strcmp(s, "hyprlock") == 0 ||
           strcmp(s, "swaylock") == 0 ||
           strcmp(s, "gtklock") == 0 ||
           strcmp(s, "polkit-agent-helper-1") == 0 ||
           strstr(s, "polkit-agent-helper") != NULL;
}

static gboolean is_suppressed_layer_ns(const char *ns) {
    if (!ns) return FALSE;
    return strcmp(ns, "omarchy-polkit") == 0 ||
           strcmp(ns, "omarchy-lock") == 0 ||
           strcmp(ns, "hyprlock") == 0;
}

static char *hypr_socket_query(const char *cmd) {
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
    if (send(fd, cmd, strlen(cmd), MSG_NOSIGNAL) < 0) {
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

static gboolean has_suppressed_layer(void) {
    char *raw = hypr_socket_query("j/layers");
    if (!raw) return FALSE;
    JsonParser *parser = json_parser_new();
    if (!json_parser_load_from_data(parser, raw, -1, NULL)) {
        g_object_unref(parser);
        g_free(raw);
        return FALSE;
    }
    g_free(raw);

    gboolean found = FALSE;
    JsonNode *root = json_parser_get_root(parser);
    if (root && JSON_NODE_HOLDS_OBJECT(root)) {
        JsonObject *mons = json_node_get_object(root);
        GList *mon_keys = json_object_get_members(mons);
        for (GList *mk = mon_keys; mk && !found; mk = mk->next) {
            JsonObject *mon = json_object_get_object_member(mons, (const char *)mk->data);
            if (!mon || !json_object_has_member(mon, "levels")) continue;
            JsonObject *levels = json_object_get_object_member(mon, "levels");
            if (!levels) continue;
            GList *lvl_keys = json_object_get_members(levels);
            for (GList *lk = lvl_keys; lk && !found; lk = lk->next) {
                JsonArray *entries = json_object_get_array_member(levels, (const char *)lk->data);
                guint len = entries ? json_array_get_length(entries) : 0;
                for (guint i = 0; i < len; ++i) {
                    JsonObject *entry = json_array_get_object_element(entries, i);
                    if (!entry) continue;
                    const char *ns = json_object_get_string_member_with_default(entry, "namespace", "");
                    if (is_suppressed_layer_ns(ns)) {
                        found = TRUE;
                        break;
                    }
                }
            }
            g_list_free(lvl_keys);
        }
        g_list_free(mon_keys);
    }
    g_object_unref(parser);
    return found;
}

static GPtrArray *read_proc_cmdline(int pid) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    gchar *raw = NULL;
    gsize len = 0;
    GPtrArray *arr = g_ptr_array_new_with_free_func(g_free);
    if (!g_file_get_contents(path, &raw, &len, NULL) || !raw || len == 0) {
        g_free(raw);
        return arr;
    }
    while (len > 0 && raw[len - 1] == '\0') len--;
    gsize start = 0;
    for (gsize i = 0; i <= len; ++i) {
        if (i == len || raw[i] == '\0') {
            g_ptr_array_add(arr, g_strndup(raw + start, i - start));
            start = i + 1;
        }
    }
    g_free(raw);
    return arr;
}

static void read_proc_status(int pid, int *ppid_out, int *ruid_out) {
    *ppid_out = 0;
    *ruid_out = -1;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/status", pid);
    FILE *fp = fopen(path, "re");
    if (!fp) return;
    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "PPid:", 5) == 0) {
            *ppid_out = atoi(line + 5);
        } else if (strncmp(line, "Uid:", 4) == 0) {
            *ruid_out = atoi(line + 4);
        }
        if (*ppid_out > 0 && *ruid_out >= 0) break;
    }
    fclose(fp);
}

static char *format_sudo_subtitle(GPtrArray *argv) {
    static const char *flags_with_arg[] = {
        "-u", "-g", "-p", "-C", "-D", "-R", "-T", "-h", "-r", "-t", NULL
    };
    guint i = 1;
    while (i < argv->len) {
        const char *tok = g_ptr_array_index(argv, i);
        if (strcmp(tok, "--") == 0) { i++; break; }
        if (tok[0] != '-') break;
        gboolean has_arg = FALSE;
        for (int k = 0; flags_with_arg[k]; ++k) {
            if (strcmp(tok, flags_with_arg[k]) == 0) { has_arg = TRUE; break; }
        }
        i += has_arg ? 2 : 1;
    }
    GString *rest = g_string_new("");
    for (; i < argv->len; ++i) {
        if (rest->len > 0) g_string_append_c(rest, ' ');
        g_string_append(rest, (const char *)g_ptr_array_index(argv, i));
    }
    g_strstrip(rest->str);
    rest->len = strlen(rest->str);
    if (rest->len == 0) {
        g_string_free(rest, TRUE);
        return g_strdup("Authenticate command in terminal");
    }
    if (rest->len > 46) {
        g_string_truncate(rest, 45);
        while (rest->len > 0 && g_ascii_isspace(rest->str[rest->len - 1])) {
            g_string_truncate(rest, rest->len - 1);
        }
        g_string_append(rest, "\xe2\x80\xa6"); /* UTF-8 ellipsis */
    }
    char *out = g_strdup_printf("sudo %s", rest->str);
    g_string_free(rest, TRUE);
    return out;
}

static gboolean argv0_base_is(GPtrArray *argv, const char *target) {
    if (!argv || argv->len == 0) return FALSE;
    const char *a0 = g_ptr_array_index(argv, 0);
    const char *slash = strrchr(a0, '/');
    const char *base = slash ? slash + 1 : a0;
    return strcmp(base, target) == 0;
}

static void inspect_caller(CallerInfo *out) {
    memset(out, 0, sizeof(*out));
    int my_uid = (int)getuid();
    GHashTable *procs = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, proc_info_free);

    DIR *d = opendir("/proc");
    if (d) {
        struct dirent *de;
        while ((de = readdir(d)) != NULL) {
            if (!isdigit((unsigned char)de->d_name[0])) continue;
            gboolean all_digits = TRUE;
            for (const char *p = de->d_name; *p; ++p) {
                if (!isdigit((unsigned char)*p)) { all_digits = FALSE; break; }
            }
            if (!all_digits) continue;
            int pid = atoi(de->d_name);
            if (pid <= 0) continue;

            char comm_path[64], comm_buf[128] = "";
            snprintf(comm_path, sizeof(comm_path), "/proc/%d/comm", pid);
            FILE *cf = fopen(comm_path, "re");
            if (!cf) continue;
            if (!fgets(comm_buf, sizeof(comm_buf), cf)) { fclose(cf); continue; }
            fclose(cf);
            g_strstrip(comm_buf);
            if (!comm_buf[0]) continue;

            if (is_suppressed_comm(comm_buf)) {
                closedir(d);
                g_hash_table_unref(procs);
                out->suppressed = TRUE;
                return;
            }

            GPtrArray *argv = read_proc_cmdline(pid);
            if (argv->len > 0) {
                const char *a0 = g_ptr_array_index(argv, 0);
                const char *slash = strrchr(a0, '/');
                const char *base0 = slash ? slash + 1 : a0;
                if (is_suppressed_comm(base0)) {
                    g_ptr_array_unref(argv);
                    closedir(d);
                    g_hash_table_unref(procs);
                    out->suppressed = TRUE;
                    return;
                }
            }

            ProcInfo *pi = g_new0(ProcInfo, 1);
            pi->pid = pid;
            pi->comm = g_strdup(comm_buf);
            pi->argv = argv;
            read_proc_status(pid, &pi->ppid, &pi->ruid);
            g_hash_table_insert(procs, GINT_TO_POINTER(pid), pi);
        }
        closedir(d);
    }

    if (has_suppressed_layer()) {
        g_hash_table_unref(procs);
        out->suppressed = TRUE;
        return;
    }

    int best_fp_pid = 0;
    int best_sudo_pid = 0;
    ProcInfo *best_sudo_pi = NULL;
    gboolean has_fidod = FALSE;

    GHashTableIter iter;
    gpointer key, val;
    g_hash_table_iter_init(&iter, procs);
    while (g_hash_table_iter_next(&iter, &key, &val)) {
        ProcInfo *pi = (ProcInfo *)val;
        if (strcmp(pi->comm, "fprintd-verify") == 0 || argv0_base_is(pi->argv, "fprintd-verify")) {
            if (pi->pid > best_fp_pid) best_fp_pid = pi->pid;
        }
        if (strcmp(pi->comm, "sudo") == 0 || strcmp(pi->comm, "doas") == 0 ||
            argv0_base_is(pi->argv, "sudo") || argv0_base_is(pi->argv, "doas")) {
            if (pi->pid > best_sudo_pid) {
                best_sudo_pid = pi->pid;
                best_sudo_pi = pi;
            }
        }
        if (strcmp(pi->comm, "aurora-fidod") == 0 || argv0_base_is(pi->argv, "aurora-fidod")) {
            has_fidod = TRUE;
        }
    }

    if (best_fp_pid > 0) {
        ProcInfo *fp_pi = g_hash_table_lookup(procs, GINT_TO_POINTER(best_fp_pid));
        int cancel_pid = (fp_pi && fp_pi->ruid == my_uid) ? best_fp_pid : 0;
        int cur = fp_pi ? fp_pi->ppid : 0;
        int hops = 0;
        while (cur > 1 && hops++ < 32) {
            ProcInfo *anc = g_hash_table_lookup(procs, GINT_TO_POINTER(cur));
            if (!anc) break;
            char *comm_lc = g_ascii_strdown(anc->comm, -1);
            GString *joined = g_string_new("");
            for (guint i = 0; i < anc->argv->len; ++i) {
                if (i > 0) g_string_append_c(joined, ' ');
                g_string_append(joined, (const char *)g_ptr_array_index(anc->argv, i));
            }
            char *joined_lc = g_ascii_strdown(joined->str, -1);
            g_string_free(joined, TRUE);

            gboolean is_orb = strstr(comm_lc, "orb") != NULL ||
                              strstr(joined_lc, "orb-signer") != NULL ||
                              strstr(joined_lc, ".orb-signer") != NULL ||
                              strstr(joined_lc, "orb-desktop") != NULL;
            g_free(comm_lc);
            g_free(joined_lc);

            if (is_orb) {
                char *reason = NULL;
                for (guint i = 0; i < anc->argv->len; ++i) {
                    const char *arg = g_ptr_array_index(anc->argv, i);
                    if (strcmp(arg, "--reason") == 0 && i + 1 < anc->argv->len) {
                        reason = g_strstrip(g_strdup(g_ptr_array_index(anc->argv, i + 1)));
                        break;
                    }
                    if (g_str_has_prefix(arg, "--reason=")) {
                        reason = g_strstrip(g_strdup(arg + 9));
                        break;
                    }
                }
                out->caller_app = g_strdup("Orb");
                out->caller_subtitle = (reason && *reason) ? reason : g_strdup("Touch sensor to approve");
                if (reason && !*reason) g_free(reason);
                out->cancel_pid = cancel_pid;
                g_hash_table_unref(procs);
                return;
            }
            cur = anc->ppid;
        }

        out->caller_app = g_strdup("");
        out->caller_subtitle = g_strdup("Touch sensor to verify");
        out->cancel_pid = cancel_pid;
        g_hash_table_unref(procs);
        return;
    }

    if (best_sudo_pi) {
        out->caller_app = g_strdup("Terminal");
        out->caller_subtitle = format_sudo_subtitle(best_sudo_pi->argv);
        out->cancel_pid = 0;
        g_hash_table_unref(procs);
        return;
    }

    if (has_fidod) {
        out->caller_app = g_strdup("Passkey");
        out->caller_subtitle = g_strdup("Verify passkey with Touch ID");
        out->cancel_pid = 0;
        g_hash_table_unref(procs);
        return;
    }

    out->caller_app = g_strdup("");
    out->caller_subtitle = g_strdup("Touch sensor to authenticate");
    out->cancel_pid = 0;
    g_hash_table_unref(procs);
}

static void start_session_if_needed(MonitorCtx *ctx, const char *finger) {
    if (ctx->session_active) return;
    CallerInfo ci;
    inspect_caller(&ci);
    ctx->session_active = TRUE;
    ctx->session_suppressed = ci.suppressed;
    if (ci.suppressed) {
        emit_simple_event(ctx, "suppressed");
    } else {
        emit_start_event(ctx, finger, &ci);
    }
    caller_info_clear(&ci);
}

static void on_fprint_signal(
    GDBusConnection *connection,
    const gchar *sender_name,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *signal_name,
    GVariant *parameters,
    gpointer user_data
) {
    (void)connection;
    (void)sender_name;
    if (!object_path || !g_str_has_prefix(object_path, "/net/reactivated/Fprint")) return;
    MonitorCtx *ctx = (MonitorCtx *)user_data;

    if (g_strcmp0(interface_name, "net.reactivated.Fprint.Device") == 0) {
        if (g_strcmp0(signal_name, "VerifyFingerSelected") == 0 && parameters) {
            const char *finger = NULL;
            g_variant_get(parameters, "(&s)", &finger);
            start_session_if_needed(ctx, finger ? finger : "");
        } else if (g_strcmp0(signal_name, "VerifyStatus") == 0 && parameters) {
            const char *status = NULL;
            gboolean done = FALSE;
            g_variant_get(parameters, "(&sb)", &status, &done);
            if (status && !ctx->session_suppressed) {
                if (strcmp(status, "verify-match") == 0) {
                    emit_done_event(ctx, "match", NULL, done);
                } else if (strcmp(status, "verify-no-match") == 0) {
                    emit_done_event(ctx, "no-match", NULL, done);
                } else if (strcmp(status, "verify-retry-scan") == 0 ||
                           strcmp(status, "verify-swipe-too-short") == 0 ||
                           strcmp(status, "verify-center-finger") == 0 ||
                           strcmp(status, "verify-remove-and-retry") == 0) {
                    emit_done_event(ctx, "retry", status, done);
                } else if (strcmp(status, "verify-disconnected") == 0 ||
                           strcmp(status, "verify-unknown-error") == 0) {
                    emit_simple_event(ctx, "stop");
                }
            }
            if (done) {
                ctx->session_active = FALSE;
                ctx->session_suppressed = FALSE;
            }
        }
    } else if (g_strcmp0(interface_name, "org.freedesktop.DBus.Properties") == 0 &&
               g_strcmp0(signal_name, "PropertiesChanged") == 0 && parameters) {
        const char *prop_iface = NULL;
        GVariant *changed = NULL;
        g_variant_get_child(parameters, 0, "&s", &prop_iface);
        if (g_strcmp0(prop_iface, "net.reactivated.Fprint.Device") != 0) return;
        changed = g_variant_get_child_value(parameters, 1);
        if (!changed) return;

        GVariant *v_needed = g_variant_lookup_value(changed, "finger-needed", G_VARIANT_TYPE_BOOLEAN);
        if (v_needed) {
            gboolean needed = g_variant_get_boolean(v_needed);
            g_variant_unref(v_needed);
            if (needed && !ctx->session_active) {
                start_session_if_needed(ctx, "");
            } else if (!needed && ctx->session_active) {
                if (!ctx->session_suppressed) {
                    emit_simple_event(ctx, "stop");
                }
                ctx->session_active = FALSE;
                ctx->session_suppressed = FALSE;
            }
        }

        GVariant *v_present = g_variant_lookup_value(changed, "finger-present", G_VARIANT_TYPE_BOOLEAN);
        if (v_present) {
            gboolean present = g_variant_get_boolean(v_present);
            g_variant_unref(v_present);
            if (ctx->session_active && !ctx->session_suppressed) {
                emit_simple_event(ctx, present ? "finger-down" : "finger-up");
            }
        }
        g_variant_unref(changed);
    }
}

static gboolean on_term_signal(gpointer user_data) {
    MonitorCtx *ctx = (MonitorCtx *)user_data;
    g_main_loop_quit(ctx->loop);
    return G_SOURCE_REMOVE;
}

int main(void) {
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (getppid() == 1) return 0;
    signal(SIGPIPE, SIG_IGN);

    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &err);
    if (!bus) {
        if (err) {
            fprintf(stderr, "touchid-monitor: %s\n", err->message);
            g_error_free(err);
        }
        return 1;
    }

    MonitorCtx ctx = { 0 };
    ctx.bus = bus;
    ctx.loop = g_main_loop_new(NULL, FALSE);

    g_unix_signal_add(SIGTERM, on_term_signal, &ctx);
    g_unix_signal_add(SIGINT, on_term_signal, &ctx);

    /* Server-side D-Bus match rules for `net.reactivated.Fprint.Device` signals and
     * `PropertiesChanged` (`arg0='net.reactivated.Fprint.Device'`), avoiding both
     * `NameOwnerChanged` races on on-demand `fprintd` activation and wakeups on unrelated signals. */
    guint sub_dev = g_dbus_connection_signal_subscribe(
        bus,
        NULL,
        "net.reactivated.Fprint.Device",
        NULL,
        NULL,
        NULL,
        G_DBUS_SIGNAL_FLAGS_NONE,
        on_fprint_signal,
        &ctx,
        NULL
    );
    guint sub_props = g_dbus_connection_signal_subscribe(
        bus,
        NULL,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        NULL,
        "net.reactivated.Fprint.Device",
        G_DBUS_SIGNAL_FLAGS_NONE,
        on_fprint_signal,
        &ctx,
        NULL
    );

    g_main_loop_run(ctx.loop);

    g_dbus_connection_signal_unsubscribe(bus, sub_dev);
    g_dbus_connection_signal_unsubscribe(bus, sub_props);
    g_main_loop_unref(ctx.loop);
    g_object_unref(bus);
    return 0;
}
