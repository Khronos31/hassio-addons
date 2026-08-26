/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * User-space RIO transport, based on the framing and control flow in
 * smsusb_onresponse(), smscore_load_firmware_family2(), and
 * smsdvb_isdbt_set_frontend() from the Linux Siano driver.
 */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#if !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif

#include "protocol.h"

#ifdef _WIN32
#include "siano-os.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <libusb.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef _WIN32
#include <getopt.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#if !defined(_WIN32) && defined(LIBUSB_API_VERSION) && (LIBUSB_API_VERSION >= 0x01000107)
#define SIANO_HAVE_WRAP_SYS_DEVICE 1
#endif

#ifndef O_BINARY
#define O_BINARY 0
#endif

/* 32 x 16KiB ≈ 250ms of 17Mbps in flight. Kernel smsusb uses 10 x 8KiB. */
#define MAX_URBS 32U
#define USB_TRANSFER_SIZE 16384U
#define TS_QUEUE_SLOTS 256U
#define CONTROL_TIMEOUT_MS 10000U
#define LOCK_TIMEOUT_MS 10000U
#define EVENT_THREAD_PRIORITY 20
#define WRITER_THREAD_PRIORITY 10

/* Darwin condvars are CLOCK_REALTIME and lack pthread_condattr_setclock. */
#ifndef SIANO_COND_CLOCK
#if defined(__APPLE__)
#define SIANO_COND_CLOCK CLOCK_REALTIME
#else
#define SIANO_COND_CLOCK CLOCK_MONOTONIC
#endif
#endif

#ifdef _WIN32
static volatile int stop_requested;
#else
static volatile sig_atomic_t stop_requested;
#endif

struct ts_chunk {
    size_t length;
    uint8_t data[USB_TRANSFER_SIZE];
};

struct ts_queue {
    pthread_mutex_t mutex;
    pthread_cond_t available;
    struct ts_chunk chunks[TS_QUEUE_SLOTS];
    size_t head;
    size_t tail;
    size_t count;
    uint64_t drops;
    bool closed;
};

struct version_info {
    uint8_t firmware_id;
    uint8_t supported_protocols;
    uint16_t firmware_version;
};

struct siano_device {
    libusb_context *usb;
    libusb_device_handle *handle;
    int interface_number;
    uint8_t in_ep;
    uint8_t tx_ep;
    int response_alignment;
    int verbose;

    pthread_t event_thread;
    bool event_thread_started;
    pthread_mutex_t state_mutex;
    pthread_cond_t state_changed;
    bool stopping;
    int active_transfers;
    int event_error;
    struct libusb_transfer *transfers[MAX_URBS];
    uint8_t *transfer_buffers[MAX_URBS];

    pthread_mutex_t response_mutex;
    pthread_cond_t response_changed;
    unsigned response_count[1024];
    struct version_info version;
    bool locked;

    struct ts_queue ts;
};

struct options {
    bool list;
    bool verbose;
    int device_index;
    int device_fd;
    int duration;
    bool have_channel;
    unsigned channel;
    bool have_frequency;
    uint32_t frequency;
    char *firmware;
    char *output;
    uint16_t pids[64];
    size_t pid_count;
};

static void on_signal(int signo)
{
    (void)signo;
    stop_requested = 1;
}

static void usage(FILE *stream, const char *program)
{
    fprintf(stream,
            "Usage: %s [options]\n"
            "  -c, --channel N       ISDB-T physical channel (13..62)\n"
            "  -f, --freq HZ         tune frequency in Hz\n"
            "  -t, --time SECONDS    stop after duration (default: until SIGINT)\n"
            "      --firmware PATH   isdbt_rio.inp\n"
            "      --device N        RIO device index\n"
            "      --fd FD           use an already-open USB fd (Termux/Android)\n"
            "      --pid PID         add PID filter (repeatable)\n"
            "  -o, --output PATH     write TS to PATH instead of stdout\n"
            "  -v, --verbose         log control message types\n"
            "  -l, --list            list Siano USB devices without opening them\n"
            "  -h, --help            show this help\n"
            "A leftover integer argument is treated as --fd (termux-usb -e).\n",
            program);
}

static int parse_unsigned(const char *text, unsigned long max, unsigned long *value)
{
    char *end;
    unsigned long parsed;

    errno = 0;
    parsed = strtoul(text, &end, 0);
    if (errno || end == text || *end != '\0' || parsed > max)
        return -EINVAL;
    *value = parsed;
    return 0;
}

static int apply_option(int option, const char *value_text, struct options *options,
                        const char *program)
{
    unsigned long value;

    switch (option) {
    case 'c':
        if (parse_unsigned(value_text, 62, &value) < 0 || value < 13)
            return -EINVAL;
        options->channel = (unsigned)value;
        options->have_channel = true;
        return 0;
    case 'f':
        if (parse_unsigned(value_text, UINT32_MAX, &value) < 0 || value == 0)
            return -EINVAL;
        options->frequency = (uint32_t)value;
        options->have_frequency = true;
        return 0;
    case 't':
        if (parse_unsigned(value_text, INT_MAX, &value) < 0)
            return -EINVAL;
        options->duration = (int)value;
        return 0;
    case 'F':
        options->firmware = (char *)value_text;
        return 0;
    case 'd':
        if (parse_unsigned(value_text, INT_MAX, &value) < 0)
            return -EINVAL;
        options->device_index = (int)value;
        return 0;
    case 1:
        if (parse_unsigned(value_text, INT_MAX, &value) < 0)
            return -EINVAL;
        options->device_fd = (int)value;
        return 0;
    case 'p':
        if (options->pid_count == sizeof(options->pids) / sizeof(options->pids[0]) ||
            parse_unsigned(value_text, 0x2000, &value) < 0)
            return -EINVAL;
        options->pids[options->pid_count++] = (uint16_t)value;
        return 0;
    case 'o':
        options->output = (char *)value_text;
        return 0;
    case 'v':
        options->verbose = true;
        return 0;
    case 'l':
        options->list = true;
        return 0;
    case 'h':
        usage(stdout, program);
        fflush(stdout);
        exit(0);
    default:
        return -EINVAL;
    }
}

