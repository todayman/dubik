/*
 *  Dubik - A D language implementation of the UBIK protocol
 *  Copyright (C) 2014 Paul O'Neil
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License as
 *  published by the Free Software Foundation, either version 3 of the
 *  License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

module message_headers;

import std.c.linux.socket;

// TODO probably needs postblit
struct ControlMessage(T)
{
    static if (!is(T : void))
    {
        private enum PayloadSize = T.sizeof;
    }
    else
    {
        private enum PayloadSize = 0;
    }
    union {
        // TODO verify the CMSG_LEN is correct...
        cmsghdr hdr = {CMSG_LEN(PayloadSize), 0, 0};
        // _data is here to ensure that the struct is the right size for
        // the payload it contains
        ubyte[CMSG_LEN(PayloadSize)] _data;
    }

    public:
    size_t totalLength() pure nothrow @nogc const
    {
        return _data.length;
    }
    size_t dataLength() pure nothrow @nogc const
    {
        return PayloadSize;
    }

    ref inout(int) level() inout pure nothrow @nogc @safe
    {
        return hdr.cmsg_level;
    }
    ref inout(int) type() inout pure nothrow @nogc @safe
    {
        return hdr.cmsg_type;
    }

    static if (!is(T : void))
    {
        ref inout(T) data() inout
        {
            return *cast(inout(T)*)CMSG_DATA(&hdr);
        }
    }

    package void writeLength()
    {
        hdr.cmsg_len = PayloadSize;
    }

    static if (CMSG_LEN(PayloadSize) != CMSG_SPACE(PayloadSize))
    {
        pragma(msg, "The length and space of a cmsg containing ", T, " are different, you might be unpleasantly surprised.");
    }
    static assert(ControlMessage!T.sizeof == CMSG_LEN(PayloadSize) || ControlMessage!T.sizeof == CMSG_SPACE(PayloadSize));
}

struct MessageHeader(ControlMessageTypes...)
{
    private msghdr hdr;

    /* Why can't I do this?
    alias name = hdr.msg_name;
    alias namelen = hdr.msg_namelen;
    alias iov = hdr.msg_iov;
    alias iovlen = hdr.msg_iovlen;
    alias flags = hdr.msg_flags;
    */
    ref void* name() {
        return hdr.msg_name;
    }
    ref socklen_t namelen() {
        return hdr.msg_namelen;
    }
    ref iovec* iov() {
        return hdr.msg_iov;
    }
    ref size_t iovlen() {
        return hdr.msg_iovlen;
    }
    ref int flags() {
        return hdr.msg_flags;
    }

    template AlignedSizeof(T)
    {
        // CMSG_SPACE is a Linux extension, but so is AF_RXRPC, so we'll use it
        enum AlignedSizeof = CMSG_SPACE(CMSG_LEN(T.sizeof));
    }

    // TODO this is probably always an underestimate.
    static if (ControlMessageTypes.length == 0)
    {
        enum default_buffer_length = 0;
    }
    else
    {
        import std.algorithm : sum;
        import std.typetuple : staticMap;
        enum default_buffer_length = sum([staticMap!(AlignedSizeof, ControlMessageTypes)]);
    }

    // So if default_buffer length were ever correct, I could allocate
    // a buffer on the stack, and resize it later if I find out it's broken
    static if (default_buffer_length > 0)
    {
        ubyte[default_buffer_length] default_buffer;
    }

    static MessageHeader!ControlMessageTypes opCall()
    {
        MessageHeader!ControlMessageTypes result;

        static if (ControlMessageTypes.length == 0)
        {
            result.hdr.msg_control = null;
            result.hdr.msg_controllen = 0;
        }
        else
        {
            result.hdr.msg_control = result.default_buffer.ptr;
            result.hdr.msg_controllen = default_buffer_length;
            if (!result.checkBufferLength(result.default_buffer[]))
            {
                ubyte[] cmsgbuf = new ubyte[default_buffer_length * 2];
                result.hdr.msg_control = cmsgbuf.ptr;
                result.hdr.msg_controllen = cmsgbuf.length;
                while (!result.checkBufferLength(cmsgbuf))
                {
                    cmsgbuf.length *= 2;
                }
            }

            // FIXME the man page (man 3 cmsg) says that this is not right
            result.hdr.msg_controllen = (cast(ubyte*)&result.ctrl!(ControlMessageTypes.length - 1)()) + CMSG_LEN(ControlMessageTypes[$-1].sizeof) - result.hdr.msg_control;
        }

        return result;
    }

    private bool checkBufferLength(ubyte[] cmsgbuf)
    {
        cmsghdr * cmsg = CMSG_FIRSTHDR(&hdr);
        foreach(T; ControlMessageTypes[0 .. $])
        {
            cmsg.cmsg_len = CMSG_LEN(ControlMessage!T.PayloadSize);
            cmsg = CMSG_NXTHDR(&hdr, cmsg);
            if (cmsg is null)
            {
                return false;
            }
        }
        return true;
    }

    ref MessageHeader!ControlMessageTypes opAssign(ref MessageHeader!ControlMessageTypes other)
    {
        this.hdr = other.hdr;
        static if (ControlMessageTypes.length > 0)
        {
            if (other.hdr.msg_control == other.default_buffer.ptr)
            {
                this.hdr.msg_control = this.default_buffer.ptr;
                this.hdr.msg_controllen = default_buffer_length;
                this.default_buffer[] = other.default_buffer[];
            }
            else
            {
                this.hdr.msg_control = other.hdr.msg_control;
                this.hdr.msg_controllen = other.hdr.msg_controllen;
            }
        }
        return this;
    }
    this(this)
    {
        static if (ControlMessageTypes.length > 0)
        {
            // Really, I want to know whether I should use my default buffer,
            // and this is the only comparison that should tell me that
            if (hdr.msg_controllen == default_buffer_length)
            {
                hdr.msg_control = default_buffer.ptr;
            }
            else
            {
                hdr.msg_control = hdr.msg_control[0 .. hdr.msg_controllen].dup.ptr;
            }
        }
    }

    ref ControlMessage!(ControlMessageTypes[idx]) ctrl(size_t idx)()
        if (idx < ControlMessageTypes.length)
    {
        cmsghdr * cmsg = CMSG_FIRSTHDR(&hdr);
        foreach (i; 0 .. idx)
        {
            cmsg = CMSG_NXTHDR(&hdr, cmsg);
        }
        return *(cast(ControlMessage!(ControlMessageTypes[idx])*)(cmsg));
    }

    ref ControlMessage!T ctrl(T)(size_t idx) pure @nogc @system
    in {
        assert(idx >= 0 && idx < ControlMessageTypes.length);
    }
    body {
        cmsghdr * cmsg = CMSG_FIRSTHDR(&hdr);
        foreach (i; 0 .. idx)
        {
            cmsg = CMSG_NXTHDR(&hdr, cmsg);
        }
        return *(cast(ControlMessage!T*)(cmsg));
    }

    size_t totalMessageLength() const
    {
        if (hdr.msg_iov is null)
            return 0;
        size_t result = 0;
        foreach (idx; 0 .. hdr.msg_iovlen)
            result += hdr.msg_iov[idx].iov_len;
        return result;
    }
}
static assert(MessageHeader!().sizeof == msghdr.sizeof);

