// cazhelper - Caz's root helper.
//
// Caz spawns this binary as root (TrollStore persona spawn). It measures and deletes
// junk in a fixed set of categories and reports back over stdout, one line per event,
// fields separated by tabs:
//
//   LOG   <text>
//   ERR   <text>
//   CAT   <category> <bytes> <files>              (scan result)
//   APP   <bundle id> <bytes> <name> <note>       (per-app cache size, during scan)
//   SKIP  <bundle id> <bytes> <name> <reason>     (an app whose cache is never touched)
//   FREED <category> <bytes> <files> <errors>     (clean result)
//   AUTOTRIM on|off|unavailable
//
// Usage:
//   cazhelper scan  [--keep-sb]
//   cazhelper clean <cat,cat,...> [--keep-sb] [--close-apps] [--exclude id,id,...]
//   cazhelper autotrim status|enable|disable
//   cazhelper install-update <path to .tipa>
//   cazhelper version
//
// Safety rules: never follows symlinks, never crosses into another volume, only touches
// the paths listed below, and inside app containers only Library/Caches, tmp, web caches,
// abandoned download temp files and installer files left in Documents/Inbox.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <errno.h>
#include <time.h>
#include <limits.h>
#include <unistd.h>
#include <signal.h>
#include <dirent.h>
#include <fts.h>
#include <spawn.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <sys/sysctl.h>
#endif

#define CAZ_VERSION "1.0"
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

extern char **environ;

static char g_root[PATH_MAX] = "";   // test builds only: prefix for every absolute path
static time_t g_now;
static int opt_keep_sb = 0;
static int opt_close_apps = 0;
static char **opt_excl = NULL;
static int opt_excl_n = 0;

// ---------------------------------------------------------------- output

static void emit(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    fflush(stdout);
}

static const char *human(uint64_t b, char *buf, size_t n) {
    static const char *units[] = { "bytes", "KB", "MB", "GB", "TB" };
    double v = (double)b;
    int i = 0;
    while (v >= 1000.0 && i < 4) { v /= 1000.0; i++; }
    if (i == 0) snprintf(buf, n, "%llu bytes", (unsigned long long)b);
    else snprintf(buf, n, "%.1f %s", v, units[i]);
    return buf;
}

// ---------------------------------------------------------------- strings & paths

static int starts_with(const char *s, const char *p) { return strncmp(s, p, strlen(p)) == 0; }

static int ends_with(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcmp(s + a - b, suf) == 0;
}

static int ends_with_ci(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcasecmp(s + a - b, suf) == 0;
}

// Builds a path; on overflow returns an empty string, which every caller treats as "doesn't exist".
__attribute__((format(printf, 2, 3)))
static int pathf(char *out, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(out, PATH_MAX, fmt, ap);
    va_end(ap);
    if (n < 0 || n >= PATH_MAX) { out[0] = 0; return 0; }
    return 1;
}

// Absolute device path -> real path (adds the test root in test builds).
static void rp(char *out, const char *abs) { pathf(out, "%s%s", g_root, abs); }

static int is_dir(const char *p) {
    struct stat st;
    return lstat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static int in_list(const char *list, const char *id) {
    size_t n = strlen(id);
    const char *s = list;
    while (s && *s) {
        const char *comma = strchr(s, ',');
        size_t len = comma ? (size_t)(comma - s) : strlen(s);
        if (len == n && strncmp(s, id, n) == 0) return 1;
        s = comma ? comma + 1 : NULL;
    }
    return 0;
}

// ---------------------------------------------------------------- walking

typedef struct { uint64_t bytes, files, errors; } Totals;
typedef int (*Filter)(const FTSENT *e);

static void add(Totals *t, const Totals *o) { t->bytes += o->bytes; t->files += o->files; t->errors += o->errors; }

// Measures (clean = 0) or deletes (clean = 1) files under `dir`, never `dir` itself.
//   maxdepth  0 = unlimited, 1 = direct children only, ...
//   filter    NULL = every file
//   prune     also remove the emptied sub-folders (used for "empty this folder")
static void walk(const char *dir, int maxdepth, Filter filter, int clean, int prune, Totals *t) {
    if (!is_dir(dir)) return;                       // missing, a file, or a symlink: skip
    char *roots[2] = { (char *)dir, NULL };
    FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) { if (clean) t->errors++; return; }
    FTSENT *e;
    while ((e = fts_read(fts)) != NULL) {
        if (e->fts_level == 0) continue;
        switch (e->fts_info) {
        case FTS_D:
            if (maxdepth > 0 && e->fts_level >= maxdepth) fts_set(fts, e, FTS_SKIP);
            break;
        case FTS_DP:
            if (clean && prune) rmdir(e->fts_accpath);   // fails harmlessly if not empty
            break;
        case FTS_F: case FTS_SL: case FTS_SLNONE: case FTS_DEFAULT: {
            if (maxdepth > 0 && e->fts_level > maxdepth) break;
            if (filter && !filter(e)) break;
            uint64_t b = (uint64_t)e->fts_statp->st_blocks * 512u;
            if (!clean) { t->bytes += b; t->files++; }
            else if (unlink(e->fts_accpath) == 0) { t->bytes += b; t->files++; }
            else t->errors++;
            break;
        }
        case FTS_DNR: case FTS_ERR: case FTS_NS:
            if (clean) t->errors++;
            break;
        default:
            break;
        }
    }
    fts_close(fts);
}