static int finish_options(int argc, char **argv, int leftover, struct options *options)
{
    if (leftover < argc) {
        unsigned long fd_value;

        if (leftover + 1 != argc ||
            parse_unsigned(argv[leftover], INT_MAX, &fd_value) < 0)
            return -EINVAL;
        if (options->device_fd >= 0 && options->device_fd != (int)fd_value)
            return -EINVAL;
        options->device_fd = (int)fd_value;
    }
    if (options->have_channel && options->have_frequency)
        return -EINVAL;
    if (options->list && options->device_fd >= 0)
        return -EINVAL;
    if (options->device_fd >= 0 && options->device_index != 0)
        return -EINVAL;
    if (!options->list && !options->have_channel && !options->have_frequency)
        return -EINVAL;
    return 0;
}

static int parse_options(int argc, char **argv, struct options *options)
{
    static const struct option long_options[] = {
        {"channel", required_argument, NULL, 'c'},
        {"freq", required_argument, NULL, 'f'},
        {"time", required_argument, NULL, 't'},
        {"firmware", required_argument, NULL, 'F'},
        {"device", required_argument, NULL, 'd'},
        {"fd", required_argument, NULL, 1},
        {"pid", required_argument, NULL, 'p'},
        {"output", required_argument, NULL, 'o'},
        {"verbose", no_argument, NULL, 'v'},
        {"list", no_argument, NULL, 'l'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0}
    };

    memset(options, 0, sizeof(*options));
    options->device_index = 0;
    options->device_fd = -1;
#ifdef _WIN32
    {
        int i = 1;

        while (i < argc) {
            const char *a = argv[i];
            const char *value = NULL;
            int option = 0;
            int needs_value = 0;
            size_t n;

            if (a[0] != '-')
                break;
            i++;
            if (a[1] == '-' && a[2] == '\0')
                break;
            if (a[1] == '-') {
                const char *name = a + 2;
                const char *eq = strchr(name, '=');
                size_t namelen = eq ? (size_t)(eq - name) : strlen(name);

                for (n = 0; long_options[n].name; n++) {
                    if (strncmp(long_options[n].name, name, namelen) != 0 ||
                        long_options[n].name[namelen] != '\0')
                        continue;
                    option = long_options[n].val;
                    needs_value = long_options[n].has_arg == required_argument;
                    break;
                }
                if (!option)
                    return -EINVAL;
                if (needs_value) {
                    if (eq)
                        value = eq + 1;
                    else if (i < argc)
                        value = argv[i++];
                    else
                        return -EINVAL;
                }
            } else {
                option = a[1];
                needs_value = (option == 'c' || option == 'f' || option == 't' ||
                               option == 'F' || option == 'd' || option == 'p' ||
                               option == 'o');
                if (a[2] != '\0' && needs_value)
                    value = a + 2;
                else if (needs_value) {
                    if (i < argc)
                        value = argv[i++];
                    else
                        return -EINVAL;
                }
            }
            if (apply_option(option, value, options, argv[0]) < 0)
                return -EINVAL;
        }
        return finish_options(argc, argv, i, options);
    }
#else
    {
        int option;

        while ((option = getopt_long(argc, argv, "c:f:t:F:d:p:o:vlh", long_options,
                                     NULL)) != -1) {
            if (apply_option(option, optarg, options, argv[0]) < 0)
                return -EINVAL;
        }
        return finish_options(argc, argv, optind, options);
    }
#endif
}

static bool is_rio_id(uint16_t vendor, uint16_t product)
{
    return (vendor == 0x3275 && product == 0x0080) ||
           (vendor == 0x187f && product == 0x0600) ||
           (vendor == 0x187f && product == 0x0302);
}

static const char *device_name(uint16_t vendor, uint16_t product, bool *supported)
{
    *supported = is_rio_id(vendor, product);
    if (*supported)
        return "Siano Rio (ISDB-T)";
    if (vendor == 0x187f) {
        switch (product) {
        case 0x0010: return "Siano Stellar ROM (unsupported)";
        case 0x0100: return "Siano Stellar (unsupported)";
        case 0x0200: return "Siano Nova A (unsupported)";
        case 0x0201: return "Siano Nova B (unsupported)";
        case 0x0300: return "Siano Vega (unsupported)";
        case 0x0301: return "Siano Venice (unsupported)";
        case 0x0310: return "Siano Ming (unsupported)";
        case 0x0500: return "Siano Pele (unsupported)";
        case 0x0700: return "Siano Denver 2160 (unsupported)";
        case 0x0800: return "Siano Denver 1530 (unsupported)";
        default: return "Siano device (unsupported)";
        }
    }
    return "USB device";
}

static int list_devices(libusb_context *usb)
{
    libusb_device **list;
    ssize_t count;
    size_t rio_count = 0;
    size_t known_count = 0;

    count = libusb_get_device_list(usb, &list);
    if (count < 0) {
        fprintf(stderr, "libusb_get_device_list: %s\n", libusb_strerror((int)count));
        return 1;
    }
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor descriptor;
        bool supported;
        const char *name;

        if (libusb_get_device_descriptor(list[i], &descriptor) < 0)
            continue;
        name = device_name(descriptor.idVendor, descriptor.idProduct, &supported);
        if (descriptor.idVendor != 0x187f && descriptor.idVendor != 0x3275)
            continue;
        known_count++;
        if (supported) {
            printf("%zu: %04x:%04x %s\n", rio_count, descriptor.idVendor,
                   descriptor.idProduct, name);
            rio_count++;
        } else {
            printf("-: %04x:%04x %s\n", descriptor.idVendor,
                   descriptor.idProduct, name);
        }
    }
    libusb_free_device_list(list, 1);
    if (known_count == 0)
        printf("0 devices\n");
    else
        printf("%zu supported RIO device(s), %zu known Siano device(s)\n",
               rio_count, known_count);
    return 0;
}

static int resolve_firmware(const char *requested, char **path)
{
    static const char *const defaults[] = {
        "./firmware/isdbt_rio.inp",
        "isdbt_rio.inp",
#ifndef _WIN32
        "/lib/firmware/isdbt_rio.inp",
#endif
    };

    if (requested) {
        if (access(requested, R_OK) < 0) {
            fprintf(stderr, "firmware '%s': %s\n", requested, strerror(errno));
            return -ENOENT;
        }
        *path = strdup(requested);
        return *path ? 0 : -ENOMEM;
    }
    for (size_t i = 0; i < sizeof(defaults) / sizeof(defaults[0]); i++) {
        if (access(defaults[i], R_OK) == 0) {
            *path = strdup(defaults[i]);
            return *path ? 0 : -ENOMEM;
        }
    }
    fprintf(stderr, "firmware 'isdbt_rio.inp' not found; use --firmware PATH\n");
    return -ENOENT;
}

