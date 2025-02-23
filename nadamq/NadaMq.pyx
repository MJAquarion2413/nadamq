# cython: embedsignature = True
# cython: language_level = 3
# distutils: language = c++
# distutils: libraries = c++
cimport cython
from cython.operator cimport dereference as deref
from libc.stdint cimport uint16_t
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
from libcpp.string cimport string

from cpython.bytes cimport PyBytes_AS_STRING

import numpy as np

ctypedef unsigned char uchar
ctypedef uint16_t crc_t


@cython.internal
cdef class _Flags:
    cdef:
        readonly string START

    def __cinit__(self):
        self.START = '|||'.encode('utf-8')


@cython.internal
cdef class _PacketTypes:
    cdef:
        readonly int NONE
        readonly int ACK
        readonly int NACK
        readonly int DATA
        readonly int STREAM
        readonly int ID_REQUEST
        readonly int ID_RESPONSE

    def __cinit__(self):
        self.NONE = PACKET_TYPE_NONE
        self.ACK = PACKET_TYPE_ACK
        self.NACK = PACKET_TYPE_NACK
        self.DATA = PACKET_TYPE_DATA
        self.STREAM = PACKET_TYPE_STREAM
        self.ID_REQUEST = PACKET_TYPE_ID_REQUEST
        self.ID_RESPONSE = PACKET_TYPE_ID_RESPONSE


PACKET_TYPES = _PacketTypes()
FLAGS = _Flags()


cdef extern from "PacketParser.h":
    cdef enum packet_type "Packet::packet_type::EnumType":
        PACKET_TYPE_NONE "Packet::packet_type::NONE"
        PACKET_TYPE_ACK "Packet::packet_type::ACK"
        PACKET_TYPE_NACK "Packet::packet_type::NACK"
        PACKET_TYPE_DATA "Packet::packet_type::DATA"
        PACKET_TYPE_STREAM "Packet::packet_type::STREAM"
        PACKET_TYPE_ID_REQUEST "Packet::packet_type::ID_REQUEST"
        PACKET_TYPE_ID_RESPONSE "Packet::packet_type::ID_RESPONSE"

    cdef cppclass FixedPacket:
        uint16_t iuid_
        packet_type type_
        uint16_t payload_length_
        uint16_t buffer_size_
        uchar *payload_buffer_
        uint16_t crc_

        FixedPacket()
        string data() except +
        uchar type()
        void type(uchar command_with_type_msb)
        void compute_crc()

    cdef cppclass PacketParser "PacketParser<FixedPacket>":
        int payload_bytes_received_
        int payload_bytes_expected_
        bint message_completed_
        bint parse_error_
        uint16_t crc_

        PacketParser()
        void parse_byte(uchar *byte)
        void reset(FixedPacket *packet)


cdef extern from "crc-16.h":
    crc_t c_crc_init "crc_init" ()
    crc_t c_crc_finalize "crc_finalize" (crc_t crc)
    crc_t c_crc_update "crc_update" (crc_t crc, uchar *data, size_t data_len)
    crc_t c_crc_update_byte "crc_update_byte" (crc_t crc, uchar data)


cdef extern from "<sstream>" namespace "std":
    cdef cppclass stringstream:
        stringstream()
        string str_ "str" ()


cdef extern from "PacketWriter.h":
    void write_packet(stringstream output, FixedPacket packet)