static void contents_at(const char *p, int clean, Totals *t) { walk(p, 0, NULL, clean, 1, t); }
static void files_at(const char *p, int depth, Filter f, int clean, Totals *t) { walk(p, depth, f, clean, 0, t); }
static void op_contents(const char *abs, int clean, Totals *t) { char p[PATH_MAX]; rp(p, abs); contents_at(p, clean, t); }
static void op_files(const char *abs, int depth, Filter f, int clean, Totals *t) { char p[PATH_MAX]; rp(p, abs); files_at(p, depth, f, clean, t); }

// ---------------------------------------------------------------- filters

static int older(const FTSENT *e, long secs) { return (long)(g_now - e->fts_statp->st_mtime) >= secs; }

// Log files: skip the ones being written right now (deleting them frees nothing anyway).
static int f_tracev3(const FTSENT *e) { return ends_with(e->fts_name, ".tracev3") && older(e, 120); }

// Download temp files nobody has touched for an hour are abandoned.
static int f_cfnet(const FTSENT *e) {
    return starts_with(e->fts_name, "CFNetworkDownload_") && ends_with(e->fts_name, ".tmp") && older(e, 3600);
}

static int f_crash(const FTSENT *e) {
    if (!opt_keep_sb) return 1;
    const char *n = e->fts_name;
    return !(starts_with(n, "SpringBoard") || starts_with(n, "JetsamEvent") || starts_with(n, "panic"));
}

static int f_installer(const FTSENT *e) {
    const char *n = e->fts_name;
    return (ends_with_ci(n, ".ipa") || ends_with_ci(n, ".tipa") || ends_with_ci(n, ".deb")) && older(e, 3600);
}

// ---------------------------------------------------------------- containers

typedef struct { char id[256]; char path[PATH_MAX]; char name[256]; } Box;
typedef struct { Box *v; int n; } Boxes;

#ifdef __APPLE__
// Bundle id from the container manager's metadata plist (binary plist, MCMMetadataIdentifier).
static int read_container_id(const char *dir, char *out, size_t len) {
    char p[PATH_MAX];
    pathf(p, "%s/.com.apple.mobile_container_manager.metadata.plist", dir);
    FILE *f = fopen(p, "rb");
    if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long sz = ftell(f);
    rewind(f);
    if (sz <= 0 || sz > (1 << 20)) { fclose(f); return 0; }
    UInt8 *buf = malloc((size_t)sz);
    if (!buf) { fclose(f); return 0; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, buf, (CFIndex)got, kCFAllocatorMalloc);
    if (!data) { free(buf); return 0; }
    CFPropertyListRef pl = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    int ok = 0;
    if (pl && CFGetTypeID(pl) == CFDictionaryGetTypeID()) {
        CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)pl, CFSTR("MCMMetadataIdentifier"));
        if (v && CFGetTypeID(v) == CFStringGetTypeID())
            ok = CFStringGetCString((CFStringRef)v, out, (CFIndex)len, kCFStringEncodingUTF8) ? 1 : 0;
    }
    if (pl) CFRelease(pl);
    return ok;
}
#else
// Test builds: the fake metadata file simply contains the bundle id as text.
static int read_container_id(const char *dir, char *out, size_t len) {
    char p[PATH_MAX];
    pathf(p, "%s/.com.apple.mobile_container_manager.metadata.plist", dir);
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    if (!fgets(out, (int)len, f)) { fclose(f); return 0; }
    fclose(f);
    out[strcspn(out, "\r\n")] = 0;
    return out[0] != 0;
}
#endif

