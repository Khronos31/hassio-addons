// px4-userland 対応機種 (PX-Q3U4 / PX-MLT5PE 系 / PX-M1UR / PX-S1UR など) を
// EDCB の1つの BonDriver として開く。GR/BS/CS の3 space を持ち、接続中の
// 筐体すべてをまたいだ物理受信機のプールから、選んだ system に合う空きを
// 選んで確保する。M1UR の1基は T/S 両対応だが排他は instance + receiver の
// 1つの flock で共有する。方式を変えるとき非対応の受信機は解放し、選び直す。
//
// 受信機プールは起動スクリプトが EDCB_PX4_SLOTS で渡す。
//   key:instance:serial:receiver:systems;key:...
// systems は T / S / TS。px4-ts は --instance で同じ endpoint を開く。
// EDCB_PX4_GR_ONLY があるときは chscan 用に GR space だけを公開する。
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef unsigned int DWORD;
typedef int BOOL;

struct Bon1 {
    void* ctx;
    const void* end;
    BOOL (*open_tuner)(void*);
    void (*close_tuner)(void*);
    BOOL (*set_channel_byte)(void*, BYTE);
    float (*signal)(void*);
    DWORD (*wait_ts)(void*, DWORD);
    DWORD (*ready)(void*);
    BOOL (*get_ts_copy)(void*, BYTE*, DWORD*, DWORD*);
    BOOL (*get_ts_ptr)(void*, BYTE**, DWORD*, DWORD*);
    void (*purge)(void*);
    void (*release)(void*);
};

struct Bon2 {
    Bon1 base;
    const uint16_t* (*tuner_name)(void*);
    BOOL (*is_open)(void*);
    const uint16_t* (*enum_space)(void*, DWORD);
    const uint16_t* (*enum_channel)(void*, DWORD, DWORD);
    BOOL (*set_channel)(void*, DWORD, DWORD);
    DWORD (*cur_space)(void*);
    DWORD (*cur_channel)(void*);
};

