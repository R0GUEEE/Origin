/*
 * origin-helper — the setuid-root half of Origin.
 *
 * The app runs as mobile and the APT configuration lives in /var/jb/etc/apt
 * (rootless) or /etc/apt (rootful), so something has to run as root to change
 * it. This is that something, and it is deliberately the smallest thing that
 * can do the job:
 *
 *   - it takes a command and fixed arguments; it never runs a shell
 *   - the destination must sit directly in one of two directories, must be a
 *     plain .list/.sources file, must not be a symlink and must not contain
 *     ".."
 *   - the contents must look like a sources file and be under 256 KiB, so a
 *     compromised app cannot turn this into a general root file-write primitive
 *
 * Build (CI does this):
 *   xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
 *         -O2 -Wall -Wextra -o origin-helper origin-helper.c
 * then ldid-sign it and give it mode 4755 in the package's postinst.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#define MAX_CONTENT (256 * 1024)

static const char *kRootlessRoot = "/var/jb";
static const char *kAptDirs[] = {
    "/etc/apt/sources.list.d",
    "/etc/apt/sileo.list.d",
};
static const size_t kAptDirCount = sizeof(kAptDirs) / sizeof(kAptDirs[0]);

static char gRoot[PATH_MAX] = "";

static void log_error(const char *message) {
    fprintf(stderr, "origin-helper: %s\n", message);
}

static int is_directory(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static void resolve_root(void) {
    if (is_directory(kRootlessRoot)) {
        snprintf(gRoot, sizeof(gRoot), "%s", kRootlessRoot);
    } else {
        snprintf(gRoot, sizeof(gRoot), "%s", "");
    }
}

/* An absolute path with no traversal and no doubled slashes. */
static int is_clean_absolute(const char *path) {
    if (path == NULL || path[0] != '/') return 0;
    if (strstr(path, "..") != NULL) return 0;
    if (strstr(path, "//") != NULL) return 0;
    size_t length = strlen(path);
    if (length >= PATH_MAX) return 0;
    return 1;
}

static int has_sources_extension(const char *path) {
    const char *dot = strrchr(path, '.');
    if (dot == NULL) return 0;
    return strcmp(dot, ".list") == 0 || strcmp(dot, ".sources") == 0;
}

/*
 * The destination is allowed when its parent, with symlinks resolved, is one of
 * the two APT directories under the detected root. Realpath on the parent means
 * a symlinked sources.list.d cannot be used to reach somewhere else.
 */
static int destination_is_allowed(const char *path) {
    if (!is_clean_absolute(path)) return 0;
    if (!has_sources_extension(path)) return 0;

    char parent[PATH_MAX];
    snprintf(parent, sizeof(parent), "%s", path);
    char *slash = strrchr(parent, '/');
    if (slash == NULL) return 0;
    *slash = '\0';

    char resolved[PATH_MAX];
    if (realpath(parent, resolved) == NULL) return 0;

    for (size_t index = 0; index < kAptDirCount; index++) {
        char allowed[PATH_MAX];
        snprintf(allowed, sizeof(allowed), "%s%s", gRoot, kAptDirs[index]);

        char allowedResolved[PATH_MAX];
        if (realpath(allowed, allowedResolved) == NULL) continue;

        size_t length = strlen(allowedResolved);
        if (strncmp(resolved, allowedResolved, length) == 0 && resolved[length] == '\0') {
            /* The file itself must not be a symlink pointing out of the tree. */
            struct stat st;
            if (lstat(path, &st) == 0 && S_ISLNK(st.st_mode)) return 0;
            return 1;
        }
    }
    return 0;
}

/*
 * A cheap shape check on the contents. It is not a parser — the engine already
 * validated the input — it exists so a hostile caller cannot use this helper to
 * write, say, a launch daemon plist into the sources directory.
 */
/* "Types" / "X-Whatever" / "Targets" — a deb822 field name. */
static int is_deb822_field(const char *line, size_t length) {
    size_t index = 0;
    if (length == 0 || !((line[0] >= 'A' && line[0] <= 'Z') || (line[0] >= 'a' && line[0] <= 'z'))) return 0;
    while (index < length && line[index] != ':') {
        char c = line[index];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return 0;
        index++;
    }
    return index > 0 && index < length && line[index] == ':';
}

static int content_looks_like_sources(const char *buffer, size_t length) {
    static const char *allowedPrefixes[] = {
        "deb ", "deb-src ", "Types:", "URIs:", "Suites:", "Components:",
        "Enabled:", "Architectures:", "Targets:", "X-",
    };
    const size_t allowedPrefixCount = sizeof(allowedPrefixes) / sizeof(allowedPrefixes[0]);

    if (length > MAX_CONTENT) return 0;

    size_t start = 0;
    int saw_real_line = 0;
    for (size_t index = 0; index <= length; index++) {
        if (index != length && buffer[index] != '\n') continue;

        size_t begin = start;
        size_t end = index;
        while (begin < end && (buffer[begin] == ' ' || buffer[begin] == '\t')) begin++;
        while (end > begin && (buffer[end - 1] == '\r' || buffer[end - 1] == ' ' || buffer[end - 1] == '\t')) end--;

        if (end > begin && buffer[begin] != '#') {
            int matched = 0;
            for (size_t candidate = 0; candidate < allowedPrefixCount; candidate++) {
                size_t prefixLength = strlen(allowedPrefixes[candidate]);
                if (end - begin >= prefixLength &&
                    strncmp(buffer + begin, allowedPrefixes[candidate], prefixLength) == 0) {
                    matched = 1;
                    break;
                }
            }
            /* A deb822 field: a name made of letters, digits and hyphens,
             * followed by a colon. This is what lets an unmodelled field such
             * as "Targets:" through while still rejecting anything that is not a
             * sources file at all. */
            if (!matched && is_deb822_field(buffer + begin, end - begin)) matched = 1;

            if (!matched) return 0;
            saw_real_line = 1;
        }
        start = index + 1;
    }
    return saw_real_line;
}