static void find_app_name(const char *bundle_dir, char *out, size_t len) {
    out[0] = 0;
    DIR *d = opendir(bundle_dir);
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (ends_with(de->d_name, ".app")) {
            snprintf(out, len, "%.*s", (int)(strlen(de->d_name) - 4), de->d_name);
            break;
        }
    }
    closedir(d);
}

static void boxes_load(const char *abs_base, Boxes *bx, int want_names) {
    char base[PATH_MAX];
    rp(base, abs_base);
    bx->v = NULL;
    bx->n = 0;
    DIR *d = opendir(base);
    if (!d) return;
    int cap = 0;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.') continue;      // ".", "..", hidden folders
        Box b;
        memset(&b, 0, sizeof b);
        pathf(b.path, "%s/%s", base, de->d_name);
        if (!is_dir(b.path)) continue;
        if (!read_container_id(b.path, b.id, sizeof b.id)) continue;
        if (want_names) find_app_name(b.path, b.name, sizeof b.name);
        if (bx->n == cap) {
            cap = cap ? cap * 2 : 64;
            Box *nv = realloc(bx->v, (size_t)cap * sizeof(Box));
            if (!nv) break;
            bx->v = nv;
        }
        bx->v[bx->n++] = b;
    }
    closedir(d);
}

static const Box *box_by_id(const Boxes *bx, const char *id) {
    for (int i = 0; i < bx->n; i++) if (strcmp(bx->v[i].id, id) == 0) return &bx->v[i];
    return NULL;
}

// Apps whose cache folder holds things you chose to download. Only apps actually installed are
// reported (as SKIP lines), and their caches are never touched.
typedef struct { const char *prefix; const char *reason; } Skip;
static const Skip k_skip[] = {
    { "com.spotify.client", "Keeps downloaded songs in its cache" },
    { NULL, NULL }
};

// Apps that keep a few things worth keeping inside an otherwise disposable cache. Those folders
// stay; everything else in the cache is cleaned. Found by looking inside real app caches.
typedef struct { const char *id; const char *folders[4]; const char *note; } Keep;
static const Keep k_keep[] = {
    { "com.zhiliaoapp.musically", { "offline-mode", "com.studio.album.importToEdit", NULL }, "Offline videos and draft media are kept" },
    { "com.strava.stravaride",    { "offline", "mapdownloads", NULL },                    "Offline maps are kept" },
    { "com.google.Maps",          { "OfflineData", NULL },                                 "Offline maps are kept" },
    { NULL, { NULL }, NULL }
};

static const Skip *skip_for(const char *id) {
    for (const Skip *k = k_skip; k->prefix; k++) if (starts_with(id, k->prefix)) return k;
    return NULL;
}

static const Keep *keep_for(const char *id) {
    for (const Keep *k = k_keep; k->id; k++) if (strcmp(id, k->id) == 0) return k;
    return NULL;
}

// Caz never touches its own data or a skipped app's cache.
static int never_touch(const char *id) { return skip_for(id) != NULL || strcmp(id, "com.parv.caz") == 0; }

static int is_excluded(const char *id) {
    for (int i = 0; i < opt_excl_n; i++) if (strcmp(opt_excl[i], id) == 0) return 1;
    return 0;
}

// ---------------------------------------------------------------- closing processes

typedef int (*ProcMatch)(const char *exe, const void *ctx);
typedef struct { const char **dirs; int n; } PrefixCtx;

static int under(const char *exe, const char *dir) {
    size_t l = strlen(dir);
    return strncmp(exe, dir, l) == 0 && exe[l] == '/';
}

static int m_prefix(const char *exe, const void *c) {
    const PrefixCtx *pc = c;
    for (int i = 0; i < pc->n; i++) {
        const char *d = pc->dirs[i];
        if (under(exe, d)) return 1;
        if (starts_with(d, "/private/") && under(exe, d + 8)) return 1;   // "/var/..." spelling
    }
    return 0;
}

static int m_exact(const char *exe, const void *c) { return strcmp(exe, (const char *)c) == 0; }

static int m_basename(const char *exe, const void *c) {
    const char *s = strrchr(exe, '/');
    return s && strcmp(s + 1, (const char *)c) == 0;
}

