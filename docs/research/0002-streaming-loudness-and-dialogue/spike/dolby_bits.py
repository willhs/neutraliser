#!/usr/bin/env python3
"""Read and edit Dolby loudness metadata in raw AC-3 / E-AC-3 streams, without touching audio.

Evidence for docs/research/0002-streaming-loudness-and-dialogue/research.md. Not product code.

- read: the dialnorm and dynrng-present flag of each frame
- set_dialnorm: rewrite dialnorm in place and fix the CRCs
- add_dynrng: give chosen AC-3 frames a dynrng word (FFmpeg's encoder never writes one, so a
  fixture with DRC has to be made by hand). Frames grow to the next size up to make room.

Only 48 kHz is handled: that is all the fixtures use.
"""
import sys

SYNC = b"\x0b\x77"
AC3_WORDS_48K = [64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192, 224, 224, 256, 256, 320, 320,
                 384, 384, 448, 448, 512, 512, 640, 640, 768, 768, 896, 896, 1024, 1024, 1152, 1152, 1280, 1280]
FULL_CHANNELS = [2, 1, 2, 3, 3, 4, 4, 5]  # by acmod, not counting LFE

_TABLE = []
for byte in range(256):
    crc = byte << 8
    for _ in range(8):
        crc = ((crc << 1) ^ 0x8005) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    _TABLE.append(crc)


def crc16(data, crc=0):
    for byte in data:
        crc = ((crc << 8) & 0xFFFF) ^ _TABLE[(crc >> 8) ^ byte]
    return crc