cdef class cPacket:
    cdef FixedPacket *thisptr
    cdef unsigned char *buffer_

    def __cinit__(self, type_=PACKET_TYPES.NONE, iuid=0, data=None,
                  buffer_=None, buffer_size=None):
        self.thisptr = new FixedPacket()
        if data is not None:
            if buffer_ is not None:
                # Caller supplied a buffer, so check to make sure that the
                # length of the buffer is long enough to hold `data`.
                if len(buffer_) < len(data):
                    raise ValueError(f'Supplied buffer is not long enough to hold `data`, {len(buffer_)} < {len(data)}')

                elif buffer_size is not None:
                    raise ValueError('Buffer size must not be specified when a buffer is supplied, since the size is '
                                     'implied by the size of the provided buffer.')
                else:
                    self.set_buffer(buffer_)
            elif buffer_size is None:
                # Data was provided, but no buffer size was specified.  Use length
                # of `data` as implied buffer size, or length of one if `data`
                # has a length of zero.
                buffer_size = max(len(data), 1)

        self.buffer_ = NULL
        if buffer_size is not None and buffer_size > 0:
            self.alloc_buffer(buffer_size)

        self.iuid = iuid
        self.type_ = type_
        if data is not None:
            self.set_data(data)

    property max_buffer_size:
        def __get__(self):
            return (1 << (sizeof(self.thisptr.buffer_size_) << 3)) - 1

    def set_data(self, string data):
        """
        Write the provided data to the buffer.

        Notes
        =====

         - The packet must already have a buffer of sufficient size.
         - This method updates the length of the payload, but does not modify
          the size of the buffer.
         - This method updates the CRC checksum of the packet, based on the new
          payload contents.
        """
        if data.size() > self.thisptr.buffer_size_:
            raise ValueError(f'Data length is too large for buffer, {data.size()} > {self.thisptr.buffer_size_}')

        memcpy(self.thisptr.payload_buffer_, data.c_str(), data.size())
        self.thisptr.payload_length_ = data.size()
        self.thisptr.compute_crc()

    def data(self):
        """
        Return the payload of the packet as a byte string.
        """
        return self.thisptr.data()

    def data_ptr(self):
        """
        Return the pointer to the payload buffer.
        """
        return <size_t>self.thisptr.payload_buffer_

    def tobytes(self) -> bytes:
        """
        Serialize a packet according to format defined in the `write_packet` C++
        function.

        Returns
        -------
        bytes
            Serialized packet.
        """
        return self.tostring()

    def tostring(self) -> bytes:
        """
        Serialize a packet according to format defined in the `write_packet` C++ function.

        Returns
        -------
        str
            Serialized packet.


        .. versionadded:: 0.15
        """
        cdef stringstream output
        write_packet(output, deref(self.thisptr))
        return output.str_()

    property crc:
        def __get__(self):
            return self.thisptr.crc_

    property type_:
        def __get__(self):
            return self.thisptr.type()
        def __set__(self, value):
            self.thisptr.type(value)

    property iuid:
        def __get__(self):
            return self.thisptr.iuid_
        def __set__(self, value):
            self.thisptr.iuid_ = value

    property buffer_size:
        def __get__(self):
            return self.thisptr.buffer_size_

    def clear_buffer(self):
        """
        Deallocate buffer (if it has been allocated).
        """
        if self.buffer_ != NULL:
            free(self.buffer_)
            self.buffer_ = NULL

    def realloc_buffer(self, buffer_size):
        """
        Allocate the specified buffer size, deallocating the existing buffer,
        if one has been allocated.
        """
        if buffer_size > self.max_buffer_size:
            raise RuntimeError(f'Max buffer size is {self.max_buffer_size}')
        self.clear_buffer()
        self.alloc_buffer(buffer_size)

    def alloc_buffer(self, buffer_size):
        """
        Allocate the specified buffer size.
        """
        if self.buffer_ != NULL:
            raise RuntimeError('Buffer has already been allocated.')
        if buffer_size > self.max_buffer_size:
            raise RuntimeError(f'Max buffer size is {self.max_buffer_size}')
        self.buffer_ = <unsigned char *>malloc(buffer_size)
        self.set_buffer(<unsigned char [:buffer_size]>self.buffer_, overwrite=True)
        self.thisptr.buffer_size_ = buffer_size

    def set_buffer(self, unsigned char [:] data, overwrite=False):
        """
        Assign the specified data buffer as the payload buffer of the packet.
        """
        if self.thisptr.payload_buffer_ != NULL and not overwrite:
            raise RuntimeError('Packet already has a payload buffer '
                               'allocated.  Must use `overwrite=True` to set buffer anyway.')
        self.thisptr.payload_buffer_ = &data[0]
        self.thisptr.buffer_size_ = len(data)
        self.thisptr.payload_length_ = 0

    def __dealloc__(self):
        free(self.thisptr)
        self.clear_buffer()

    def __str__(self):
        return self.tostring()


cdef class cPacketParser:
    cdef PacketParser *thisptr
    cdef object packet

    def __cinit__(self, buffer_size=8 << 10):
        self.thisptr = new PacketParser()
        self.packet = cPacket(buffer_size=buffer_size)
        self.reset()

    def __dealloc__(self):
        free(self.thisptr)

    def reset(self):
        self.thisptr.reset((<cPacket>self.packet).thisptr)

    def parse(self, uchar [:] packet_buffer):
        cdef int i
        for i in range(len(packet_buffer)):
            self.thisptr.parse_byte(<uchar *>&packet_buffer[i])
            if self.error:
                raise RuntimeError(f'Error parsing packet [byte={i}]: {np.asarray(packet_buffer).tobytes()}')
            elif self.message_completed:
                return self.packet
        return False

    property message_completed:
        def __get__(self):
            return self.thisptr.message_completed_

    property error:
        def __get__(self):
            return self.thisptr.parse_error_

    property crc:
        def __get__(self):
            return self.thisptr.crc_


def crc_init():
    return c_crc_init()


def crc_finalize(crc):
    return c_crc_finalize(crc)


def crc_update(uint16_t crc, uchar [:] data):
    return c_crc_update(crc, &data[0], len(data))


def crc_update_byte(uint16_t crc, uchar octet):
    return c_crc_update_byte(crc, octet)

def compute_crc16(data):
    cdef string data_ = data
    cdef uint16_t crc = crc_init()
    crc = c_crc_update(crc, <uchar *>data_.c_str(), len(data))
    return crc_finalize(crc)

def byte_pair(value):
    return chr((value >> 8) & 0x0FF), chr(value & 0x0FF)


def parse_from_string(packet_str):
    """
    .. versionchanged:: 0.15
        Coerce :data:`packet_str` to :class:`bytes` and do not use :func:`ord`
        to decode characters.  This is required to support both Python 2 and 3.


    Returns
    -------
    cPacket
        Parsed packet instance.
    """
    parser = cPacketParser()
    return parser.parse(np.array([v for v in bytes(packet_str)], dtype='uint8'))


PACKET_NAME_BY_TYPE = {PACKET_TYPE_NONE: 'NONE',
                       PACKET_TYPE_ACK: 'ACK',
                       PACKET_TYPE_NACK: 'NACK',
                       PACKET_TYPE_DATA: 'DATA',
                       PACKET_TYPE_STREAM: 'STREAM',
                       PACKET_TYPE_ID_REQUEST: 'ID_REQUEST',
                       PACKET_TYPE_ID_RESPONSE: 'ID_RESPONSE'}