#ifdef __APPLE__
static int kill_procs(ProcMatch match, const void *ctx) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return 0;
    len += 16 * sizeof(struct kinfo_proc);
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return 0;
    if (sysctl(mib, 3, procs, &len, NULL, 0) != 0) { free(procs); return 0; }
    int count = (int)(len / sizeof(struct kinfo_proc));
    int argmax = 0;
    size_t asz = sizeof argmax;
    int amib[2] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(amib, 2, &argmax, &asz, NULL, 0) != 0 || argmax <= 0) argmax = 65536;
    char *buf = malloc((size_t)argmax);
    if (!buf) { free(procs); return 0; }
    pid_t me = getpid(), parent = getppid();
    int killed = 0;
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 1 || pid == me || pid == parent) continue;
        int pmib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
        size_t s = (size_t)argmax;
        if (sysctl(pmib, 3, buf, &s, NULL, 0) != 0 || s <= sizeof(int)) continue;
        buf[s - 1] = 0;
        const char *exe = buf + sizeof(int);       // executable path follows argc
        if (match(exe, ctx) && kill(pid, SIGKILL) == 0) killed++;
    }
    free(buf);
    free(procs);
    return killed;
}
#else
static int kill_procs(ProcMatch match, const void *ctx) { (void)match; (void)ctx; return 0; }
#endif

// ---------------------------------------------------------------- categories

static void cat_logs(int clean, Totals *t) {
    op_files("/private/var/db/diagnostics", 0, f_tracev3, clean, t);
}

static void each_container(const char *abs_base, void (*fn)(const char *cpath, int clean, Totals *t), int clean, Totals *t) {
    char base[PATH_MAX];
    rp(base, abs_base);
    DIR *d = opendir(base);
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.') continue;
        char p[PATH_MAX];
        pathf(p, "%s/%s", base, de->d_name);
        if (is_dir(p)) fn(p, clean, t);
    }
    closedir(d);
}

static void downloads_in(const char *c, int clean, Totals *t) {
    char p[PATH_MAX];
    pathf(p, "%s/tmp", c);                                      files_at(p, 1, f_cfnet, clean, t);
    pathf(p, "%s/Documents", c);                                files_at(p, 1, f_cfnet, clean, t);
    pathf(p, "%s/Library/Caches/com.apple.nsurlsessiond/Downloads", c); files_at(p, 0, f_cfnet, clean, t);
}

static void cat_downloads(int clean, Totals *t) {
    op_files("/private/var/mobile/Library/Caches/com.apple.nsurlsessiond/Downloads", 0, f_cfnet, clean, t);
    op_files("/private/var/tmp", 1, f_cfnet, clean, t);
    each_container("/private/var/mobile/Containers/Data/Application", downloads_in, clean, t);
    each_container("/private/var/mobile/Containers/Data/PluginKitPlugin", downloads_in, clean, t);
    each_container("/private/var/mobile/Containers/Data/InternalDaemon", downloads_in, clean, t);
}

static void cat_crash(int clean, Totals *t) {
    op_files("/private/var/mobile/Library/Logs/CrashReporter", 0, f_crash, clean, t);
    op_files("/private/var/logs/CrashReporter", 0, NULL, clean, t);
    op_contents("/private/var/root/Library/Caches/hangtracerd", clean, t);
    op_files("/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/DiagnosticReports", 0, NULL, clean, t);
}

static void cat_syscache(int clean, Totals *t) {
    static const char *dirs[] = {
        "/private/var/root/Library/Caches/com.apple.coresymbolicationd",
        "/private/var/mobile/Library/Caches/com.apple.AvatarKit",
        "/private/var/mobile/Library/Caches/com.apple.QuickLook.thumbnailcache",
        "/private/var/mobile/tmp/MediaCache",
        "/private/var/mobile/tmp/com.apple.mediaanalysisd/PosterConfigurations",
        "/private/var/mobile/Media/PublicStaging",
        "/private/var/mobile/Library/Caches/wiki.qaq.TrollFools/InjectorV3",
        NULL
    };
    for (int i = 0; dirs[i]; i++) op_contents(dirs[i], clean, t);

    // Photos keeps temporary copies of items you share or pick in its File Provider group.
    // Only that group has a "photospicker" folder, which is how it's recognised.
    char base[PATH_MAX];
    rp(base, "/private/var/mobile/Containers/Shared/AppGroup");
    DIR *d = opendir(base);
    if (d) {
        struct dirent *de;
        while ((de = readdir(d)) != NULL) {
            if (de->d_name[0] == '.') continue;
            char picker[PATH_MAX], dnd[PATH_MAX];
            pathf(picker, "%s/%s/File Provider Storage/photospicker", base, de->d_name);
            if (!is_dir(picker)) continue;
            pathf(dnd, "%s/%s/File Provider Storage/draganddrop", base, de->d_name);
            contents_at(picker, clean, t);
            contents_at(dnd, clean, t);
        }
        closedir(d);
    }
    if (clean) kill_procs(m_basename, "coresymbolicationd");
}

