// PX-Q3U4 / PX-MLT5PE 系 (px4-userland) を EDCB の BonDriver として開く。
// px4-ts-stream の出力を recisdb に通し、STRUCT_IBONDRIVER2 で返す。
//
// 地上波用 (_T) は `-DPX4_BONDRIVER_SATELLITE` 無しで、
// BS/CS 用 (_S) は `-DPX4_BONDRIVER_SATELLITE=1` でビルドする。
// 受信機の割り当ては /run/edcb-px4/<serial>-<receiver>.lock の flock で
// _T / _S の間でも共有する (MLT5 系は同じ受信機が地上波と衛星を兼ねる)。
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

#ifdef PX4_BONDRIVER_SATELLITE
constexpr int kBsTransponders = 12;  // 01,03,...,23
constexpr int kBsSlots = 12;         // 0..11
constexpr int kBsCount = kBsTransponders * kBsSlots;
constexpr int kCsCount = 12;  // CS2,CS4,...,CS24
constexpr int kChannelCount = kBsCount + kCsCount;
constexpr int kSpaceCount = 2;
#else
constexpr int kFirstPhysical = 13;
constexpr int kLastPhysical = 62;
constexpr int kChannelCount = kLastPhysical - kFirstPhysical + 1;
constexpr int kSpaceCount = 1;
#endif

constexpr size_t kBufferCap = 8 * 1024 * 1024;

struct ModelSpec;