static int cond_init_waitable(pthread_cond_t *cond)
{
#ifdef _WIN32
    return pthread_cond_init(cond, NULL) == 0 ? 0 : -1;
#else
    pthread_condattr_t attr;

    if (pthread_condattr_init(&attr) != 0)
        return -1;
#if !defined(__APPLE__)
    if (pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) != 0) {
        pthread_condattr_destroy(&attr);
        return -1;
    }
#endif
    if (pthread_cond_init(cond, &attr) != 0) {
        pthread_condattr_destroy(&attr);
        return -1;
    }
    pthread_condattr_destroy(&attr);
    return 0;
#endif
}

static void cond_deadline_from_now(struct timespec *deadline, unsigned extra_ms)
{
    clock_gettime(SIANO_COND_CLOCK, deadline);
    deadline->tv_sec += extra_ms / 1000U;
    deadline->tv_nsec += (long)(extra_ms % 1000U) * 1000000L;
    if (deadline->tv_nsec >= 1000000000L) {
        deadline->tv_sec++;
        deadline->tv_nsec -= 1000000000L;
    }
}

static int ts_queue_init(struct ts_queue *queue)
{
    if (pthread_mutex_init(&queue->mutex, NULL) != 0)
        return -1;
    if (cond_init_waitable(&queue->available) != 0) {
        pthread_mutex_destroy(&queue->mutex);
        return -1;
    }
    return 0;
}

static void ts_queue_close(struct ts_queue *queue)
{
    pthread_mutex_lock(&queue->mutex);
    queue->closed = true;
    pthread_cond_broadcast(&queue->available);
    pthread_mutex_unlock(&queue->mutex);
}

static void ts_queue_destroy(struct ts_queue *queue)
{
    pthread_cond_destroy(&queue->available);
    pthread_mutex_destroy(&queue->mutex);
}

static void try_realtime(pthread_t thread, int priority, const char *name)
{
#ifdef SCHED_FIFO
    struct sched_param param;

    memset(&param, 0, sizeof(param));
    param.sched_priority = priority;
    if (pthread_setschedparam(thread, SCHED_FIFO, &param) != 0)
        fprintf(stderr, "%s SCHED_FIFO %d: %s (continuing)\n",
                name, priority, strerror(errno));
    else
        fprintf(stderr, "%s running SCHED_FIFO %d\n", name, priority);
#else
    (void)thread;
    (void)priority;
    (void)name;
#endif
}

static void try_lock_pages(void)
{
#ifdef MCL_CURRENT
    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0)
        fprintf(stderr, "mlockall: %s (continuing)\n", strerror(errno));
    else
        fprintf(stderr, "address space locked\n");
#endif
}

static void ts_enqueue(struct ts_queue *queue, const uint8_t *data, size_t length)
{
    pthread_mutex_lock(&queue->mutex);
    if (queue->closed || queue->count == TS_QUEUE_SLOTS) {
        queue->drops++;
        pthread_mutex_unlock(&queue->mutex);
        return;
    }
    if (length > sizeof(queue->chunks[queue->tail].data))
        length = sizeof(queue->chunks[queue->tail].data);
    memcpy(queue->chunks[queue->tail].data, data, length);
    queue->chunks[queue->tail].length = length;
    queue->tail = (queue->tail + 1) % TS_QUEUE_SLOTS;
    queue->count++;
    pthread_cond_signal(&queue->available);
    pthread_mutex_unlock(&queue->mutex);
}

static int ts_pop(struct ts_queue *queue, uint8_t *data, size_t *length)
{
    struct timespec deadline;
    int rc = 0;

    cond_deadline_from_now(&deadline, 100);
    pthread_mutex_lock(&queue->mutex);
    while (queue->count == 0 && !queue->closed && !stop_requested) {
        rc = pthread_cond_timedwait(&queue->available, &queue->mutex, &deadline);
        if (rc == ETIMEDOUT)
            break;
    }
    if (queue->count != 0) {
        struct ts_chunk *chunk = &queue->chunks[queue->head];
        memcpy(data, chunk->data, chunk->length);
        *length = chunk->length;
        queue->head = (queue->head + 1) % TS_QUEUE_SLOTS;
        queue->count--;
        rc = 0;
    } else {
        rc = -EAGAIN;
    }
    pthread_mutex_unlock(&queue->mutex);
    return rc;
}

static void response_note(struct siano_device *device, uint16_t type,
                          const uint8_t *payload, size_t payload_length)
{
    pthread_mutex_lock(&device->response_mutex);
    if (type < sizeof(device->response_count) / sizeof(device->response_count[0]))
        device->response_count[type]++;

    if (type == MSG_SMS_GET_VERSION_EX_RES && payload_length >= 12) {
        /* smscore_onresponse() uses rom_ver_major/minor as fw_version. */
        device->version.firmware_id = payload[4];
        device->version.supported_protocols = payload[5];
        device->version.firmware_version = ((uint16_t)payload[10] << 8) | payload[11];
        if (device->verbose) {
            fprintf(stderr,
                    "version payload: chip=%04x fw_id=%u proto=0x%02x app=%u.%u.%u rom=%u.%u\n",
                    sms_get_le16(payload), payload[4], payload[5],
                    payload[6], payload[7], payload[8], payload[10], payload[11]);
        }
    } else if ((type == MSG_SMS_GET_STATISTICS_EX_RES && payload_length >= 20) ||
               (type == MSG_SMS_GET_STATISTICS_RES && payload_length >= 16)) {
        size_t demod_offset = type == MSG_SMS_GET_STATISTICS_EX_RES ? 16 : 12;
        if (sms_get_le32(payload + demod_offset) != 0)
            device->locked = true;
    } else if (type == MSG_SMS_SIGNAL_DETECTED_IND) {
        device->locked = true;
    } else if (type == MSG_SMS_NO_SIGNAL_IND) {
        device->locked = false;
    }
    pthread_cond_broadcast(&device->response_changed);
    pthread_mutex_unlock(&device->response_mutex);
}