static void inbox_in(const char *c, int clean, Totals *t) {
    char p[PATH_MAX];
    pathf(p, "%s/Documents/Inbox", c);
    files_at(p, 1, f_installer, clean, t);
}

static void cat_installers(int clean, Totals *t) {
    each_container("/private/var/mobile/Containers/Data/Application", inbox_in, clean, t);
    each_container("/private/var/mobile/Library/Application Support/Containers", inbox_in, clean, t);
}

static void cat_previews(int clean, Totals *t) {
    if (clean) kill_procs(m_exact, "/Applications/MobileSMS.app/MobileSMS");
    op_contents("/private/var/mobile/Library/Caches/com.apple.MobileSMS/Previews", clean, t);
}

static void cat_maps(int clean, Totals *t) {
    if (clean) {
        Boxes bundles;
        boxes_load("/private/var/containers/Bundle/Application", &bundles, 0);
        const Box *maps = box_by_id(&bundles, "com.apple.Maps");
        if (maps) {
            const char *dirs[1] = { maps->path };
            PrefixCtx pc = { dirs, 1 };
            kill_procs(m_prefix, &pc);
        }
        kill_procs(m_exact, "/Applications/Maps.app/Maps");
        free(bundles.v);
    }
    op_contents("/private/var/mobile/Library/Caches/com.apple.geod/MapTiles", clean, t);
    op_contents("/private/var/mobile/Library/Caches/GeoServices", clean, t);
    if (clean) kill_procs(m_basename, "geod");
}

// Like contents_at, but top-level entries named in `keep` are left as they are.
static void contents_except(const char *dir, const char *const *keep, int clean, Totals *t) {
    if (!is_dir(dir)) return;
    DIR *d = opendir(dir);
    if (!d) { if (clean) t->errors++; return; }
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;
        int kept = 0;
        for (int i = 0; keep[i]; i++) if (strcmp(de->d_name, keep[i]) == 0) kept = 1;
        if (kept) continue;
        char p[PATH_MAX];
        if (!pathf(p, "%s/%s", dir, de->d_name)) continue;
        struct stat st;
        if (lstat(p, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            contents_at(p, clean, t);
            if (clean) rmdir(p);
        } else {
            uint64_t b = (uint64_t)st.st_blocks * 512u;
            if (!clean) { t->bytes += b; t->files++; }
            else if (unlink(p) == 0) { t->bytes += b; t->files++; }
            else t->errors++;
        }
    }
    closedir(d);
}

static void app_cache_targets(const char *cpath, const char *id, int clean, Totals *t) {
    char p[PATH_MAX];
    const Keep *keep = keep_for(id);
    pathf(p, "%s/Library/Caches", cpath);
    if (keep) contents_except(p, keep->folders, clean, t);
    else contents_at(p, clean, t);
    pathf(p, "%s/tmp", cpath);            contents_at(p, clean, t);
    pathf(p, "%s/SystemData/com.apple.SafariViewService/Library/WebKit/WebsiteData/NetworkCache", cpath);
    contents_at(p, clean, t);
    if (strcmp(id, "com.kdt.livecontainer") == 0) {        // apps running inside LiveContainer
        char g[PATH_MAX];
        pathf(g, "%s/Documents/Data/Application", cpath);
        DIR *d = opendir(g);
        if (!d) return;
        struct dirent *de;
        while ((de = readdir(d)) != NULL) {
            if (de->d_name[0] == '.') continue;
            pathf(p, "%s/%s/Library/Caches", g, de->d_name); contents_at(p, clean, t);
            pathf(p, "%s/%s/tmp", g, de->d_name);            contents_at(p, clean, t);
        }
        closedir(d);
    }
}

