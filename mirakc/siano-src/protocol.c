/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "protocol.h"

#include <errno.h>
#include <limits.h>
#include <string.h>

uint16_t sms_get_le16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

uint32_t sms_get_le32(const uint8_t *p)
{
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

void sms_put_le16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

void sms_put_le32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

void sms_pack_header(uint8_t *buffer, uint16_t type, uint8_t src,
                     uint8_t dst, uint16_t length, uint16_t flags)
{
    sms_put_le16(buffer + 0, type);
    buffer[2] = src;
    buffer[3] = dst;
    sms_put_le16(buffer + 4, length);
    sms_put_le16(buffer + 6, flags);
}

int sms_unpack_header(const uint8_t *buffer, size_t size,
                      struct sms_msg_hdr_wire *header)
{
    if (!buffer || !header || size < SMS_HEADER_SIZE)
        return -EINVAL;

    header->msg_type = sms_get_le16(buffer + 0);
    header->msg_src_id = buffer[2];
    header->msg_dst_id = buffer[3];
    header->msg_length = sms_get_le16(buffer + 4);
    header->msg_flags = sms_get_le16(buffer + 6);
    return 0;
}

int sms_frame_message(const uint8_t *buffer, size_t actual_length,
                      size_t response_alignment, struct sms_frame *frame)
{
    struct sms_msg_hdr_wire header;
    size_t offset = 0;
    int rc;

    if (!frame)
        return -EINVAL;

    rc = sms_unpack_header(buffer, actual_length, &header);
    if (rc < 0)
        return rc;
    if (header.msg_length < SMS_HEADER_SIZE)
        return -EBADMSG;

    if ((header.msg_flags & SMS_MSG_HDR_FLAG_SPLIT_MSG) &&
        response_alignment != 0) {
        offset = response_alignment + ((header.msg_flags >> 8) & 3U);
    }
    if (offset > actual_length || header.msg_length > actual_length - offset)
        return -EMSGSIZE;

    frame->type = header.msg_type;
    frame->length = header.msg_length;
    frame->flags = header.msg_flags;
    frame->offset = offset;
    frame->payload_offset = offset + SMS_HEADER_SIZE;
    frame->payload_length = header.msg_length - SMS_HEADER_SIZE;
    return 0;
}

int sms_channel_frequency(unsigned channel, uint32_t *frequency_hz)
{
    uint64_t frequency;

    if (!frequency_hz || channel < 13 || channel > 62)
        return -EINVAL;

    frequency = ((uint64_t)channel * 6U + 395U) * 1000000U + 142857U;
    if (frequency > UINT32_MAX)
        return -ERANGE;
    *frequency_hz = (uint32_t)frequency;
    return 0;
}

int sms_parse_firmware_header(const uint8_t *buffer, size_t size,
                              struct sms_firmware_header *header)
{
    if (!buffer || !header || size < 12)
        return -EINVAL;

    header->check_sum = sms_get_le32(buffer + 0);
    header->length = sms_get_le32(buffer + 4);
    header->start_address = sms_get_le32(buffer + 8);
    if ((uint64_t)header->length > (uint64_t)size - 12U)
        return -EBADMSG;
    return 0;
}

const char *sms_message_type_name(uint16_t type)
{
    switch (type) {
    case MSG_SMS_GET_VERSION_EX_REQ: return "MSG_SMS_GET_VERSION_EX_REQ";
    case MSG_SMS_GET_VERSION_EX_RES: return "MSG_SMS_GET_VERSION_EX_RES";
    case MSG_SMS_INIT_DEVICE_REQ: return "MSG_SMS_INIT_DEVICE_REQ";
    case MSG_SMS_INIT_DEVICE_RES: return "MSG_SMS_INIT_DEVICE_RES";
    case MSG_SMS_ADD_PID_FILTER_REQ: return "MSG_SMS_ADD_PID_FILTER_REQ";
    case MSG_SMS_ADD_PID_FILTER_RES: return "MSG_SMS_ADD_PID_FILTER_RES";
    case MSG_SMS_GET_STATISTICS_REQ: return "MSG_SMS_GET_STATISTICS_REQ";
    case MSG_SMS_GET_STATISTICS_RES: return "MSG_SMS_GET_STATISTICS_RES";
    case MSG_SMS_DATA_DOWNLOAD_REQ: return "MSG_SMS_DATA_DOWNLOAD_REQ";
    case MSG_SMS_DATA_DOWNLOAD_RES: return "MSG_SMS_DATA_DOWNLOAD_RES";
    case MSG_SMS_DATA_VALIDITY_REQ: return "MSG_SMS_DATA_VALIDITY_REQ";
    case MSG_SMS_DATA_VALIDITY_RES: return "MSG_SMS_DATA_VALIDITY_RES";
    case MSG_SMS_SWDOWNLOAD_TRIGGER_REQ: return "MSG_SMS_SWDOWNLOAD_TRIGGER_REQ";
    case MSG_SMS_SWDOWNLOAD_TRIGGER_RES: return "MSG_SMS_SWDOWNLOAD_TRIGGER_RES";
    case MSG_SMS_DVBT_BDA_DATA: return "MSG_SMS_DVBT_BDA_DATA";
    case MSG_SW_RELOAD_START_REQ: return "MSG_SW_RELOAD_START_REQ";
    case MSG_SW_RELOAD_START_RES: return "MSG_SW_RELOAD_START_RES";
    case MSG_SW_RELOAD_EXEC_REQ: return "MSG_SW_RELOAD_EXEC_REQ";
    case MSG_SW_RELOAD_EXEC_RES: return "MSG_SW_RELOAD_EXEC_RES";
    case MSG_SMS_ISDBT_TUNE_REQ: return "MSG_SMS_ISDBT_TUNE_REQ";
    case MSG_SMS_ISDBT_TUNE_RES: return "MSG_SMS_ISDBT_TUNE_RES";
    case MSG_SMS_GET_STATISTICS_EX_REQ: return "MSG_SMS_GET_STATISTICS_EX_REQ";
    case MSG_SMS_GET_STATISTICS_EX_RES: return "MSG_SMS_GET_STATISTICS_EX_RES";
    case MSG_SMS_SIGNAL_DETECTED_IND: return "MSG_SMS_SIGNAL_DETECTED_IND";
    case MSG_SMS_NO_SIGNAL_IND: return "MSG_SMS_NO_SIGNAL_IND";
    default: return "UNKNOWN";
    }
}