static void handle_received_buffer(struct siano_device *device,
                                   const uint8_t *buffer, size_t actual_length)
{
    struct sms_frame frame;
    int rc;

    rc = sms_frame_message(buffer, actual_length, (size_t)device->response_alignment,
                           &frame);
    if (rc < 0) {
        if (device->verbose)
            fprintf(stderr, "invalid RX frame: %s (%zu bytes)\n",
                    strerror(-rc), actual_length);
        return;
    }
    if (device->verbose && frame.type != MSG_SMS_DVBT_BDA_DATA)
        fprintf(stderr, "RX %s(%u) length=%u\n", sms_message_type_name(frame.type),
                frame.type, frame.length);
    if (frame.type == MSG_SMS_DVBT_BDA_DATA) {
        ts_enqueue(&device->ts, buffer + frame.payload_offset, frame.payload_length);
    } else {
        response_note(device, frame.type, buffer + frame.payload_offset,
                      frame.payload_length);
    }
}

static void transfer_callback(struct libusb_transfer *transfer)
{
    struct siano_device *device = transfer->user_data;
    bool resubmit;

    pthread_mutex_lock(&device->state_mutex);
    if (device->active_transfers > 0)
        device->active_transfers--;
    resubmit = !device->stopping;
    pthread_mutex_unlock(&device->state_mutex);

    if (transfer->status == LIBUSB_TRANSFER_COMPLETED && transfer->actual_length > 0)
        handle_received_buffer(device, transfer->buffer,
                               (size_t)transfer->actual_length);
    else if (resubmit && transfer->status != LIBUSB_TRANSFER_TIMED_OUT)
        fprintf(stderr, "bulk IN transfer status %d\n", transfer->status);

    if (!resubmit)
        return;

    pthread_mutex_lock(&device->state_mutex);
    if (!device->stopping) {
        int rc = libusb_submit_transfer(transfer);
        if (rc == 0)
            device->active_transfers++;
        else {
            fprintf(stderr, "libusb_submit_transfer: %s\n", libusb_error_name(rc));
            device->stopping = true;
            device->event_error = rc;
        }
    }
    pthread_mutex_unlock(&device->state_mutex);
}

static void *event_thread_main(void *arg)
{
    struct siano_device *device = arg;

    for (;;) {
        bool done;
        struct timeval timeout = {.tv_sec = 0, .tv_usec = 100000};
        int rc;

        pthread_mutex_lock(&device->state_mutex);
        done = device->stopping && device->active_transfers == 0;
        pthread_mutex_unlock(&device->state_mutex);
        if (done)
            break;

        rc = libusb_handle_events_timeout(device->usb, &timeout);
        if (rc < 0 && rc != LIBUSB_ERROR_INTERRUPTED) {
            fprintf(stderr, "libusb_handle_events: %s\n", libusb_error_name(rc));
            pthread_mutex_lock(&device->state_mutex);
            device->event_error = rc;
            device->stopping = true;
            for (size_t i = 0; i < MAX_URBS; i++)
                if (device->transfers[i])
                    libusb_cancel_transfer(device->transfers[i]);
            pthread_mutex_unlock(&device->state_mutex);
        }
    }
    return NULL;
}

static int start_streaming(struct siano_device *device)
{
    int rc;

    rc = pthread_create(&device->event_thread, NULL, event_thread_main, device);
    if (rc != 0)
        return -rc;
    device->event_thread_started = true;
    try_realtime(device->event_thread, EVENT_THREAD_PRIORITY, "usb-event");
    fprintf(stderr, "USB ring %u x %u bytes\n", MAX_URBS, USB_TRANSFER_SIZE);
    for (size_t i = 0; i < MAX_URBS; i++) {
        device->transfer_buffers[i] = malloc(USB_TRANSFER_SIZE);
        device->transfers[i] = libusb_alloc_transfer(0);
        if (!device->transfer_buffers[i] || !device->transfers[i])
            return -ENOMEM;
        libusb_fill_bulk_transfer(device->transfers[i], device->handle, device->in_ep,
                                  device->transfer_buffers[i], USB_TRANSFER_SIZE,
                                  transfer_callback, device, 0);
        pthread_mutex_lock(&device->state_mutex);
        rc = libusb_submit_transfer(device->transfers[i]);
        if (rc == 0)
            device->active_transfers++;
        pthread_mutex_unlock(&device->state_mutex);
        if (rc < 0) {
            fprintf(stderr, "libusb_submit_transfer: %s\n", libusb_error_name(rc));
            return rc;
        }
    }
    return 0;
}

static void stop_streaming(struct siano_device *device)
{
    pthread_mutex_lock(&device->state_mutex);
    device->stopping = true;
    for (size_t i = 0; i < MAX_URBS; i++)
        if (device->transfers[i])
            libusb_cancel_transfer(device->transfers[i]);
    pthread_mutex_unlock(&device->state_mutex);

    if (device->event_thread_started)
        pthread_join(device->event_thread, NULL);
    for (size_t i = 0; i < MAX_URBS; i++) {
        libusb_free_transfer(device->transfers[i]);
        free(device->transfer_buffers[i]);
        device->transfers[i] = NULL;
        device->transfer_buffers[i] = NULL;
    }
}

static int wait_response(struct siano_device *device, uint16_t type,
                         unsigned timeout_ms)
{
    struct timespec deadline;
    int rc = 0;

    cond_deadline_from_now(&deadline, timeout_ms);
    pthread_mutex_lock(&device->response_mutex);
    while (device->response_count[type] == 0 && !stop_requested) {
        rc = pthread_cond_timedwait(&device->response_changed,
                                    &device->response_mutex, &deadline);
        if (rc == ETIMEDOUT)
            break;
    }
    if (device->response_count[type] != 0) {
        device->response_count[type]--;
        rc = 0;
    } else if (stop_requested) {
        rc = EINTR;
    } else if (rc == ETIMEDOUT) {
        rc = ETIMEDOUT;
    } else {
        rc = EIO;
    }
    pthread_mutex_unlock(&device->response_mutex);
    return rc == 0 ? 0 : -rc;
}

static void clear_response(struct siano_device *device, uint16_t type)
{
    pthread_mutex_lock(&device->response_mutex);
    device->response_count[type] = 0;
    pthread_mutex_unlock(&device->response_mutex);
}

static int send_message(struct siano_device *device, const uint8_t *message,
                        size_t length)
{
    int transferred = 0;
    int rc;
    uint16_t type = sms_get_le16(message);

    if (device->verbose)
        fprintf(stderr, "TX %s(%u) length=%zu\n", sms_message_type_name(type),
                type, length);
    rc = libusb_bulk_transfer(device->handle, device->tx_ep,
                              (unsigned char *)message, (int)length,
                              &transferred, 1000);
    if (rc < 0)
        fprintf(stderr, "bulk OUT: %s\n", libusb_error_name(rc));
    else if ((size_t)transferred != length)
        rc = LIBUSB_ERROR_IO;
    return rc;
}