static void extension_caches(const char *c, int clean, Totals *t) {
    char p[PATH_MAX];
    pathf(p, "%s/Library/Caches", c); contents_at(p, clean, t);
    pathf(p, "%s/tmp", c);            contents_at(p, clean, t);
}

static void cat_appcache(int clean, Totals *t) {
    Boxes data, bundles;
    boxes_load("/private/var/mobile/Containers/Data/Application", &data, 0);
    boxes_load("/private/var/containers/Bundle/Application", &bundles, 1);

    if (clean && opt_close_apps) {
        const char **dirs = calloc((size_t)data.n + 1, sizeof(char *));
        int nd = 0;
        for (int i = 0; dirs && i < data.n; i++) {
            if (never_touch(data.v[i].id) || is_excluded(data.v[i].id)) continue;
            const Box *b = box_by_id(&bundles, data.v[i].id);
            if (b) dirs[nd++] = b->path;
        }
        PrefixCtx pc = { dirs, nd };
        int killed = dirs ? kill_procs(m_prefix, &pc) : 0;
        if (killed) emit("LOG\tClosed %d running app process%s", killed, killed == 1 ? "" : "es");
        free(dirs);
    }

    for (int i = 0; i < data.n; i++) {
        const Box *b = &data.v[i];
        const Box *bb = box_by_id(&bundles, b->id);
        const char *name = (bb && bb->name[0]) ? bb->name : b->id;
        const Skip *skip = skip_for(b->id);
        if (skip) {
            if (!clean) {               // measured only, so the list can show what's being left alone
                Totals st = {0, 0, 0};
                app_cache_targets(b->path, b->id, 0, &st);
                emit("SKIP\t%s\t%llu\t%s\t%s", b->id, (unsigned long long)st.bytes, name, skip->reason);
            }
            continue;
        }
        if (never_touch(b->id) || is_excluded(b->id)) continue;
        Totals at = {0, 0, 0};
        app_cache_targets(b->path, b->id, clean, &at);
        add(t, &at);
        if (!clean && at.bytes > 0) {
            const Keep *keep = keep_for(b->id);
            emit("APP\t%s\t%llu\t%s\t%s", b->id, (unsigned long long)at.bytes, name, keep ? keep->note : "");
        }
    }

    if (!is_excluded("extensions")) {
        Totals et = {0, 0, 0};
        each_container("/private/var/mobile/Containers/Data/PluginKitPlugin", extension_caches, clean, &et);
        add(t, &et);
        if (!clean && et.bytes > 0)
            emit("APP\textensions\t%llu\tExtensions and in-app browsers\t", (unsigned long long)et.bytes);
    }
    free(data.v);
    free(bundles.v);
}

typedef struct { const char *id; const char *label; void (*fn)(int clean, Totals *t); } Category;

// Cleaning runs in this order; app caches go last because they close apps first.
static const Category k_categories[] = {
    { "logs",       "System logs",         cat_logs },
    { "downloads",  "Abandoned downloads", cat_downloads },
    { "crash",      "Crash reports",       cat_crash },
    { "syscache",   "System caches",       cat_syscache },
    { "installers", "Leftover installers", cat_installers },
    { "previews",   "Messages previews",   cat_previews },
    { "maps",       "Maps tiles",          cat_maps },
    { "appcache",   "App caches",          cat_appcache },
    { NULL, NULL, NULL }
};

static void do_scan(void) {
    char h[32];
    uint64_t total = 0;
    for (const Category *c = k_categories; c->id; c++) {
        emit("LOG\tMeasuring %s", c->label);
        Totals t = {0, 0, 0};
        c->fn(0, &t);
        total += t.bytes;
        emit("CAT\t%s\t%llu\t%llu", c->id, (unsigned long long)t.bytes, (unsigned long long)t.files);
        emit("LOG\t  %s in %llu files", human(t.bytes, h, sizeof h), (unsigned long long)t.files);
    }
    emit("LOG\tScan finished: %s found", human(total, h, sizeof h));
}

