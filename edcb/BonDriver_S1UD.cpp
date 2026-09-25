// PX-S1UD を EDCB の BonDriver として開く。
// siano-ts の出力を recisdb に通し、STRUCT_IBONDRIVER2 で返す。
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

constexpr int kFirstPhysical = 13;
constexpr int kLastPhysical = 62;
constexpr int kChannelCount = kLastPhysical - kFirstPhysical + 1;
constexpr size_t kBufferCap = 8 * 1024 * 1024;

struct Driver {
    std::mutex mu;
    std::condition_variable cv;
    int adapter = -1;
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
    uint16_t space_name[8] = {0x5730, 0x4E0A, 0x6CE2, 0};
};

Driver* driver(void* p) { return static_cast<Driver*>(p); }

void store_ascii(uint16_t* dst, const char* src) {
    while (*src) {
        *dst++ = static_cast<uint16_t>(*src++);
    }
    *dst = 0;
}

void init_names(Driver* d) {
    store_ascii(d->tuner_name, "PX-S1UD");
    for (int i = 0; i < kChannelCount; i++) {
        char text[8];
        snprintf(text, sizeof text, "T%d", kFirstPhysical + i);
        store_ascii(d->names[i], text);
    }
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
                d->buffer.erase(d->buffer.begin(), d->buffer.begin() + static_cast<std::ptrdiff_t>(drop));
            }
        }
        d->buffer.insert(d->buffer.end(), tmp, tmp + n);
        d->cv.notify_all();
    }
}

int claim_adapter(Driver* d) {
    mkdir("/run/edcb-s1ud", 0755);
    for (int adapter = 0; adapter < 8; adapter++) {
        char path[64];
        snprintf(path, sizeof path, "/run/edcb-s1ud/%d.lock", adapter);
        int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
        if (fd < 0) {
            continue;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            d->lock_fd = fd;
            d->adapter = adapter;
            return adapter;
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
    if (claim_adapter(d) < 0) {
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
    d->adapter = -1;
    d->opened = false;
    d->have_channel = false;
}

bool spawn_pipeline(Driver* d, const char* channel) {
    int to_decode[2] = {-1, -1};
    int from_decode[2] = {-1, -1};
    if (pipe(to_decode) != 0 || pipe(from_decode) != 0) {
        return false;
    }
    pid_t stream = fork();
    if (stream < 0) {
        return false;
    }
    if (stream == 0) {
        dup2(to_decode[1], STDOUT_FILENO);
        close(to_decode[0]);
        close(to_decode[1]);
        close(from_decode[0]);
        close(from_decode[1]);
        char adapter[16];
        snprintf(adapter, sizeof adapter, "%d", d->adapter);
        setenv("PX_S1UD_ADAPTER", adapter, 1);
        setenv("PX_S1UD_FIRMWARE", "/lib/firmware/isdbt_rio.inp", 0);
        execl("/usr/local/bin/px-s1ud-stream", "px-s1ud-stream", channel, nullptr);
        _exit(127);
    }
    pid_t decode = fork();
    if (decode < 0) {
        kill_pid(stream);
        return false;
    }
    if (decode == 0) {
        dup2(to_decode[0], STDIN_FILENO);
        dup2(from_decode[1], STDOUT_FILENO);
        close(to_decode[0]);
        close(to_decode[1]);
        close(from_decode[0]);
        close(from_decode[1]);
        execl("/usr/bin/recisdb", "recisdb", "decode", "--input", "-", "-", nullptr);
        _exit(127);
    }
    close(to_decode[0]);
    close(to_decode[1]);
    close(from_decode[1]);
    d->stream_pid = stream;
    d->decode_pid = decode;
    d->read_fd = from_decode[0];
    d->stop = false;
    d->reader = std::thread(reader_main, d, d->read_fd);
    return true;
}

BOOL tune(Driver* d, int physical) {
    std::unique_lock<std::mutex> lock(d->mu);
    if (!d->opened || physical < kFirstPhysical || physical > kLastPhysical) {
        return 0;
    }
    stop_pipeline(d, lock);
    char channel[8];
    snprintf(channel, sizeof channel, "T%d", physical);
    if (!spawn_pipeline(d, channel)) {
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

BOOL set_channel_byte(void* p, BYTE ch) {
    int physical = ch;
    if (physical < kFirstPhysical && physical < kChannelCount) {
        physical = kFirstPhysical + physical;
    }
    return tune(driver(p), physical);
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
        d->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return !d->buffer.empty(); });
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
    if (space != 0) {
        return nullptr;
    }
    return driver(p)->space_name;
}

const uint16_t* enum_channel(void* p, DWORD space, DWORD channel) {
    if (space != 0 || channel >= kChannelCount) {
        return nullptr;
    }
    return driver(p)->names[channel];
}

BOOL set_channel(void* p, DWORD space, DWORD channel) {
    if (space != 0 || channel >= static_cast<DWORD>(kChannelCount)) {
        return 0;
    }
    Driver* d = driver(p);
    BOOL ok = tune(d, kFirstPhysical + static_cast<int>(channel));
    if (ok) {
        std::lock_guard<std::mutex> guard(d->mu);
        d->space = space;
        d->channel = channel;
    }
    return ok;
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