class Bits:
    """Big-endian bit access over a bytearray."""

    def __init__(self, data, pos=0):
        self.data, self.pos = data, pos

    def read(self, n):
        value = 0
        for _ in range(n):
            value = (value << 1) | ((self.data[self.pos >> 3] >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return value

    def write_at(self, pos, n, value):
        for i in range(n):
            bit = (value >> (n - 1 - i)) & 1
            mask = 1 << (7 - ((pos + i) & 7))
            byte = (pos + i) >> 3
            self.data[byte] = (self.data[byte] | mask) if bit else (self.data[byte] & ~mask)


def is_eac3(frame):
    return (frame[5] >> 3) > 10


def frame_size(data, offset):
    if data[offset:offset + 2] != SYNC:
        raise ValueError(f"no sync at {offset}")
    bsid = data[offset + 5] >> 3
    if bsid > 10:
        return (((data[offset + 2] & 0x07) << 8) | data[offset + 3]) * 2 + 2
    if data[offset + 4] >> 6 != 0:
        raise ValueError("fixtures are 48 kHz only")
    return AC3_WORDS_48K[data[offset + 4] & 0x3F] * 2


def frames(data):
    offset = 0
    while offset + 6 < len(data):
        size = frame_size(data, offset)
        yield offset, size
        offset += size


def _ac3_header(frame):
    """Field positions in an AC-3 frame: dialnorm's bit position, and block 0's dynrnge."""
    bits = Bits(frame, 32)
    bits.read(8)  # fscod, frmsizecod
    bsid = bits.read(5)
    bits.read(3)  # bsmod
    acmod = bits.read(3)
    if acmod & 1 and acmod != 1:
        bits.read(2)
    if acmod & 4:
        bits.read(2)
    if acmod == 2:
        bits.read(2)
    bits.read(1)  # lfeon
    dialnorm_pos = bits.pos
    bits.read(5)
    if bits.read(1):
        bits.read(8)  # compr
    if bits.read(1):
        bits.read(8)  # langcod
    if bits.read(1):
        bits.read(7)  # mixlevel, roomtyp
    if acmod == 0:
        bits.read(5)
        if bits.read(1):
            bits.read(8)
        if bits.read(1):
            bits.read(8)
        if bits.read(1):
            bits.read(7)
    bits.read(2)  # copyrightb, origbs
    for _ in range(2):  # timecod1e/2e, or xbsi1e/2e: 14 bits each way
        if bits.read(1):
            bits.read(14)
    if bits.read(1):
        length = bits.read(6)
        bits.read((length + 1) * 8)
    bits.read(FULL_CHANNELS[acmod] * 2)  # blksw, dithflag
    return dialnorm_pos, bits.pos, bsid


def _eac3_dialnorm_pos(frame):
    bits = Bits(frame, 16)
    bits.read(2 + 3 + 11)  # strmtyp, substreamid, frmsiz
    fscod = bits.read(2)
    bits.read(2)  # numblkscod or fscod2
    if fscod == 3:
        raise ValueError("reduced sample rates not handled")
    bits.read(3 + 1 + 5)  # acmod, lfeon, bsid
    return bits.pos


def read_dialnorm(frame):
    pos = _eac3_dialnorm_pos(frame) if is_eac3(frame) else _ac3_header(frame)[0]
    code = Bits(frame, pos).read(5)
    return -31 if code == 0 else -code  # 0 is reserved; decoders treat it as 31


def dialnorm_values(data):
    return {read_dialnorm(bytearray(data[o:o + s])) for o, s in frames(data)}


def _five_eighths(size):
    return ((size >> 2) + (size >> 4)) << 1


_CRC1_INVERSE = {}


def _solve_crc1(size_58, target):
    """The crc1 field value that makes crc16(frame[2:size_58]) zero.

    crc1 sits at the start of what it protects, so it can't be computed by running the CRC forward.
    The CRC is linear over GF(2), so solve for it with an inverted 16x16 matrix per frame size.
    """
    if size_58 not in _CRC1_INVERSE:
        zeros = bytes(size_58 - 4)
        columns = [crc16(zeros, crc16((1 << bit).to_bytes(2, "big"))) for bit in range(16)]
        rows = [[(columns[col] >> row) & 1 for col in range(16)] + [1 if row == j else 0 for j in range(16)]
                for row in range(16)]
        for pivot in range(16):
            lead = next(r for r in range(pivot, 16) if rows[r][pivot])
            rows[pivot], rows[lead] = rows[lead], rows[pivot]
            for r in range(16):
                if r != pivot and rows[r][pivot]:
                    rows[r] = [a ^ b for a, b in zip(rows[r], rows[pivot])]
        _CRC1_INVERSE[size_58] = [sum(rows[r][16 + c] << c for c in range(16)) for r in range(16)]
    inverse = _CRC1_INVERSE[size_58]
    return sum(((bin(inverse[r] & target).count("1") & 1) << r) for r in range(16))


def fix_crcs(frame):
    size = len(frame)
    if is_eac3(frame):
        frame[size - 2:] = crc16(frame[2:size - 2]).to_bytes(2, "big")
        return frame
    size_58 = _five_eighths(size)
    frame[2:4] = _solve_crc1(size_58, crc16(frame[4:size_58])).to_bytes(2, "big")
    frame[size - 2:] = crc16(frame[size_58:size - 2]).to_bytes(2, "big")
    return frame


def set_dialnorm(data, value):
    """Rewrite dialnorm in every frame. The audio bits are left alone."""
    out = bytearray()
    for offset, size in frames(data):
        frame = bytearray(data[offset:offset + size])
        pos = _eac3_dialnorm_pos(frame) if is_eac3(frame) else _ac3_header(frame)[0]
        Bits(frame).write_at(pos, 5, abs(value))
        out += fix_crcs(frame)
    return bytes(out)


def has_dynrng(frame):
    return Bits(frame, _ac3_header(frame)[1]).read(1) == 1


def add_dynrng(data, code_for_frame):
    """Give AC-3 frames a dynrng word in block 0 (later blocks reuse it).

    code_for_frame(index) returns the 8-bit dynrng code, or None to leave the frame without one.
    Every frame moves up one bitrate class so there is room for the extra bits, and the new space is zero
    padding, which decoders don't read.
    """
    out = bytearray()
    for index, (offset, size) in enumerate(frames(data)):
        frame = bytearray(data[offset:offset + size])
        if is_eac3(frame):
            raise ValueError("dynrng insertion is AC-3 only")
        code = code_for_frame(index)
        cod = frame[4] & 0x3F
        new_size = AC3_WORDS_48K[cod + 2] * 2
        if new_size - size < 2:
            raise ValueError("no larger frame size available")
        frame[4] = (frame[4] & 0xC0) | (cod + 2)
        body = frame[:size - 3]  # the old crcrsv byte goes with the old crc2
        body += bytes(new_size - len(body))
        if code is not None:
            _, flag_pos, _ = _ac3_header(body)
            as_int = int.from_bytes(body, "big")
            total_bits = new_size * 8
            head = as_int >> (total_bits - flag_pos)
            tail = as_int & ((1 << (total_bits - flag_pos - 1)) - 1)  # everything after the old flag
            tail_bits = total_bits - flag_pos - 1
            head = (head << 1) | 1
            head = (head << 8) | code
            body = bytearray(((head << (tail_bits - 8)) | (tail >> 8)).to_bytes(new_size, "big"))
        out += fix_crcs(body)
    return bytes(out)


if __name__ == "__main__":
    stream = open(sys.argv[1], "rb").read()
    all_frames = list(frames(stream))
    print(f"frames={len(all_frames)} dialnorm={sorted(dialnorm_values(stream))}")