struct Driver {
    std::mutex mu;
    std::condition_variable cv;
    char serial[32] = {};
    const ModelSpec* model = nullptr;
    int receiver = -1;
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
    uint16_t names[kChannelCount][8] = {};
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

struct ModelSpec {
    const char* key;
    const char* name;
    int t_pool[8];
    int t_count;
    int s_pool[8];
    int s_count;
};

const ModelSpec* find_model(const char* key) {
    static const ModelSpec kModels[] = {
        {"px_q3u4", "PX-Q3U4", {2, 3, 6, 7}, 4, {0, 1, 4, 5}, 4},
        {"px_q3pe4", "PX-Q3PE4", {2, 3, 6, 7}, 4, {0, 1, 4, 5}, 4},
        {"px_q3pe5", "PX-Q3PE5", {2, 3, 6, 7}, 4, {0, 1, 4, 5}, 4},
        {"px_w3u4", "PX-W3U4", {2, 3}, 2, {0, 1}, 2},
        {"px_w3pe4", "PX-W3PE4", {2, 3}, 2, {0, 1}, 2},
        {"px_w3pe5", "PX-W3PE5", {2, 3}, 2, {0, 1}, 2},
        {"px_mlt5pe", "PX-MLT5PE", {0, 1, 2, 3, 4}, 5, {0, 1, 2, 3, 4}, 5},
        {"dtv02a_5ts_p", "DTV02A-5TS-P", {0, 1, 2, 3, 4}, 5, {0, 1, 2, 3, 4}, 5},
        {"px_mlt8pe3", "PX-MLT8PE3", {0, 1, 2}, 3, {0, 1, 2}, 3},
        {"px_mlt8pe5", "PX-MLT8PE5", {0, 1, 2, 3, 4}, 5, {0, 1, 2, 3, 4}, 5},
        {"dtv02a_4ts_p", "DTV02A-4TS-P", {0, 1, 2, 3}, 4, {0, 1, 2, 3}, 4},
        {"px_m1ur", "PX-M1UR", {0}, 1, {0}, 1},
        {"px_s1ur", "PX-S1UR", {0}, 1, {0, 0}, 0},
        {"dtv03a_1tu", "DTV03A-1TU", {0}, 1, {0, 0}, 0},
        {"dtv02_1t1s_u", "DTV02-1T1S-U", {0}, 1, {0}, 1},
        {"dtv02a_1t1s_u", "DTV02A-1T1S-U", {0}, 1, {0}, 1},
    };
    if (key == nullptr || *key == '\0') {
        return nullptr;
    }
    for (const auto& model : kModels) {
        if (strcmp(model.key, key) == 0) {
            return &model;
        }
    }
    return nullptr;
}

void init_names(Driver* d) {
    const char* env = getenv("PX4_DEVICE");
    if (env != nullptr && strlen(env) < sizeof(d->serial)) {
        snprintf(d->serial, sizeof(d->serial), "%s", env);
    }
    const char* model_env = getenv("PX4_MODEL");
    if (model_env != nullptr && *model_env != '\0') {
        d->model = find_model(model_env);
    }
    if (d->model == nullptr) {
        size_t len = strlen(d->serial);
        if (len == 14) {
            d->model = find_model("px_q3u4");
        } else if (len == 15) {
            d->model = find_model("px_mlt5pe");
        }
    }
    store_ascii(d->tuner_name, d->model != nullptr ? d->model->name : "PX4");
#ifdef PX4_BONDRIVER_SATELLITE
    for (int i = 0; i < kBsCount; i++) {
        int tp = 1 + 2 * (i / kBsSlots);
        int slot = i % kBsSlots;
        char text[8];
        snprintf(text, sizeof text, "BS%02d_%d", tp, slot);
        store_ascii(d->names[i], text);
    }
    for (int i = 0; i < kCsCount; i++) {
        char text[8];
        snprintf(text, sizeof text, "CS%d", 2 + 2 * i);
        store_ascii(d->names[kBsCount + i], text);
    }
    store_ascii(d->space_names[0], "BS");
    store_ascii(d->space_names[1], "CS");
#else
    for (int i = 0; i < kChannelCount; i++) {
        char text[8];
        snprintf(text, sizeof text, "T%d", kFirstPhysical + i);
        store_ascii(d->names[i], text);
    }
    d->space_names[0][0] = 0x5730;
    d->space_names[0][1] = 0x4E0A;
    d->space_names[0][2] = 0x6CE2;
    d->space_names[0][3] = 0;
#endif
}

int receiver_pool_size(const Driver* d) {
    if (d->model == nullptr) {
        return 0;
    }
#ifdef PX4_BONDRIVER_SATELLITE
    return d->model->s_count;
#else
    return d->model->t_count;
#endif
}

int receiver_in_pool(const Driver* d, int index) {
    if (d->model == nullptr || index < 0) {
        return -1;
    }
#ifdef PX4_BONDRIVER_SATELLITE
    if (index >= d->model->s_count) {
        return -1;
    }
    return d->model->s_pool[index];
#else
    if (index >= d->model->t_count) {
        return -1;
    }
    return d->model->t_pool[index];
#endif
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

int claim_receiver(Driver* d) {
    mkdir("/run/edcb-px4", 0755);
    int size = receiver_pool_size(d);
    for (int i = 0; i < size; i++) {
        int receiver = receiver_in_pool(d, i);
        if (receiver < 0) {
            continue;
        }
        char path[128];
        snprintf(path, sizeof path, "/run/edcb-px4/%s-%d.lock", d->serial, receiver);
        int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
        if (fd < 0) {
            continue;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            d->lock_fd = fd;
            d->receiver = receiver;
            return receiver;
        }
        close(fd);
    }
    return -1;
}

BOOL open_tuner(void* p) {
    Driver* d = driver(p);
    std::lock_guard<std::mutex> lock(d->mu);
    if (d->opened) {
        return 1;
    }
    if (d->serial[0] == '\0') {
        return 0;
    }
    if (claim_receiver(d) < 0) {
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
    if (d->lock_fd >= 0) {
        flock(d->lock_fd, LOCK_UN);
        close(d->lock_fd);
        d->lock_fd = -1;
    }
    d->receiver = -1;
    d->opened = false;
    d->have_channel = false;
}

bool spawn_pipeline(Driver* d, const char* channel, bool decode) {
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
        snprintf(receiver, sizeof receiver, "%d", d->receiver);
        setenv("PX4_DEVICE", d->serial, 1);
        setenv("PX4_RECEIVER", receiver, 1);
        setenv("PX4_MODEL", d->model != nullptr ? d->model->key : "", 1);
        setenv("PX4_RUNTIME_DIR", "/run/px4-userland", 0);
        execl("/usr/local/bin/px4-ts-stream", "px4-ts-stream", channel, nullptr);
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
            execl("/usr/bin/recisdb", "recisdb", "decode", "--input", "-", "-", nullptr);
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

#ifdef PX4_BONDRIVER_SATELLITE
BOOL tune(Driver* d, DWORD space, DWORD channel) {
    std::unique_lock<std::mutex> lock(d->mu);
    if (!d->opened || space >= kSpaceCount || channel >= static_cast<DWORD>(kChannelCount)) {
        return 0;
    }
    char name[16];
    if (space == 0) {
        if (channel >= kBsCount) {
            return 0;
        }
        int tp = 1 + 2 * static_cast<int>(channel / kBsSlots);
        int slot = static_cast<int>(channel % kBsSlots);
        snprintf(name, sizeof name, "BS%02d_%d", tp, slot);
    } else {
        if (channel >= kCsCount) {
            return 0;
        }
        snprintf(name, sizeof name, "CS%d", 2 + 2 * static_cast<int>(channel));
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
#else
BOOL tune(Driver* d, int physical) {
    std::unique_lock<std::mutex> lock(d->mu);
    if (!d->opened || physical < kFirstPhysical || physical > kLastPhysical) {
        return 0;
    }
    stop_pipeline(d, lock);
    char channel[8];
    snprintf(channel, sizeof channel, "T%d", physical);
    if (!spawn_pipeline(d, channel, want_decode())) {
        return 0;
    }
    d->cv.wait_for(lock, std::chrono::seconds(4), [&] { return d->got_bytes || d->stop; });
    if (!d->got_bytes) {
        stop_pipeline(d, lock);
        return 0;
    }
    d->channel = static_cast<DWORD>(physical - kFirstPhysical);
    d->have_channel = true;
    return 1;
}
#endif

#ifdef PX4_BONDRIVER_SATELLITE
BOOL set_channel_byte(void* p, BYTE ch) {
    (void)p;
    (void)ch;
    return 0;
}
#else
BOOL set_channel_byte(void* p, BYTE ch) {
    int physical = ch;
    if (physical < kFirstPhysical && physical < kChannelCount) {
        physical = kFirstPhysical + physical;
    }
    return tune(driver(p), physical);
}
#endif

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
    if (space >= kSpaceCount) {
        return nullptr;
    }
    return driver(p)->space_names[space];
}

const uint16_t* enum_channel(void* p, DWORD space, DWORD channel) {
    if (space >= kSpaceCount) {
        return nullptr;
    }
#ifdef PX4_BONDRIVER_SATELLITE
    if (space == 0) {
        if (channel >= kBsCount) {
            return nullptr;
        }
        return driver(p)->names[channel];
    }
    if (channel >= kCsCount) {
        return nullptr;
    }
    return driver(p)->names[kBsCount + channel];
#else
    if (channel >= kChannelCount) {
        return nullptr;
    }
    return driver(p)->names[channel];
#endif
}

BOOL set_channel(void* p, DWORD space, DWORD channel) {
    Driver* d = driver(p);
#ifdef PX4_BONDRIVER_SATELLITE
    return tune(d, space, channel);
#else
    if (space != 0 || channel >= static_cast<DWORD>(kChannelCount)) {
        return 0;
    }
    BOOL ok = tune(d, kFirstPhysical + static_cast<int>(channel));
    if (ok) {
        std::lock_guard<std::mutex> guard(d->mu);
        d->space = space;
        d->channel = channel;
    }
    return ok;
#endif
}

DWORD cur_space(void* p) { return driver(p)->space; }

DWORD cur_channel(void* p) { return driver(p)->channel; }

Driver g_driver;
Bon2 g_bon;

}  // namespace

extern "C" const Bon1* CreateBonStruct(void) {
    static int ready = 0;
    if (!ready) {
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