static int send_and_wait(struct siano_device *device, const uint8_t *message,
                         size_t length, uint16_t response_type)
{
    int rc;

    clear_response(device, response_type);
    rc = send_message(device, message, length);
    if (rc < 0)
        return rc;
    rc = wait_response(device, response_type, CONTROL_TIMEOUT_MS);
    if (rc < 0)
        fprintf(stderr, "waiting for %s: %s\n", sms_message_type_name(response_type),
                strerror(-rc));
    return rc;
}

static int get_version(struct siano_device *device)
{
    uint8_t message[SMS_HEADER_SIZE];

    sms_pack_header(message, MSG_SMS_GET_VERSION_EX_REQ, 0, SMS_HIF_TASK,
                    SMS_HEADER_SIZE, 0);
    return send_and_wait(device, message, sizeof(message),
                         MSG_SMS_GET_VERSION_EX_RES);
}

static int read_file(const char *path, uint8_t **data, size_t *size)
{
    FILE *file;
    long file_size;
    uint8_t *buffer;

    file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "firmware '%s': %s\n", path, strerror(errno));
        return -errno;
    }
    if (fseek(file, 0, SEEK_END) < 0 || (file_size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET) < 0 || (uintmax_t)file_size > SIZE_MAX) {
        fclose(file);
        return -EIO;
    }
    buffer = malloc((size_t)file_size);
    if (!buffer) {
        fclose(file);
        return -ENOMEM;
    }
    if (fread(buffer, 1, (size_t)file_size, file) != (size_t)file_size) {
        free(buffer);
        fclose(file);
        return -EIO;
    }
    fclose(file);
    *data = buffer;
    *size = (size_t)file_size;
    return 0;
}

static uint32_t firmware_checksum(const uint8_t *payload, size_t length)
{
    uint32_t checksum = 0;

    for (size_t i = 0; i + 4 <= length; i += 4)
        checksum += sms_get_le32(payload + i);
    return checksum;
}

static int load_family2_firmware(struct siano_device *device, const char *path,
                                 int current_mode)
{
    uint8_t *file_data = NULL;
    uint8_t *wire_payload = NULL;
    size_t file_size = 0;
    struct sms_firmware_header header;
    uint32_t address;
    int rc;

    rc = read_file(path, &file_data, &file_size);
    if (rc < 0)
        return rc;
    rc = sms_parse_firmware_header(file_data, file_size, &header);
    if (rc < 0) {
        fprintf(stderr, "invalid firmware header in '%s': %s\n", path,
                strerror(-rc));
        free(file_data);
        return rc;
    }
    fprintf(stderr, "firmware: checksum=0x%08x length=%u start=0x%08x\n",
            header.check_sum, header.length, header.start_address);

    /* smscore_load_firmware_family2() passes the complete file size as size.
     * Preserve that wire length; the final 12 bytes are outside the payload
     * described by the header and are zero-padded here for deterministic I/O. */
    wire_payload = calloc(1, file_size);
    if (!wire_payload) {
        free(file_data);
        return -ENOMEM;
    }
    memcpy(wire_payload, file_data + 12, header.length);
    address = header.start_address;

    if (current_mode != DEVICE_MODE_NONE) {
        uint8_t message[SMS_HEADER_SIZE];

        sms_pack_header(message, MSG_SW_RELOAD_START_REQ, 0, SMS_HIF_TASK,
                        SMS_HEADER_SIZE, 0);
        rc = send_and_wait(device, message, sizeof(message), MSG_SW_RELOAD_START_RES);
        if (rc < 0)
            goto out;
        /* smscore_load_firmware_family2() deliberately takes payload[20]
         * from the firmware image when reloading an already-running mode. */
        if (header.length < 24) {
            rc = -EBADMSG;
            goto out;
        }
        address = sms_get_le32(wire_payload + 20);
    }

    fprintf(stderr, "firmware: checksum(sum32)=0x%08x, downloading %zu bytes\n",
            firmware_checksum(wire_payload, header.length), file_size);
    for (size_t offset = 0; offset < file_size; ) {
        uint8_t message[SMS_MAX_MESSAGE_SIZE];
        size_t chunk = file_size - offset;
        if (chunk > SMS_MAX_PAYLOAD_SIZE)
            chunk = SMS_MAX_PAYLOAD_SIZE;
        sms_pack_header(message, MSG_SMS_DATA_DOWNLOAD_REQ, 0, SMS_HIF_TASK,
                        (uint16_t)(SMS_HEADER_SIZE + 4U + chunk), 0);
        sms_put_le32(message + SMS_HEADER_SIZE, address);
        memcpy(message + SMS_HEADER_SIZE + 4U, wire_payload + offset, chunk);
        rc = send_and_wait(device, message, SMS_HEADER_SIZE + 4U + chunk,
                           MSG_SMS_DATA_DOWNLOAD_RES);
        if (rc < 0)
            goto out;
        offset += chunk;
        address += (uint32_t)chunk;
    }

    {
        uint8_t message[SMS_HEADER_SIZE + 12U];

        sms_pack_header(message, MSG_SMS_DATA_VALIDITY_REQ, 0, SMS_HIF_TASK,
                        sizeof(message), 0);
        sms_put_le32(message + SMS_HEADER_SIZE + 0, header.start_address);
        sms_put_le32(message + SMS_HEADER_SIZE + 4, header.length);
        sms_put_le32(message + SMS_HEADER_SIZE + 8, 0); /* regular checksum */
        rc = send_and_wait(device, message, sizeof(message),
                           MSG_SMS_DATA_VALIDITY_RES);
        if (rc < 0)
            goto out;
    }

    if (current_mode == DEVICE_MODE_NONE) {
        uint8_t message[SMS_HEADER_SIZE + 20U];

        sms_pack_header(message, MSG_SMS_SWDOWNLOAD_TRIGGER_REQ, 0, SMS_HIF_TASK,
                        sizeof(message), 0);
        sms_put_le32(message + SMS_HEADER_SIZE + 0, header.start_address);
        sms_put_le32(message + SMS_HEADER_SIZE + 4, 6);
        sms_put_le32(message + SMS_HEADER_SIZE + 8, 0x200);
        sms_put_le32(message + SMS_HEADER_SIZE + 12, 0);
        sms_put_le32(message + SMS_HEADER_SIZE + 16, 4);
        rc = send_and_wait(device, message, sizeof(message),
                           MSG_SMS_SWDOWNLOAD_TRIGGER_RES);
    } else {
        uint8_t message[SMS_HEADER_SIZE];

        sms_pack_header(message, MSG_SW_RELOAD_EXEC_REQ, 0, SMS_HIF_TASK,
                        sizeof(message), 0);
        rc = send_message(device, message, sizeof(message));
    }
    if (rc < 0)
        goto out;
    {
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 400000000L};
        nanosleep(&delay, NULL);
    }