static void do_clean(const char *list) {
    char h[32];
    uint64_t total = 0;
    for (const Category *c = k_categories; c->id; c++) {
        if (!in_list(list, c->id)) continue;
        emit("LOG\tCleaning %s", c->label);
        Totals t = {0, 0, 0};
        c->fn(1, &t);
        total += t.bytes;
        emit("FREED\t%s\t%llu\t%llu\t%llu", c->id, (unsigned long long)t.bytes,
             (unsigned long long)t.files, (unsigned long long)t.errors);
        emit("LOG\t  freed %s from %llu files", human(t.bytes, h, sizeof h), (unsigned long long)t.files);
        if (t.errors) emit("LOG\t  %llu files couldn't be removed (in use or protected)", (unsigned long long)t.errors);
    }
    emit("LOG\tClean finished: %s freed", human(total, h, sizeof h));
}

// ---------------------------------------------------------------- auto-trim (jailbreak only)

static const char *k_trim_labels[] = { "com.parv.caz.logtrim", "com.parv.logtrim", NULL };

static const char *k_trim_plist =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\">\n"
    "<dict>\n"
    "\t<key>Label</key><string>com.parv.caz.logtrim</string>\n"
    "\t<key>ProgramArguments</key>\n"
    "\t<array>\n"
    "\t\t<string>/var/jb/usr/bin/find</string>\n"
    "\t\t<string>/private/var/db/diagnostics</string>\n"
    "\t\t<string>-name</string><string>*.tracev3</string>\n"
    "\t\t<string>-mmin</string><string>+1440</string>\n"
    "\t\t<string>-delete</string>\n"
    "\t</array>\n"
    "\t<key>RunAtLoad</key><true/>\n"
    "\t<key>StartInterval</key><integer>21600</integer>\n"
    "</dict>\n"
    "</plist>\n";

static void trim_plist_path(char *out, const char *label) {
    char a[PATH_MAX];
    pathf(a, "/var/jb/Library/LaunchDaemons/%s.plist", label);
    rp(out, a);
}

// mkdir -p
static void mkdir_p(const char *path) {
    char tmp[PATH_MAX];
    if (!pathf(tmp, "%s", path)) return;
    for (char *s = tmp + 1; *s; s++) {
        if (*s == '/') { *s = 0; mkdir(tmp, 0755); *s = '/'; }
    }
    mkdir(tmp, 0755);
}

static int jailbreak_present(void) {
    char p[PATH_MAX];
    struct stat st;
    rp(p, "/var/jb/usr/bin");
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);    // follows the /var/jb symlink
}

static int run_cmd(const char *path, char *const argv[]) {
#ifdef CAZ_TEST
    (void)argv;
    emit("LOG\t(test) would run %s %s", path, argv[1]);
    return 0;
#else
    pid_t pid;
    if (posix_spawn(&pid, path, NULL, NULL, argv, environ) != 0) return -1;
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
#endif
}

static int do_autotrim(const char *verb) {
    if (!jailbreak_present()) { emit("AUTOTRIM\tunavailable"); return 0; }
    char launchctl[PATH_MAX], p[PATH_MAX];
    rp(launchctl, "/var/jb/usr/bin/launchctl");

    if (strcmp(verb, "status") == 0) {
        int on = 0;
        for (int i = 0; k_trim_labels[i]; i++) {
            trim_plist_path(p, k_trim_labels[i]);
            if (access(p, F_OK) == 0) on = 1;
        }
        emit("AUTOTRIM\t%s", on ? "on" : "off");
        return 0;
    }
    if (strcmp(verb, "enable") == 0) {
        char dir[PATH_MAX];
        rp(dir, "/var/jb/Library/LaunchDaemons");
        mkdir_p(dir);
        trim_plist_path(p, k_trim_labels[0]);
        FILE *f = fopen(p, "w");
        if (!f) { emit("ERR\tCouldn't write %s: %s", p, strerror(errno)); return 1; }
        fputs(k_trim_plist, f);
        fclose(f);
        chmod(p, 0644);
        if (chown(p, 0, 0) != 0) { /* already root-owned in practice */ }
        char *unload[] = { "launchctl", "unload", p, NULL };
        run_cmd(launchctl, unload);
        char *load[] = { "launchctl", "load", p, NULL };
        int rc = run_cmd(launchctl, load);
        if (rc != 0) emit("ERR\tlaunchctl load returned %d", rc);
        emit("LOG\tAuto-trim is on: every 6 hours, log files older than a day are deleted");
        emit("AUTOTRIM\ton");
        return 0;
    }
    if (strcmp(verb, "disable") == 0) {
        for (int i = 0; k_trim_labels[i]; i++) {
            trim_plist_path(p, k_trim_labels[i]);
            if (access(p, F_OK) != 0) continue;
            char *unload[] = { "launchctl", "unload", p, NULL };
            run_cmd(launchctl, unload);
            unlink(p);
        }
        emit("LOG\tAuto-trim is off");
        emit("AUTOTRIM\toff");
        return 0;
    }
    emit("ERR\tUnknown autotrim action: %s", verb);
    return 2;
}

