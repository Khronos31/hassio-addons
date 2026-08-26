/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef SIANO_PROTOCOL_H
#define SIANO_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define SMS_HEADER_SIZE 8U
#define SMS_MAX_PAYLOAD_SIZE 240U
#define SMS_USB2_BUFFER_SIZE 0x2000U
#define SMS_MAX_MESSAGE_SIZE (SMS_HEADER_SIZE + 4U + SMS_MAX_PAYLOAD_SIZE)
#define SMS_MSG_HDR_FLAG_SPLIT_MSG 4U

enum sms_message_type {
    MSG_SMS_GET_VERSION_EX_REQ = 668,
    MSG_SMS_GET_VERSION_EX_RES = 669,
    MSG_SMS_INIT_DEVICE_REQ = 578,
    MSG_SMS_INIT_DEVICE_RES = 579,
    MSG_SMS_ADD_PID_FILTER_REQ = 601,
    MSG_SMS_ADD_PID_FILTER_RES = 602,
    MSG_SMS_GET_STATISTICS_REQ = 615,
    MSG_SMS_GET_STATISTICS_RES = 616,
    MSG_SMS_DATA_DOWNLOAD_REQ = 660,
    MSG_SMS_DATA_DOWNLOAD_RES = 661,
    MSG_SMS_DATA_VALIDITY_REQ = 662,
    MSG_SMS_DATA_VALIDITY_RES = 663,
    MSG_SMS_SWDOWNLOAD_TRIGGER_REQ = 664,
    MSG_SMS_SWDOWNLOAD_TRIGGER_RES = 665,
    MSG_SMS_DVBT_BDA_DATA = 693,
    MSG_SW_RELOAD_START_REQ = 702,
    MSG_SW_RELOAD_START_RES = 703,
    MSG_SW_RELOAD_EXEC_REQ = 704,
    MSG_SW_RELOAD_EXEC_RES = 705,
    MSG_SMS_ISDBT_TUNE_REQ = 776,
    MSG_SMS_ISDBT_TUNE_RES = 777,
    MSG_SMS_GET_STATISTICS_EX_REQ = 653,
    MSG_SMS_GET_STATISTICS_EX_RES = 654,
    MSG_SMS_SIGNAL_DETECTED_IND = 827,
    MSG_SMS_NO_SIGNAL_IND = 828,
};

enum sms_device_mode {
    DEVICE_MODE_NONE = -1,
    DEVICE_MODE_ISDBT_BDA = 6,
};

enum sms_bandwidth_mode {
    BW_ISDBT_13SEG = 8,
};

enum {
    SMS_HIF_TASK = 11,
    SMS_DVBT_BDA_CONTROL_MSG_ID = 201,
};

#ifdef _MSC_VER
#pragma pack(push, 1)
#endif
struct sms_msg_hdr_wire {
    uint16_t msg_type;
    uint8_t msg_src_id;
    uint8_t msg_dst_id;
    uint16_t msg_length;
    uint16_t msg_flags;
#ifdef _MSC_VER
};
#pragma pack(pop)
#else
} __attribute__((packed));
#endif

struct sms_firmware_header {
    uint32_t check_sum;
    uint32_t length;
    uint32_t start_address;
};

struct sms_frame {
    uint16_t type;
    uint16_t length;
    uint16_t flags;
    size_t offset;
    size_t payload_offset;
    size_t payload_length;
};

uint16_t sms_get_le16(const uint8_t *p);
uint32_t sms_get_le32(const uint8_t *p);
void sms_put_le16(uint8_t *p, uint16_t value);
void sms_put_le32(uint8_t *p, uint32_t value);

void sms_pack_header(uint8_t *buffer, uint16_t type, uint8_t src,
                     uint8_t dst, uint16_t length, uint16_t flags);
int sms_unpack_header(const uint8_t *buffer, size_t size,
                      struct sms_msg_hdr_wire *header);

/* Decode the framing used by smsusb_onresponse(), including split messages. */
int sms_frame_message(const uint8_t *buffer, size_t actual_length,
                      size_t response_alignment, struct sms_frame *frame);

int sms_channel_frequency(unsigned channel, uint32_t *frequency_hz);
int sms_parse_firmware_header(const uint8_t *buffer, size_t size,
                              struct sms_firmware_header *header);

const char *sms_message_type_name(uint16_t type);

#endif