out:
    free(wire_payload);
    free(file_data);
    return rc;
}

static int set_device_mode(struct siano_device *device, const char *firmware)
{
    int current_mode;
    int rc;

    rc = get_version(device);
    if (rc < 0)
        return rc;
    current_mode = device->version.firmware_id == 255 ? DEVICE_MODE_NONE :
                   device->version.firmware_id;
    fprintf(stderr, "firmware mode=%d supported=0x%02x fw=%u.%u\n",
            current_mode, device->version.supported_protocols,
            device->version.firmware_version >> 8,
            device->version.firmware_version & 0xff);
    /* smscore_set_device_mode() returns immediately when the running mode
     * already matches. Re-sending INIT_DEVICE on a warm RIO leaves HIF
     * unresponsive to the next control message (observed on PX-S1UD). */
    if (current_mode == DEVICE_MODE_ISDBT_BDA)
        return 0;
    if (!(device->version.supported_protocols & (1U << DEVICE_MODE_ISDBT_BDA))) {
        rc = load_family2_firmware(device, firmware, current_mode);
        if (rc < 0)
            return rc;
        rc = get_version(device);
        if (rc < 0)
            return rc;
        current_mode = device->version.firmware_id == 255 ? DEVICE_MODE_NONE :
                       device->version.firmware_id;
        if (current_mode == DEVICE_MODE_ISDBT_BDA)
            return 0;
    }
    if (device->version.firmware_version >= 0x800) {
        uint8_t message[SMS_HEADER_SIZE + 4U];

        sms_pack_header(message, MSG_SMS_INIT_DEVICE_REQ, 0, SMS_HIF_TASK,
                        sizeof(message), 0);
        sms_put_le32(message + SMS_HEADER_SIZE, DEVICE_MODE_ISDBT_BDA);
        rc = send_and_wait(device, message, sizeof(message), MSG_SMS_INIT_DEVICE_RES);
        if (rc < 0)
            return rc;
    }
    return 0;
}

static int add_pid(struct siano_device *device, uint16_t pid)
{
    uint8_t message[SMS_HEADER_SIZE + 4U];

    sms_pack_header(message, MSG_SMS_ADD_PID_FILTER_REQ,
                    SMS_DVBT_BDA_CONTROL_MSG_ID, SMS_HIF_TASK, sizeof(message), 0);
    sms_put_le32(message + SMS_HEADER_SIZE, pid);
    return send_and_wait(device, message, sizeof(message), MSG_SMS_ADD_PID_FILTER_RES);
}

static int tune(struct siano_device *device, uint32_t frequency)
{
    uint8_t message[SMS_HEADER_SIZE + 16U];
    struct timespec deadline;
    int rc;

    pthread_mutex_lock(&device->response_mutex);
    device->locked = false;
    pthread_mutex_unlock(&device->response_mutex);
    sms_pack_header(message, MSG_SMS_ISDBT_TUNE_REQ,
                    SMS_DVBT_BDA_CONTROL_MSG_ID, SMS_HIF_TASK, sizeof(message), 0);
    sms_put_le32(message + SMS_HEADER_SIZE + 0, frequency);
    sms_put_le32(message + SMS_HEADER_SIZE + 4, BW_ISDBT_13SEG);
    sms_put_le32(message + SMS_HEADER_SIZE + 8, 12000000U);
    sms_put_le32(message + SMS_HEADER_SIZE + 12, 0);
    rc = send_and_wait(device, message, sizeof(message), MSG_SMS_ISDBT_TUNE_RES);
    if (rc < 0)
        return rc;

    clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_sec += LOCK_TIMEOUT_MS / 1000U;
    deadline.tv_nsec += (long)(LOCK_TIMEOUT_MS % 1000U) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }
    while (!stop_requested) {
        bool locked;
        struct timespec now;
        uint8_t stats[SMS_HEADER_SIZE];
        uint16_t stats_request = device->version.firmware_version >= 0x800 ?
                                 MSG_SMS_GET_STATISTICS_EX_REQ : MSG_SMS_GET_STATISTICS_REQ;

        pthread_mutex_lock(&device->response_mutex);
        locked = device->locked;
        pthread_mutex_unlock(&device->response_mutex);
        if (locked)
            return 0;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec > deadline.tv_sec ||
            (now.tv_sec == deadline.tv_sec && now.tv_nsec >= deadline.tv_nsec))
            break;

        sms_pack_header(stats, stats_request, SMS_DVBT_BDA_CONTROL_MSG_ID,
                        SMS_HIF_TASK, sizeof(stats), 0);
        (void)send_message(device, stats, sizeof(stats));
        /* Discard a bounded amount of TS during lock wait. An unbounded
         * drain never returns once the mux is flowing. */
        {
            uint8_t discard[USB_TRANSFER_SIZE];
            size_t discard_length;
            for (int n = 0; n < 32; n++) {
                if (ts_pop(&device->ts, discard, &discard_length) != 0)
                    break;
            }
        }
        pthread_mutex_lock(&device->response_mutex);
        struct timespec short_deadline;
        cond_deadline_from_now(&short_deadline, 100);
        (void)pthread_cond_timedwait(&device->response_changed,
                                     &device->response_mutex, &short_deadline);
        pthread_mutex_unlock(&device->response_mutex);
    }
    fprintf(stderr, "ISDB-T tune response received but no demod lock\n");
    return -ETIMEDOUT;
}

static int write_all(int fd, const uint8_t *data, size_t length)
{
    while (length != 0) {
        ssize_t written = write(fd, data, length);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return -errno;
        }
        if (written == 0)
            return -EIO;
        data += written;
        length -= (size_t)written;
    }
    return 0;
}

