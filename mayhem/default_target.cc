#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/statvfs.h>
#include <unistd.h>

#include <filesystem>
#include <string>
#include <system_error>

// BasicTestingSetup (addrman, coins_view, rpc) calls util::ThreadRename("test"), which renames the
// process's main thread to "b-test" with prctl(PR_SET_NAME), and TestingSetup names its worker
// threads the same way. Those are the only targets Mayhem fails ("internal error" in regression
// testing) while every target that never renames a thread fuzzes fine. Thread names are cosmetic
// (util::ThreadGetInternalName() is unaffected), so keep the OS-level name the binary started with.
extern "C" int prctl(int option, ...) {
    va_list ap;
    va_start(ap, option);
    unsigned long a2 = va_arg(ap, unsigned long), a3 = va_arg(ap, unsigned long),
                  a4 = va_arg(ap, unsigned long), a5 = va_arg(ap, unsigned long);
    va_end(ap);
    if (option == PR_SET_NAME) return 0;
    return (int)syscall(SYS_prctl, option, a2, a3, a4, a5);
}

// The upstream fuzz binary aborts when FUZZ is unset; fall back to one harness so the binary
// is runnable stand-alone. Mayhemfiles always set FUZZ explicitly.
//
// Harnesses built on BasicTestingSetup/TestingSetup (addrman, coins_view, rpc) create their data
// directory under fs::temp_directory_path()/test_common_Peercoin and abort the process with an
// uncaught filesystem_error when that fails (read-only or foreign-owned /tmp), and the full TestingSetup
// aborts when the data directory's filesystem is nearly full. Point TMPDIR at a fresh private
// directory on a writable filesystem with room to spare, so every run gets its own.
static std::string g_private_tmp;

static void remove_private_tmp() {
    std::error_code ec;
    std::filesystem::remove_all(g_private_tmp, ec);
}

static void choose_private_tmp() {
    // Peercoin aborts ("Disk space is too low!") when the data directory has less than ~50 MiB plus
    // headroom for the coins cache free, so prefer a writable location with plenty of space.
    const unsigned long long want = 1ull << 30;
    const char* bases[] = {getenv("TMPDIR"), "/tmp", ".", "/var/tmp", "/dev/shm", getenv("HOME")};
    std::string best;
    unsigned long long best_free = 0;
    for (const char* base : bases) {
        if (!base || !*base) continue;
        std::string tmpl = std::string(base) + "/peercoin-fuzz-XXXXXX";
        if (!mkdtemp(&tmpl[0])) continue;
        struct statvfs vfs;
        unsigned long long avail = statvfs(tmpl.c_str(), &vfs) == 0
                                       ? (unsigned long long)vfs.f_bavail * vfs.f_frsize : 0;
        if (best.empty() || avail > best_free) {
            if (!best.empty()) rmdir(best.c_str());
            best = tmpl;
            best_free = avail;
        } else {
            rmdir(tmpl.c_str());
        }
        if (best_free >= want) break;
    }
    if (best.empty()) return;
    char* resolved = realpath(best.c_str(), nullptr);
    g_private_tmp = resolved ? resolved : best;
    free(resolved);
    setenv("TMPDIR", g_private_tmp.c_str(), 1);
    atexit(remove_private_tmp);
}

__attribute__((constructor)) static void default_fuzz_target() {
    setenv("FUZZ", "transaction", 0);
    choose_private_tmp();
}
