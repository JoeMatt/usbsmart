// The public CLI needs its own app-like bundle to carry a restricted-entitlement profile.
// Keep the usual Contents/MacOS/usbsmart entry point, including symlink invocation.
#include <mach-o/dyld.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    (void)argc;
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *path = malloc(size);
    if (!path || _NSGetExecutablePath(path, &size) != 0) return 1;
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) { perror("usbsmart launcher"); free(path); return 1; }
    free(path);
    char *last = strrchr(resolved, '/');
    if (!last) return 1;
    *last = '\0';
    const char *suffix = "/../Helpers/USBSmartCLI.app/Contents/MacOS/usbsmart";
    if (strlen(resolved) + strlen(suffix) >= sizeof(resolved)) return 1;
    strcat(resolved, suffix);
    execv(resolved, argv);
    perror("usbsmart client");
    return errno == ENOENT ? 127 : 1;
}