/* URB payloads are not a multiple of 188. Emit only aligned TS packets. */
static int write_aligned_ts(int fd, uint8_t *hold, size_t *hold_len,
                            const uint8_t *data, size_t length)
{
    uint8_t scratch[USB_TRANSFER_SIZE + 188U];
    size_t n = 0;
    const uint8_t *p;

    if (*hold_len != 0) {
        memcpy(scratch, hold, *hold_len);
        memcpy(scratch + *hold_len, data, length);
        n = *hold_len + length;
        p = scratch;
        *hold_len = 0;
    } else {
        p = data;
        n = length;
    }

    while (n >= 188U) {
        if (p[0] == 0x47 && (n < 376U || p[188] == 0x47)) {
            int rc = write_all(fd, p, 188U);
            if (rc < 0)
                return rc;
            p += 188U;
            n -= 188U;
        } else {
            p++;
            n--;
        }
    }
    if (n != 0) {
        memcpy(hold, p, n);
        *hold_len = n;
    }
    return 0;
}

static int stream_ts(struct siano_device *device, int output_fd, int duration)
{
    struct timespec deadline;
    uint8_t data[USB_TRANSFER_SIZE];
    uint8_t hold[188];
    size_t hold_len = 0;

    if (duration > 0) {
        clock_gettime(CLOCK_MONOTONIC, &deadline);
        deadline.tv_sec += duration;
    }
    while (!stop_requested) {
        size_t length;
        int rc = ts_pop(&device->ts, data, &length);
        if (rc == 0) {
            rc = write_aligned_ts(output_fd, hold, &hold_len, data, length);
            if (rc < 0) {
                fprintf(stderr, "TS output: %s\n", strerror(-rc));
                return rc;
            }
        }
        if (duration > 0) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec > deadline.tv_sec ||
                (now.tv_sec == deadline.tv_sec && now.tv_nsec >= deadline.tv_nsec))
                break;
        }
    }
    return 0;
}

static int inspect_and_claim(struct siano_device *device)
{
    libusb_device *usb_device;
    struct libusb_config_descriptor *config = NULL;
    struct libusb_device_descriptor descriptor;
    bool supported;
    const char *name;
    int rc;

    usb_device = libusb_get_device(device->handle);
    rc = libusb_get_device_descriptor(usb_device, &descriptor);
    if (rc < 0) {
        fprintf(stderr, "device descriptor: %s\n", libusb_error_name(rc));
        return rc;
    }
    name = device_name(descriptor.idVendor, descriptor.idProduct, &supported);
    if (!supported) {
        fprintf(stderr, "%04x:%04x is %s\n", descriptor.idVendor,
                descriptor.idProduct, name);
        return -ENODEV;
    }
    (void)libusb_set_auto_detach_kernel_driver(device->handle, 1);
    rc = libusb_get_active_config_descriptor(usb_device, &config);
    if (rc < 0) {
        fprintf(stderr, "active USB config: %s\n", libusb_error_name(rc));
        return rc;
    }
    device->interface_number = -1;
    for (int i = 0; i < config->bNumInterfaces && device->interface_number < 0; i++) {
        const struct libusb_interface *interface = &config->interface[i];
        for (int a = 0; a < interface->num_altsetting; a++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[a];
            uint8_t in_ep = 0;
            uint8_t descriptor_out_ep = 0;
            int max_packet = 0;

            for (int e = 0; e < alt->bNumEndpoints; e++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[e];
                if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) !=
                    LIBUSB_TRANSFER_TYPE_BULK)
                    continue;
                if (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) {
                    in_ep = endpoint->bEndpointAddress;
                    max_packet = endpoint->wMaxPacketSize & 0x7ff;
                } else {
                    descriptor_out_ep = endpoint->bEndpointAddress;
                }
            }
            if (!in_ep)
                continue;
            device->interface_number = alt->bInterfaceNumber;
            device->in_ep = in_ep;
            device->response_alignment = max_packet > (int)SMS_HEADER_SIZE ?
                                          max_packet - SMS_HEADER_SIZE : 0;
            if (descriptor_out_ep != 2)
                fprintf(stderr, "warning: descriptor OUT endpoint is 0x%02x; kernel protocol uses fixed endpoint 2\n",
                        descriptor_out_ep);
            break;
        }
    }
    libusb_free_config_descriptor(config);
    if (device->interface_number < 0) {
        fprintf(stderr, "no bulk IN endpoint found\n");
        return -ENODEV;
    }
    device->tx_ep = 2; /* smsusb_sendrequest() uses usb_sndbulkpipe(..., 2). */
    rc = libusb_claim_interface(device->handle, device->interface_number);
    if (rc < 0) {
        fprintf(stderr, "libusb_claim_interface(%d): %s\n", device->interface_number,
                libusb_error_name(rc));
        return rc;
    }
    /* smsusb_probe() clears halt on both bulk endpoints before talking. */
    (void)libusb_clear_halt(device->handle, device->in_ep);
    (void)libusb_clear_halt(device->handle, device->tx_ep | LIBUSB_ENDPOINT_OUT);
    fprintf(stderr, "opened RIO %04x:%04x interface %d, IN endpoint 0x%02x, response alignment %d\n",
            descriptor.idVendor, descriptor.idProduct, device->interface_number,
            device->in_ep, device->response_alignment);
    return 0;
}

static int open_rio(struct siano_device *device, int requested_index)
{
    libusb_device **list;
    ssize_t count;
    int found = 0;
    libusb_device *selected = NULL;
    int rc;

    count = libusb_get_device_list(device->usb, &list);
    if (count < 0)
        return (int)count;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor descriptor;

        if (libusb_get_device_descriptor(list[i], &descriptor) < 0)
            continue;
        if (!is_rio_id(descriptor.idVendor, descriptor.idProduct))
            continue;
        if (found++ == requested_index) {
            selected = list[i];
            break;
        }
    }
    if (!selected) {
        fprintf(stderr, "RIO device index %d not found\n", requested_index);
        libusb_free_device_list(list, 1);
        return -ENODEV;
    }
    rc = libusb_open(selected, &device->handle);
    libusb_free_device_list(list, 1);
    if (rc < 0) {
        fprintf(stderr, "libusb_open: %s\n", libusb_error_name(rc));
        return rc;
    }
    return inspect_and_claim(device);
}