// ---------------------------------------------------------------- updates

// Installs a downloaded Caz.tipa with TrollStore's installer (trollstorehelper, inside TrollStore.app),
// in its own session so it finishes even when installing closes Caz.
static int do_install_update(const char *path) {
    char mobile[PATH_MAX], mobile2[PATH_MAX];
    rp(mobile, "/private/var/mobile/"); rp(mobile2, "/var/mobile/");
    struct stat st;
    if (!(starts_with(path, mobile) || starts_with(path, mobile2)) || lstat(path, &st) != 0 || !S_ISREG(st.st_mode)
        || !(ends_with_ci(path, ".tipa") || ends_with_ci(path, ".ipa"))) {
        emit("ERR\tThe downloaded update wasn't found");
        return 4;
    }
    Boxes bundles;
    boxes_load("/private/var/containers/Bundle/Application", &bundles, 0);
    const Box *ts = box_by_id(&bundles, "com.opa334.TrollStore");
    char helper[PATH_MAX] = "";
    if (ts) pathf(helper, "%s/TrollStore.app/trollstorehelper", ts->path);
    free(bundles.v);
    if (!helper[0] || access(helper, F_OK) != 0) {
        emit("ERR\tTrollStore's installer wasn't found");
        return 5;
    }
    emit("LOG\tInstalling with TrollStore");
#ifdef CAZ_TEST
    emit("LOG\t(test) would run %s install %s", helper, path);
    return 0;
#else
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
#ifdef POSIX_SPAWN_SETSID
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
#endif
    char *argv[] = { "trollstorehelper", "install", (char *)path, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, helper, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        emit("ERR\tCouldn't start TrollStore's installer: %s", strerror(rc));
        return 6;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    unlink(path);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (code != 0) {
        emit("ERR\tTrollStore's installer returned %d", code);
        return 7;
    }
    emit("LOG\tInstalled");
    return 0;
#endif
}

// ---------------------------------------------------------------- main

static void parse_options(int argc, char **argv, int first) {
    for (int i = first; i < argc; i++) {
        if (strcmp(argv[i], "--keep-sb") == 0) opt_keep_sb = 1;
        else if (strcmp(argv[i], "--close-apps") == 0) opt_close_apps = 1;
        else if (strcmp(argv[i], "--exclude") == 0 && i + 1 < argc) {
            char *list = strdup(argv[++i]);
            for (char *tok = strtok(list, ","); tok; tok = strtok(NULL, ",")) {
                char **nv = realloc(opt_excl, (size_t)(opt_excl_n + 1) * sizeof(char *));
                if (!nv) break;
                opt_excl = nv;
                opt_excl[opt_excl_n++] = strdup(tok);
            }
            free(list);
        }
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    umask(022);
    g_now = time(NULL);
#ifdef CAZ_TEST
    const char *root = getenv("CAZ_ROOT");
    if (root) snprintf(g_root, sizeof g_root, "%s", root);
#else
    if (geteuid() != 0) {
        emit("ERR\tThe helper isn't running as root. Install Caz with TrollStore.");
        return 3;
    }
#endif
    if (argc < 2) {
        emit("ERR\tusage: cazhelper scan | clean <categories> | autotrim status|enable|disable | install-update <tipa> | version");
        return 2;
    }
    if (strcmp(argv[1], "version") == 0) { emit("LOG\tcazhelper %s", CAZ_VERSION); return 0; }
    if (strcmp(argv[1], "scan") == 0) { parse_options(argc, argv, 2); do_scan(); return 0; }
    if (strcmp(argv[1], "clean") == 0 && argc >= 3) { parse_options(argc, argv, 3); do_clean(argv[2]); return 0; }
    if (strcmp(argv[1], "autotrim") == 0 && argc >= 3) return do_autotrim(argv[2]);
    if (strcmp(argv[1], "install-update") == 0 && argc >= 3) return do_install_update(argv[2]);
    emit("ERR\tUnknown command: %s", argv[1]);
    return 2;
}
