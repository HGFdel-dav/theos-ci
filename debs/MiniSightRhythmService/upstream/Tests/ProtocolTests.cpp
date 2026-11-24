#include "../MSHFProtocol.h"
#include "../RequestPolicy.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint64_t NextRandom(uint64_t *state) {
    uint64_t value = *state;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    *state = value;
    return value;
}

int main(void) {
    uint8_t packet[MSHF_PROTOCOL_MAX_PACKET_SIZE] = {0};
    uint8_t payload[MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE] = {0};
    uint8_t *payloadCursor = payload;
    MSHFWriteU32(payloadCursor, MSHFFeatureMaskAll);
    payloadCursor += sizeof(uint32_t);
    MSHFWriteU16(payloadCursor, 60);
    payloadCursor += sizeof(uint16_t);
    MSHFWriteU16(payloadCursor, 10);
    MSHFEncodeHeader(packet, MSHFMessageTypeSubscribe,
                     MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE,
                     UINT64_C(0x0102030405060708),
                     UINT64_C(0x1112131415161718),
                     UINT64_C(0x2122232425262728));
    memcpy(packet + MSHF_PROTOCOL_HEADER_SIZE, payload, sizeof(payload));

    assert(memcmp(packet, "MSH2", 4) == 0);
    assert(packet[4] == MSHFMessageTypeSubscribe && packet[5] == 0);
    assert(packet[6] == MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE &&
           packet[7] == 0);
    assert(MSHFReadU64(packet + 8) == UINT64_C(0x0102030405060708));
    assert(MSHFReadU64(packet + 16) == UINT64_C(0x1112131415161718));
    assert(MSHFReadU64(packet + 24) == UINT64_C(0x2122232425262728));

    MSHFPacketHeader header{};
    assert(MSHFDecodeHeader(packet,
                            MSHF_PROTOCOL_HEADER_SIZE +
                                MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE,
                            &header));
    assert(header.type == MSHFMessageTypeSubscribe);
    assert(header.payloadLength == MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE);
    assert(header.clientSessionID == UINT64_C(0x0102030405060708));
    assert(header.serverInstanceID == UINT64_C(0x1112131415161718));
    assert(header.sequence == UINT64_C(0x2122232425262728));
    assert(MSHFReadU32(packet + MSHF_PROTOCOL_HEADER_SIZE) ==
           MSHFFeatureMaskAll);
    assert(MSHFReadU16(packet + MSHF_PROTOCOL_HEADER_SIZE +
                       sizeof(uint32_t)) == 60);
    assert(MSHFReadU16(packet + MSHF_PROTOCOL_HEADER_SIZE +
                       sizeof(uint32_t) + sizeof(uint16_t)) == 10);

    constexpr uint64_t serverInstance = UINT64_C(0xaabbccddeeff0011);
    MSHFPacketHeader request{};
    request.type = MSHFMessageTypeSubscribe;
    request.payloadLength = MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE;
    request.clientSessionID = 7;
    request.sequence = 1;
    assert(MSHFRequestPolicy::Classify(request, serverInstance) ==
           MSHFRequestPolicy::Action::Subscribe);
    request.sequence = 0;
    assert(MSHFRequestPolicy::Classify(request, serverInstance) ==
           MSHFRequestPolicy::Action::Reject);

    request.type = MSHFMessageTypeFeature;
    request.payloadLength = MSHFFeaturePayloadLength(MSHFFeatureMaskAll);
    request.serverInstanceID = serverInstance;
    request.sequence = 2;
    assert(MSHFRequestPolicy::Classify(request, serverInstance) ==
           MSHFRequestPolicy::Action::Reject);

    request.type = MSHFMessageTypeUnsubscribe;
    request.payloadLength = 0;
    assert(MSHFRequestPolicy::Classify(request, serverInstance) ==
           MSHFRequestPolicy::Action::Unsubscribe);
    request.serverInstanceID = 0;
    assert(MSHFRequestPolicy::Classify(request, serverInstance) ==
           MSHFRequestPolicy::Action::Reject);

    uint8_t mutated[MSHF_PROTOCOL_MAX_PACKET_SIZE];
    memcpy(mutated, packet, sizeof(packet));
    mutated[0] = 'X';
    assert(!MSHFDecodeHeader(
        mutated,
        MSHF_PROTOCOL_HEADER_SIZE + MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE,
        &header));
    memcpy(mutated, packet, sizeof(packet));
    mutated[4] = 0;
    assert(!MSHFDecodeHeader(
        mutated,
        MSHF_PROTOCOL_HEADER_SIZE + MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE,
        &header));
    memcpy(mutated, packet, sizeof(packet));
    mutated[6] = MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE + 1;
    assert(!MSHFDecodeHeader(
        mutated,
        MSHF_PROTOCOL_HEADER_SIZE + MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE,
        &header));
    assert(!MSHFDecodeHeader(
        packet,
        MSHF_PROTOCOL_HEADER_SIZE + MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE - 1,
        &header));
    assert(!MSHFDecodeHeader(
        packet,
        MSHF_PROTOCOL_HEADER_SIZE + MSHF_PROTOCOL_SUBSCRIBE_PAYLOAD_SIZE + 1,
        &header));

    MSHFEncodeHeader(mutated, MSHFMessageTypeFeature,
                     MSHF_PROTOCOL_MAX_PACKET_SIZE -
                         MSHF_PROTOCOL_HEADER_SIZE,
                     1, 2, 3);
    assert(MSHFDecodeHeader(mutated, MSHF_PROTOCOL_MAX_PACKET_SIZE, &header));

    const uint32_t featureMasks[] = {
        MSHFFeatureMaskWaveform,
        MSHFFeatureMaskSpectrum,
        MSHFFeatureMaskAll,
    };
    const uint16_t expectedFeatureLengths[] = {284, 284, 540};
    for (size_t index = 0;
         index < sizeof(featureMasks) / sizeof(featureMasks[0]); ++index) {
        uint16_t payloadLength =
            MSHFFeaturePayloadLength(featureMasks[index]);
        assert(payloadLength == expectedFeatureLengths[index]);
        memset(mutated, 0, sizeof(mutated));
        MSHFEncodeHeader(mutated, MSHFMessageTypeFeature, payloadLength,
                         1, 2, index + 1);
        assert(MSHFDecodeHeader(
            mutated, MSHF_PROTOCOL_HEADER_SIZE + payloadLength, &header));
        assert(!MSHFDecodeHeader(
            mutated, MSHF_PROTOCOL_HEADER_SIZE + payloadLength - 1,
            &header));
        assert(!MSHFDecodeHeader(
            mutated, MSHF_PROTOCOL_HEADER_SIZE + payloadLength + 1,
            &header));
    }
    assert(MSHFFeaturePayloadLength(0) == 0);
    assert(MSHFFeaturePayloadLength(1u << 2) == 0);

    uint64_t randomState = UINT64_C(0x4d534832cafef00d);
    for (unsigned iteration = 0; iteration < 100000; ++iteration) {
        size_t length = (size_t)(NextRandom(&randomState) %
                                 MSHF_PROTOCOL_MAX_PACKET_SIZE);
        for (size_t index = 0; index < length; ++index) {
            mutated[index] = (uint8_t)NextRandom(&randomState);
        }
        (void)MSHFDecodeHeader(mutated, length, &header);
    }

    puts("MSH2 protocol tests passed");
    return 0;
}