namespace {

constexpr int kFirstPhysical = 13;
constexpr int kLastPhysical = 62;
constexpr int kGrCount = kLastPhysical - kFirstPhysical + 1;
constexpr int kBsTransponders = 12;  // 01,03,...,23
constexpr int kBsSlots = 12;         // 0..11
constexpr int kBsCount = kBsTransponders * kBsSlots;
constexpr int kCsCount = 12;  // CS2,CS4,...,CS24
constexpr int kTotalChannels = kGrCount + kBsCount + kCsCount;
constexpr int kSpaceCount = 3;
constexpr size_t kBufferCap = 8 * 1024 * 1024;

// 1つの物理受信機。systems は T/S/TS。
struct Slot {
    std::string model;
    std::string instance;
    std::string serial;
    int receiver = -1;
    bool supports_t = false;
    bool supports_s = false;
};

struct Driver {
    std::mutex mu;
    std::condition_variable cv;
    int slot = -1;
    int lock_fd = -1;
    pid_t stream_pid = -1;
    pid_t decode_pid = -1;
    int read_fd = -1;
    std::thread reader;
    bool stop = false;
    bool opened = false;
    DWORD space = 0;
    DWORD channel = 0;
    bool have_channel = false;
    bool got_bytes = false;
    std::vector<BYTE> buffer;
    std::vector<BYTE> handed;
    uint16_t names[kTotalChannels][8] = {};
    uint16_t tuner_name[16] = {};
    uint16_t space_names[kSpaceCount][8] = {};
};

Driver* driver(void* p) { return static_cast<Driver*>(p); }

void store_ascii(uint16_t* dst, const char* src) {
    while (*src) {
        *dst++ = static_cast<uint16_t>(*src++);
    }
    *dst = 0;
}

std::vector<Slot> g_slots;
bool g_has_t = false;
bool g_has_s = false;
bool g_gr_only = false;

bool split_slot(const std::string& entry, Slot* slot) {
    std::vector<std::string> fields;
    std::size_t start = 0;
    while (true) {
        const std::size_t separator = entry.find(':', start);
        if (separator == std::string::npos) {
            fields.push_back(entry.substr(start));
            break;
        }
        fields.push_back(entry.substr(start, separator - start));
        start = separator + 1;
    }
    if (fields.size() != 5 || fields[0].empty() || fields[1].empty() ||
        fields[2].empty() || fields[4].empty()) {
        return false;
    }
    char* end = nullptr;
    const long receiver = strtol(fields[3].c_str(), &end, 10);
    if (end == nullptr || *end != '\0' || receiver < 0 || receiver > 7) {
        return false;
    }
    slot->model = fields[0];
    slot->instance = fields[1];
    slot->serial = fields[2];
    slot->receiver = static_cast<int>(receiver);
    slot->supports_t = fields[4].find('T') != std::string::npos;
    slot->supports_s = fields[4].find('S') != std::string::npos;
    return slot->supports_t || slot->supports_s;
}

void load_slots() {
    const char* env = getenv("EDCB_PX4_SLOTS");
    if (env == nullptr) {
        return;
    }
    const std::string text(env);
    std::size_t start = 0;
    while (start < text.size()) {
        std::size_t end = text.find(';', start);
        if (end == std::string::npos) {
            end = text.size();
        }
        const std::string entry = text.substr(start, end - start);
        start = end + 1;
        if (entry.empty()) {
            continue;
        }
        Slot slot;
        if (!split_slot(entry, &slot)) {
            continue;
        }
        g_slots.push_back(slot);
        g_has_t = g_has_t || slot.supports_t;
        g_has_s = g_has_s || slot.supports_s;
    }
    g_gr_only = getenv("EDCB_PX4_GR_ONLY") != nullptr;
}

void init_names(Driver* d) {
    store_ascii(d->tuner_name, "PX4");
    for (int i = 0; i < kGrCount; i++) {
        char text[8];
        snprintf(text, sizeof text, "T%d", kFirstPhysical + i);
        store_ascii(d->names[i], text);
    }
    for (int i = 0; i < kBsCount; i++) {
        const int tp = 1 + 2 * (i / kBsSlots);
        const int slot = i % kBsSlots;
        char text[8];
        snprintf(text, sizeof text, "BS%02d_%d", tp, slot);
        store_ascii(d->names[kGrCount + i], text);
    }
    for (int i = 0; i < kCsCount; i++) {
        char text[8];
        snprintf(text, sizeof text, "CS%d", 2 + 2 * i);
        store_ascii(d->names[kGrCount + kBsCount + i], text);
    }
    d->space_names[0][0] = 0x5730;
    d->space_names[0][1] = 0x4E0A;
    d->space_names[0][2] = 0x6CE2;
    d->space_names[0][3] = 0;
    store_ascii(d->space_names[1], "BS");
    store_ascii(d->space_names[2], "CS");
}

void kill_pid(pid_t pid) {
    if (pid <= 0) {
        return;
    }
    kill(pid, SIGTERM);
    for (int i = 0; i < 20; i++) {
        int status = 0;
        if (waitpid(pid, &status, WNOHANG) == pid) {
            return;
        }
        usleep(50 * 1000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, nullptr, 0);
}

void stop_pipeline(Driver* d, std::unique_lock<std::mutex>& lock) {
    d->stop = true;
    if (d->read_fd >= 0) {
        close(d->read_fd);
        d->read_fd = -1;
    }
    d->cv.notify_all();
    if (d->reader.joinable()) {
        lock.unlock();
        d->reader.join();
        lock.lock();
    }
    kill_pid(d->decode_pid);
    kill_pid(d->stream_pid);
    d->decode_pid = -1;
    d->stream_pid = -1;
    d->stop = false;
    d->buffer.clear();
    d->got_bytes = false;
}

void reader_main(Driver* d, int fd) {
    BYTE tmp[188 * 32];
    while (true) {
        ssize_t n = read(fd, tmp, sizeof tmp);
        if (n == 0) {
            break;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        std::lock_guard<std::mutex> lock(d->mu);
        if (d->stop) {
            break;
        }
        d->got_bytes = true;
        if (d->buffer.size() + static_cast<size_t>(n) > kBufferCap) {
            size_t drop = d->buffer.size() + static_cast<size_t>(n) - kBufferCap;
            if (drop >= d->buffer.size()) {
                d->buffer.clear();
            } else {
                d->buffer.erase(d->buffer.begin(),
                                d->buffer.begin() + static_cast<std::ptrdiff_t>(drop));
            }
        }
        d->buffer.insert(d->buffer.end(), tmp, tmp + n);
        d->cv.notify_all();
    }
}

void release_slot(Driver* d) {
    if (d->lock_fd >= 0) {
        flock(d->lock_fd, LOCK_UN);
        close(d->lock_fd);
        d->lock_fd = -1;
    }
    d->slot = -1;
}

int claim_slot(Driver* d, bool want_t) {
    const char* lock_dir = getenv("EDCB_PX4_LOCK_DIR");
    char default_lock_dir[1024];
    if (lock_dir == nullptr) {
#ifdef __APPLE__
        const char* tmpdir = getenv("TMPDIR");
        if (tmpdir == nullptr) {
            tmpdir = "/tmp";
        }
        snprintf(default_lock_dir, sizeof default_lock_dir, "%s/edcb-px4", tmpdir);
        lock_dir = default_lock_dir;
#else
        lock_dir = "/run/edcb-px4";
#endif
    }
    mkdir(lock_dir, 0755);
    // Dedicated receivers should be used before a T/S hybrid (such as M1UR),
    // so an early GR session cannot strand a later satellite session.
    for (int pass = 0; pass < 2; pass++) {
        for (size_t i = 0; i < g_slots.size(); i++) {
            const Slot& slot = g_slots[i];
            if (want_t && !slot.supports_t) {
                continue;
            }
            if (!want_t && !slot.supports_s) {
                continue;
            }
            const bool hybrid = slot.supports_t && slot.supports_s;
            if ((pass == 0 && hybrid) || (pass == 1 && !hybrid)) {
                continue;
            }
            char path[1024];
            snprintf(path, sizeof path, "%s/%s-%d.lock", lock_dir, slot.instance.c_str(),
                     slot.receiver);
            int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
            if (fd < 0) {
                continue;
            }
            if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
                d->lock_fd = fd;
                d->slot = static_cast<int>(i);
                return 0;
            }
            close(fd);
        }
    }
    return -1;
}

BOOL open_tuner(void* p) {
    Driver* d = driver(p);
    std::lock_guard<std::mutex> lock(d->mu);
    if (d->opened) {
        return 1;
    }
    if (g_slots.empty()) {
        return 0;
    }
    d->opened = true;
    d->have_channel = false;
    return 1;
}

void close_tuner(void* p) {
    Driver* d = driver(p);
    std::unique_lock<std::mutex> lock(d->mu);
    stop_pipeline(d, lock);
    release_slot(d);
    d->opened = false;
    d->have_channel = false;
}

bool spawn_pipeline(Driver* d, const char* channel, bool decode) {
    if (d->slot < 0 || d->slot >= static_cast<int>(g_slots.size())) {
        return false;
    }
    const Slot& slot = g_slots[d->slot];
    int to_decode[2] = {-1, -1};
    int from_decode[2] = {-1, -1};
    if (pipe(to_decode) != 0) {
        return false;
    }
    if (decode && pipe(from_decode) != 0) {
        close(to_decode[0]);
        close(to_decode[1]);
        return false;
    }
    pid_t stream = fork();
    if (stream < 0) {
        close(to_decode[0]);
        close(to_decode[1]);
        if (decode) {
            close(from_decode[0]);
            close(from_decode[1]);
        }
        return false;
    }
    if (stream == 0) {
        dup2(to_decode[1], STDOUT_FILENO);
        close(to_decode[0]);
        close(to_decode[1]);
        if (decode) {
            close(from_decode[0]);
            close(from_decode[1]);
        }
        char receiver[16];
        snprintf(receiver, sizeof receiver, "%d", slot.receiver);
        setenv("PX4_INSTANCE", slot.instance.c_str(), 1);
        setenv("PX4_DEVICE", slot.serial.c_str(), 1);
        setenv("PX4_RECEIVER", receiver, 1);
        setenv("PX4_MODEL", slot.model.c_str(), 1);
        char runtime_dir[1024];
        const char* tmpdir = getenv("TMPDIR");
        if (tmpdir == nullptr) {
            tmpdir = "/tmp";
        }
#ifdef __APPLE__
        snprintf(runtime_dir, sizeof runtime_dir, "%s/px4-userland", tmpdir);
        setenv("PX4_RUNTIME_DIR", runtime_dir, 0);
        const char* stream_bin = getenv("PX4_TS_STREAM");
        if (stream_bin == nullptr) {
            stream_bin = "/opt/homebrew/bin/px4-ts-stream";
        }
#else
        setenv("PX4_RUNTIME_DIR", "/run/px4-userland", 0);
        const char* stream_bin = getenv("PX4_TS_STREAM");
        if (stream_bin == nullptr) {
            stream_bin = "/usr/local/bin/px4-ts-stream";
        }
#endif
        execl(stream_bin, "px4-ts-stream", channel, nullptr);
        _exit(127);
    }
    close(to_decode[1]);
    if (decode) {
        pid_t recisdb_pid = fork();
        if (recisdb_pid < 0) {
            kill_pid(stream);
            close(to_decode[0]);
            close(from_decode[0]);
            close(from_decode[1]);
            return false;
        }
        if (recisdb_pid == 0) {
            dup2(to_decode[0], STDIN_FILENO);
            dup2(from_decode[1], STDOUT_FILENO);
            close(to_decode[0]);
            close(from_decode[0]);
            close(from_decode[1]);
            const char* bin = getenv("RECISDB");
            if (bin == nullptr) {
#ifdef __APPLE__
                bin = "/opt/homebrew/bin/recisdb";
#else
                bin = "/usr/bin/recisdb";
#endif
            }
            execl(bin, "recisdb", "decode", "--input", "-", "-", nullptr);
            _exit(127);
        }
        close(to_decode[0]);
        close(from_decode[1]);
        d->stream_pid = stream;
        d->decode_pid = recisdb_pid;
        d->read_fd = from_decode[0];
    } else {
        d->stream_pid = stream;
        d->decode_pid = -1;
        d->read_fd = to_decode[0];
    }
    d->stop = false;
    d->reader = std::thread(reader_main, d, d->read_fd);
    return true;
}

bool want_decode() {
    const char* env = getenv("EDCB_DECODE");
    return env == nullptr || strcmp(env, "0") != 0;
}

BOOL tune(Driver* d, DWORD space, DWORD channel) {
    std::unique_lock<std::mutex> lock(d->mu);
    if (!d->opened) {
        return 0;
    }
    const bool want_t = space == 0;
    char name[16];
    if (space == 0) {
        if (channel >= static_cast<DWORD>(kGrCount)) {
            return 0;
        }
        snprintf(name, sizeof name, "T%d", kFirstPhysical + static_cast<int>(channel));
    } else if (space == 1) {
        if (channel >= static_cast<DWORD>(kBsCount)) {
            return 0;
        }
        const int tp = 1 + 2 * (static_cast<int>(channel) / kBsSlots);
        const int slot = static_cast<int>(channel) % kBsSlots;
        snprintf(name, sizeof name, "BS%02d_%d", tp, slot);
    } else if (space == 2) {
        if (channel >= static_cast<DWORD>(kCsCount)) {
            return 0;
        }
        snprintf(name, sizeof name, "CS%d", 2 + 2 * static_cast<int>(channel));
    } else {
        return 0;
    }
    // system が変わり今の受信機が非対応なら、解放してから選び直す。
    if (d->slot >= 0) {
        const Slot& current = g_slots[d->slot];
        if (want_t ? !current.supports_t : !current.supports_s) {
            stop_pipeline(d, lock);
            release_slot(d);
        }
    }
    if (d->slot < 0) {
        stop_pipeline(d, lock);
        if (claim_slot(d, want_t) < 0) {
            return 0;
        }
    }
    stop_pipeline(d, lock);
    if (!spawn_pipeline(d, name, want_decode())) {
        return 0;
    }
    d->cv.wait_for(lock, std::chrono::seconds(4), [&] { return d->got_bytes || d->stop; });
    if (!d->got_bytes) {
        stop_pipeline(d, lock);
        return 0;
    }
    d->space = space;
    d->channel = channel;
    d->have_channel = true;
    return 1;
}

BOOL set_channel_byte(void* p, BYTE ch) {
    int physical = ch;
    if (physical < kFirstPhysical && physical < kGrCount) {
        physical = kFirstPhysical + physical;
    }
    if (physical < kFirstPhysical || physical > kLastPhysical) {
        return 0;
    }
    return tune(driver(p), 0, static_cast<DWORD>(physical - kFirstPhysical));
}

float signal_level(void* p) {
    Driver* d = driver(p);
    std::lock_guard<std::mutex> lock(d->mu);
    return d->got_bytes ? 40.0f : 0.0f;
}

DWORD wait_ts(void* p, DWORD timeout_ms) {
    Driver* d = driver(p);
    std::unique_lock<std::mutex> lock(d->mu);
    if (d->buffer.empty() && timeout_ms > 0) {
        d->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                       [&] { return !d->buffer.empty(); });
    }
    return static_cast<DWORD>(d->buffer.size());
}

DWORD ready_count(void* p) {
    Driver* d = driver(p);
    std::lock_guard<std::mutex> lock(d->mu);
    return static_cast<DWORD>(d->buffer.size());
}

BOOL copy_out(Driver* d, BYTE* dst, DWORD* size, DWORD* remain) {
    if (d->buffer.empty() || dst == nullptr || size == nullptr) {
        return 0;
    }
    DWORD n = *size;
    if (n > d->buffer.size()) {
        n = static_cast<DWORD>(d->buffer.size());
    }
    memcpy(dst, d->buffer.data(), n);
    d->buffer.erase(d->buffer.begin(), d->buffer.begin() + n);
    *size = n;
    if (remain) {
        *remain = static_cast<DWORD>(d->buffer.size());
    }
    return 1;
}

BOOL get_ts_copy(void* p, BYTE* dst, DWORD* size, DWORD* remain) {
    Driver* d = driver(p);
    std::lock_guard<std::mutex> lock(d->mu);
    return copy_out(d, dst, size, remain);
}

BOOL get_ts_ptr(void* p, BYTE** dst, DWORD* size, DWORD* remain) {
    Driver* d = driver(p);
    std::lock_guard<std::mutex> lock(d->mu);
    if (d->buffer.empty() || dst == nullptr || size == nullptr) {
        return 0;
    }
    d->handed.swap(d->buffer);
    d->buffer.clear();
    *dst = d->handed.data();
    *size = static_cast<DWORD>(d->handed.size());
    if (remain) {
        *remain = 0;
    }
    return 1;
}

void purge(void* p) {
    Driver* d = driver(p);
    std::lock_guard<std::mutex> lock(d->mu);
    d->buffer.clear();
}

void release(void* p) { close_tuner(p); }

const uint16_t* tuner_name(void* p) { return driver(p)->tuner_name; }

BOOL is_open(void* p) {
    Driver* d = driver(p);
    std::lock_guard<std::mutex> lock(d->mu);
    return d->opened ? 1 : 0;
}

const uint16_t* enum_space(void* p, DWORD space) {
    if (g_gr_only) {
        if (space != 0 || !g_has_t) {
            return nullptr;
        }
        return driver(p)->space_names[0];
    }
    if (space >= kSpaceCount) {
        return nullptr;
    }
    if (space == 0 && !g_has_t) {
        return nullptr;
    }
    if ((space == 1 || space == 2) && !g_has_s) {
        return nullptr;
    }
    return driver(p)->space_names[space];
}

const uint16_t* enum_channel(void* p, DWORD space, DWORD channel) {
    if (g_gr_only && space != 0) {
        return nullptr;
    }
    if (space == 0) {
        if (channel >= static_cast<DWORD>(kGrCount)) {
            return nullptr;
        }
        return driver(p)->names[channel];
    }
    if (space == 1) {
        if (channel >= static_cast<DWORD>(kBsCount)) {
            return nullptr;
        }
        return driver(p)->names[kGrCount + channel];
    }
    if (space == 2) {
        if (channel >= static_cast<DWORD>(kCsCount)) {
            return nullptr;
        }
        return driver(p)->names[kGrCount + kBsCount + channel];
    }
    return nullptr;
}

BOOL set_channel(void* p, DWORD space, DWORD channel) {
    if (g_gr_only && space != 0) {
        return 0;
    }
    return tune(driver(p), space, channel);
}

DWORD cur_space(void* p) { return driver(p)->space; }

DWORD cur_channel(void* p) { return driver(p)->channel; }

Driver g_driver;
Bon2 g_bon;

}  // namespace

extern "C" const Bon1* CreateBonStruct(void) {
    static int ready = 0;
    if (!ready) {
        load_slots();
        init_names(&g_driver);
        memset(&g_bon, 0, sizeof g_bon);
        g_bon.base.ctx = &g_driver;
        g_bon.base.end = &g_bon + 1;
        g_bon.base.open_tuner = open_tuner;
        g_bon.base.close_tuner = close_tuner;
        g_bon.base.set_channel_byte = set_channel_byte;
        g_bon.base.signal = signal_level;
        g_bon.base.wait_ts = wait_ts;
        g_bon.base.ready = ready_count;
        g_bon.base.get_ts_copy = get_ts_copy;
        g_bon.base.get_ts_ptr = get_ts_ptr;
        g_bon.base.purge = purge;
        g_bon.base.release = release;
        g_bon.tuner_name = tuner_name;
        g_bon.is_open = is_open;
        g_bon.enum_space = enum_space;
        g_bon.enum_channel = enum_channel;
        g_bon.set_channel = set_channel;
        g_bon.cur_space = cur_space;
        g_bon.cur_channel = cur_channel;
        ready = 1;
    }
    return &g_bon.base;
}