static int open_from_fd(struct siano_device *device, int fd)
{
#if defined(_WIN32)
    (void)device;
    (void)fd;
    fprintf(stderr, "--fd is not supported on Windows\n");
    return -ENOTSUP;
#elif defined(SIANO_HAVE_WRAP_SYS_DEVICE)
    int rc;

    if (fd < 0 || fcntl(fd, F_GETFD) < 0) {
        fprintf(stderr, "USB fd %d: %s\n", fd, strerror(errno));
        return -EBADF;
    }
    rc = libusb_wrap_sys_device(device->usb, (intptr_t)fd, &device->handle);
    if (rc < 0) {
        fprintf(stderr, "libusb_wrap_sys_device(%d): %s\n", fd,
                libusb_error_name(rc));
        return rc;
    }
    fprintf(stderr, "wrapped USB fd %d\n", fd);
    return inspect_and_claim(device);
#else
    (void)device;
    fprintf(stderr, "--fd requires libusb >= 1.0.23\n");
    return -ENOTSUP;
#endif
}

static void close_device(struct siano_device *device)
{
    if (device->event_thread_started)
        stop_streaming(device);
    ts_queue_close(&device->ts);
    if (device->handle) {
        if (device->interface_number >= 0)
            libusb_release_interface(device->handle, device->interface_number);
        libusb_close(device->handle);
        device->handle = NULL;
    }
    pthread_cond_destroy(&device->response_changed);
    pthread_mutex_destroy(&device->response_mutex);
    pthread_cond_destroy(&device->state_changed);
    pthread_mutex_destroy(&device->state_mutex);
    ts_queue_destroy(&device->ts);
}

static int init_device_state(struct siano_device *device, libusb_context *usb,
                             bool verbose)
{
    memset(device, 0, sizeof(*device));
    device->usb = usb;
    device->verbose = verbose;
    if (pthread_mutex_init(&device->state_mutex, NULL) != 0 ||
        pthread_cond_init(&device->state_changed, NULL) != 0 ||
        pthread_mutex_init(&device->response_mutex, NULL) != 0)
        return -1;
    if (cond_init_waitable(&device->response_changed) != 0)
        return -1;
    if (ts_queue_init(&device->ts) < 0)
        return -1;
    return 0;
}

#ifdef _WIN32
static BOOL WINAPI on_console(DWORD type)
{
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT) {
        stop_requested = 1;
        return TRUE;
    }
    return FALSE;
}
#endif

int main(int argc, char **argv)
{
    struct options options;
    struct siano_device *device;
    libusb_context *usb = NULL;
    char *firmware_path = NULL;
    uint32_t frequency;
    int output_fd = STDOUT_FILENO;
    bool close_output = false;
    int rc;

#ifdef _WIN32
    SetConsoleCtrlHandler(on_console, TRUE);
    _setmode(fileno(stdout), O_BINARY);
#else
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stderr, NULL, _IOLBF, 0);
#endif
    rc = parse_options(argc, argv, &options);
    if (rc < 0) {
        usage(stderr, argv[0]);
        return 2;
    }
    if (options.have_channel) {
        rc = sms_channel_frequency(options.channel, &frequency);
        if (rc < 0) {
            usage(stderr, argv[0]);
            return 2;
        }
        fprintf(stderr, "channel %u -> %u Hz\n", options.channel, frequency);
    } else {
        frequency = options.frequency;
    }
    if (!options.list) {
        rc = resolve_firmware(options.firmware, &firmware_path);
        if (rc < 0) {
            usage(stderr, argv[0]);
            return 2;
        }
    }
#ifdef SIANO_HAVE_WRAP_SYS_DEVICE
    if (options.device_fd >= 0) {
        /* Skip udev/usbfs scans so Android/Termux can pass a Host API fd. */
        rc = libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
        if (rc < 0)
            fprintf(stderr, "LIBUSB_OPTION_NO_DEVICE_DISCOVERY: %s\n",
                    libusb_error_name(rc));
    }
#endif
    rc = libusb_init(&usb);
    if (rc < 0) {
        fprintf(stderr, "libusb_init: %s\n", libusb_error_name(rc));
        free(firmware_path);
        return 1;
    }
    if (options.list) {
        rc = list_devices(usb);
        libusb_exit(usb);
        return rc;
    }
    device = calloc(1, sizeof(*device));
    if (!device) {
        free(firmware_path);
        libusb_exit(usb);
        return 1;
    }
    if (init_device_state(device, usb, options.verbose) < 0) {
        fprintf(stderr, "failed to initialize device state\n");
        free(device);
        free(firmware_path);
        libusb_exit(usb);
        return 1;
    }
    try_lock_pages();
    try_realtime(pthread_self(), WRITER_THREAD_PRIORITY, "writer");
    if (options.device_fd >= 0)
        rc = open_from_fd(device, options.device_fd);
    else
        rc = open_rio(device, options.device_index);
    if (rc < 0)
        goto out;
    rc = start_streaming(device);
    if (rc < 0)
        goto out;
    rc = set_device_mode(device, firmware_path);
    if (rc < 0)
        goto out;
    /* smsdvb tunes first (set_frontend), then ADD_PID on start_feed. */
    rc = tune(device, frequency);
    if (rc < 0)
        goto out;
    fprintf(stderr, "ISDB-T lock acquired\n");
    if (options.pid_count == 0) {
        /* 0x2000 is the DVB catch-all. This firmware does not ACK it;
         * the mux still flows, so do not block recording on the response. */
        uint8_t message[SMS_HEADER_SIZE + 4U];
        sms_pack_header(message, MSG_SMS_ADD_PID_FILTER_REQ,
                        SMS_DVBT_BDA_CONTROL_MSG_ID, SMS_HIF_TASK, sizeof(message), 0);
        sms_put_le32(message + SMS_HEADER_SIZE, 0x2000);
        (void)send_message(device, message, sizeof(message));
    } else {
        for (size_t i = 0; i < options.pid_count; i++) {
            rc = add_pid(device, options.pids[i]);
            if (rc < 0)
                goto out;
        }
    }
    rc = 0;
    if (options.output) {
        output_fd = open(options.output, O_WRONLY | O_CREAT | O_TRUNC | O_BINARY, 0666);
        if (output_fd < 0) {
            fprintf(stderr, "output '%s': %s\n", options.output, strerror(errno));
            rc = -errno;
            goto out;
        }
        close_output = true;
    }
    rc = stream_ts(device, output_fd, options.duration);
out:
    if (device->ts.drops != 0)
        fprintf(stderr, "TS queue dropped %llu chunk(s)\n",
                (unsigned long long)device->ts.drops);
    if (close_output)
        close(output_fd);
    close_device(device);
    free(device);
    free(firmware_path);
    libusb_exit(usb);
    if (rc < 0 && !stop_requested)
        fprintf(stderr, "siano-ts: %s\n", strerror(-rc));
    return stop_requested ? 0 : (rc < 0 ? 1 : 0);
}