static int read_whole_file(const char *path, char **outBuffer, size_t *outLength) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;

    size_t capacity = 8192;
    size_t length = 0;
    char *buffer = malloc(capacity);
    if (buffer == NULL) {
        close(fd);
        return -1;
    }

    for (;;) {
        if (length + 4096 + 1 > capacity) {
            capacity *= 2;
            if (capacity > MAX_CONTENT + 1) {
                free(buffer);
                close(fd);
                errno = EFBIG;
                return -1;
            }
            char *grown = realloc(buffer, capacity);
            if (grown == NULL) {
                free(buffer);
                close(fd);
                return -1;
            }
            buffer = grown;
        }
        ssize_t got = read(fd, buffer + length, capacity - length - 1);
        if (got < 0) {
            if (errno == EINTR) continue;
            free(buffer);
            close(fd);
            return -1;
        }
        if (got == 0) break;
        length += (size_t)got;
    }
    close(fd);
    buffer[length] = '\0';
    *outBuffer = buffer;
    *outLength = length;
    return 0;
}

static int command_install(const char *source, const char *destination) {
    if (!destination_is_allowed(destination)) {
        log_error("refusing to write there");
        return 1;
    }

    char *buffer = NULL;
    size_t length = 0;
    if (read_whole_file(source, &buffer, &length) != 0) {
        log_error("cannot read the staged file");
        return 1;
    }
    if (!content_looks_like_sources(buffer, length)) {
        log_error("the contents do not look like a sources file");
        free(buffer);
        return 1;
    }

    /* Write through a temporary file in the same directory so a reader never
     * sees a half-written sources list. */
    char temporary[PATH_MAX];
    snprintf(temporary, sizeof(temporary), "%s.origin-new", destination);

    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        log_error("cannot create the destination");
        free(buffer);
        return 1;
    }

    size_t written = 0;
    while (written < length) {
        ssize_t result = write(fd, buffer + written, length - written);
        if (result < 0) {
            if (errno == EINTR) continue;
            log_error("cannot write the destination");
            close(fd);
            unlink(temporary);
            free(buffer);
            return 1;
        }
        written += (size_t)result;
    }
    free(buffer);

    if (fchmod(fd, 0644) != 0) log_error("could not set the file mode");
    if (fchown(fd, 0, 0) != 0) log_error("could not set the file owner");
    if (fsync(fd) != 0) log_error("could not flush the file");
    if (close(fd) != 0) {
        log_error("could not close the destination");
        unlink(temporary);
        return 1;
    }
    if (rename(temporary, destination) != 0) {
        log_error("could not replace the destination");
        unlink(temporary);
        return 1;
    }
    return 0;
}

static int command_remove(const char *destination) {
    if (!destination_is_allowed(destination)) {
        log_error("refusing to remove that");
        return 1;
    }
    if (unlink(destination) != 0 && errno != ENOENT) {
        log_error("could not remove the file");
        return 1;
    }
    return 0;
}

/* Both of these are fixed commands, never a string from the caller. */
static int command_apt_update(void) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/usr/bin/apt-get", gRoot);
    execl(path, "apt-get", "update", (char *)NULL);
    log_error("could not run apt-get");
    return 1;
}

static int command_respring(void) {
    char path[PATH_MAX];

    snprintf(path, sizeof(path), "%s/usr/bin/sbreload", gRoot);
    if (access(path, X_OK) == 0) {
        execl(path, "sbreload", (char *)NULL);
    }
    snprintf(path, sizeof(path), "%s/usr/bin/killall", gRoot);
    if (access(path, X_OK) == 0) {
        execl(path, "killall", "SpringBoard", (char *)NULL);
    }
    log_error("no respring tool found");
    return 1;
}

static void usage(void) {
    fprintf(stderr,
            "usage: origin-helper install <staged-file> <destination>\n"
            "       origin-helper remove <destination>\n"
            "       origin-helper apt-update\n"
            "       origin-helper respring\n");
}

int main(int argc, char *argv[]) {
    /* The helper is only useful as root; refuse to be a no-op that looks like
     * success when the setuid bit did not survive installation. */
    if (geteuid() != 0) {
        log_error("not running as root; the setuid bit is missing");
        return 1;
    }
    if (argc < 2) {
        usage();
        return 2;
    }

    resolve_root();

    if (strcmp(argv[1], "install") == 0) {
        if (argc != 4) {
            usage();
            return 2;
        }
        return command_install(argv[2], argv[3]);
    }
    if (strcmp(argv[1], "remove") == 0) {
        if (argc != 3) {
            usage();
            return 2;
        }
        return command_remove(argv[2]);
    }
    if (strcmp(argv[1], "apt-update") == 0) {
        return command_apt_update();
    }
    if (strcmp(argv[1], "respring") == 0) {
        return command_respring();
    }

    usage();
    return 2;
}