struct UntypedControlMessage
{
    cmsghdr hdr;

    public:
    size_t totalLength() pure nothrow @nogc const
    {
        return hdr.cmsg_len;
    }
    size_t dataLength() pure nothrow @nogc const
    {
        return hdr.cmsg_len - cmsghdr.sizeof;
    }

    ref inout(int) level() inout
    {
        return hdr.cmsg_level;
    }
    ref inout(int) type() inout
    {
        return hdr.cmsg_type;
    }

    ref inout(ControlMessage!T) to(T)() inout
    in {
        // TODO should I drop the < and enforce ==?
        assert(T.sizeof == dataLength());
    }
    body {
        return *(cast(inout(ControlMessage!T*))&this);
    }
}

struct UntypedMessageHeader
{
    import std.algorithm : map, sum;

    private msghdr hdr;
    private ubyte[] ctrl_buffer;

    /* Why can't I do this?
    alias name = hdr.msg_name;
    alias namelen = hdr.msg_namelen;
    alias iov = hdr.msg_iov;
    alias iovlen = hdr.msg_iovlen;
    alias flags = hdr.msg_flags;
    */
    ref inout(void*) name() inout {
        return hdr.msg_name;
    }
    ref inout(socklen_t) namelen() inout {
        return hdr.msg_namelen;
    }
    ref inout(iovec*) iov() inout {
        return hdr.msg_iov;
    }
    ref inout(size_t) iovlen() inout {
        return hdr.msg_iovlen;
    }
    ref inout(int) flags() inout {
        return hdr.msg_flags;
    }
    ulong controllen() {
        return hdr.msg_controllen;
    }

    this(size_t ctrl_buffer_length)
    {
        ctrl_buffer = new ubyte[ctrl_buffer_length];
        hdr.msg_control = ctrl_buffer.ptr;
        hdr.msg_controllen = ctrl_buffer.length;
    }

    this(this)
    {
        ctrl_buffer = ctrl_buffer.dup;
        hdr.msg_control = ctrl_buffer.ptr;
    }

    private struct ControlListLooper
    {
        private msghdr* hdr;

        public this(inout(msghdr)* h) inout
        {
            hdr = h;
        }

        // TODO change these to inout
        int opApply(int delegate(ref const UntypedControlMessage) dg) const
        {
            int result = 0;
            for (const(cmsghdr)* cmsg = CMSG_FIRSTHDR(hdr);
                 cmsg !is null && !result;
                 cmsg = CMSG_NXTHDR(hdr, cmsg))
            {
                result = dg(*cast(UntypedControlMessage*)cmsg);
            }
            return result;
        }
        int opApply(int delegate(ref ulong, ref const UntypedControlMessage) dg) const
        {
            int result = 0;
            const(cmsghdr)* cmsg = CMSG_FIRSTHDR(hdr);
            for (ulong idx = 0;
                 cmsg !is null && !result;
                 ++idx)
            {
                result = dg(idx, *cast(const(UntypedControlMessage)*)cmsg);
                cmsg = CMSG_NXTHDR(hdr, cmsg);
            }
            return result;
        }

        ulong length() const
        {
            ulong len = 0;
            for (const(cmsghdr)* cmsg = CMSG_FIRSTHDR(hdr);
                 cmsg !is null;
                 cmsg = CMSG_NXTHDR(cast(msghdr*)hdr, cmsg))
            {
                ++len;
            }
            return len;
        }
    }
    inout(ControlListLooper) ctrl_list() inout
    {
        return inout(ControlListLooper)(&hdr);
    }

    ref UntypedControlMessage ctrl(size_t idx)
    {
        cmsghdr * cmsg = CMSG_FIRSTHDR(&hdr);
        for (size_t i = 0; i < idx && cmsg !is null; ++i)
        {
            cmsg = CMSG_NXTHDR(&hdr, cmsg);
        }
        if (cmsg is null)
            throw new Exception("Out of bounds!");
        return *(cast(UntypedControlMessage*)(cmsg));
    }

    void resetControlLength()
    {
        hdr.msg_controllen = ctrl_buffer.length;
    }
}
