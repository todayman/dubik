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

import std.conv;
import std.stdio;
import std.typecons;
import std.typetuple;
import std.c.linux.socket;
import std.c.linux.rxrpc;

import core.memory;
import core.stdc.errno;
import core.sys.posix.poll;

int main(string[] args)
{
    if( args.length != 2 )
    {
        writeln("Exactly one argument expected.");
        return 1;
    }

    if( args[1] == "--ping" )
    {
        ping();
    }
    else if( args[1] == "--pong" )
    {
        server();
    }
    else
    {
        writeln("Expected argument to be either \"--ping\" or \"--pong\".");
    }

    return 0;
}

enum PING_SERVICE_ID = 1;
enum PING_CLIENT_PORT = 1200;
enum PING_SERVER_PORT = 1201;
immutable in_addr_t LOCALHOST_IP;
static this()
{
    LOCALHOST_IP = inet_addr("127.0.0.1");
}

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
        cmsghdr hdr = {PayloadSize, 0, 0};
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

    static assert(ControlMessage!T.sizeof == CMSG_LEN(PayloadSize));
}

struct MessageHeader(ControlMessageTypes...)
{
    import std.algorithm : map, sum;

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
        // CMSG_ALIGN is a Linux extension, but so is AF_RXRPC, so we'll use it
        // CMSG_SPACE is from bits/socket.h and should be moved to druntime,
        // where the other macros are
        static size_t CMSG_SPACE(size_t len) { return CMSG_ALIGN(len) + CMSG_ALIGN(cmsghdr.sizeof); }
        enum AlignedSizeof = CMSG_SPACE(CMSG_LEN(T.sizeof));
    }

    // TODO this is probably always an underestimate.
    static if (ControlMessageTypes.length == 0)
    {
        enum default_buffer_length = 0;
    }
    else
    {
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
                writeln("Allocating a control buffer");
                ubyte[] cmsgbuf = new ubyte[default_buffer_length * 2];
                result.hdr.msg_control = cmsgbuf.ptr;
                result.hdr.msg_controllen = cmsgbuf.length;
                while (!result.checkBufferLength(cmsgbuf))
                {
                    cmsgbuf.length *= 2;
                }
            }

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
}
static assert(MessageHeader!().sizeof == msghdr.sizeof);

struct DynamicControlMessage
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
        assert(T.sizeof <= dataLength());
    }
    body {
        return *(cast(inout(ControlMessage!T*))&this);
    }
}

struct DynamicMessageHeader
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

    private struct ControlListLooper
    {
        private msghdr* hdr;

        public this(msghdr* h)
        {
            hdr = h;
        }

        // TODO change these to inout
        int opApply(int delegate(ref const DynamicControlMessage) dg) const
        {
            int result = 0;
            for (const(cmsghdr)* cmsg = CMSG_FIRSTHDR(hdr);
                 cmsg !is null && !result;
                 cmsg = CMSG_NXTHDR(hdr, cmsg))
            {
                result = dg(*cast(DynamicControlMessage*)cmsg);
            }
            return result;
        }
        int opApply(int delegate(ref ulong, ref const DynamicControlMessage) dg) const
        {
            int result = 0;
            const(cmsghdr)* cmsg = CMSG_FIRSTHDR(hdr);
            for (ulong idx = 0;
                 cmsg !is null && !result;
                 ++idx)
            {
                result = dg(idx, *cast(const(DynamicControlMessage)*)cmsg);
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
    auto ctrl_list()
    {
        return ControlListLooper(&hdr);
    }

    ref DynamicControlMessage ctrl(size_t idx)
    {
        cmsghdr * cmsg = CMSG_FIRSTHDR(&hdr);
        for (size_t i = 0; i < idx && cmsg !is null; ++i)
        {
            cmsg = CMSG_NXTHDR(&hdr, cmsg);
        }
        if (cmsg is null)
            throw new Exception("Out of bounds!");
        return *(cast(DynamicControlMessage*)(cmsg));
    }

    void resetControlLength()
    {
        hdr.msg_controllen = ctrl_buffer.length;
    }
}

void ping()
{
    int send_socket = socket(AF_RXRPC, SOCK_DGRAM, AF_INET);

    int security_level = RXRPC_SECURITY_PLAIN;
    int result = setsockopt(send_socket, SOL_RXRPC, RXRPC_MIN_SECURITY_LEVEL, &security_level, typeof(security_level).sizeof);
    if( result < 0 )
    {
        writeln("setsockopt failed");
        writefln("Errno = %d", errno);
        return;
    }

    sockaddr_rxrpc my_addr;
    my_addr.srx_family = AF_RXRPC;
    my_addr.srx_service = 0; /* 0 indicates a client */
    my_addr.transport_type = SOCK_DGRAM;
    my_addr.transport_len = sockaddr_in.sizeof;
    my_addr.transport.family = AF_INET;
    my_addr.transport.sin.sin_port = 0;//htons(PING_CLIENT_PORT);
    my_addr.transport.sin.sin_addr.s_addr = 0;
    result = bind(send_socket, cast(sockaddr*)&my_addr, cast(uint)typeof(my_addr).sizeof);
    if(result < 0)
    {
        writeln("bind failed");
        writefln("Errno = %d", errno);
        return;
    }

    sockaddr_rxrpc target_addr;
    target_addr.srx_family = AF_RXRPC;
    target_addr.srx_service = PING_SERVICE_ID;
    target_addr.transport_type = SOCK_DGRAM;
    target_addr.transport_len = sockaddr_in.sizeof;
    target_addr.transport.family = AF_INET;
    target_addr.transport.sin.sin_port = htons(PING_SERVER_PORT);
    target_addr.transport.sin.sin_addr.s_addr = LOCALHOST_IP;

    result = connect(send_socket, cast(sockaddr*)&target_addr, typeof(target_addr).sizeof);
    if(result < 0 )
    {
        writeln("connect failed");
        writefln("Errno = %d", errno);
        return;
    }

    {
        auto msg = MessageHeader!ulong();
        msg.ctrl!0.level = SOL_RXRPC;
        msg.ctrl!0.type = RXRPC_USER_CALL_ID;
        msg.ctrl!0.data = 1;

        string msg_string = "PING";
        iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };
        msg.name = &target_addr;
        msg.namelen = sockaddr_rxrpc.sizeof;
        msg.iov = &msg_contents;
        msg.iovlen = 1;
        msg.flags = 0;

        ssize_t success = sendmsg(send_socket, cast(msghdr*)&msg, 0);
        assert(success == msg_string.length);
    }

    {
        ubyte[128] msg_string;
        iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };
        DynamicMessageHeader msg = DynamicMessageHeader(128);
        msg.name = null;
        msg.namelen = 0;
        msg.iov = &msg_contents;
        msg.iovlen = 1;
        msg.flags = 0;

        ssize_t success = recvmsg(send_socket, cast(msghdr*)&msg, 0);
        writeln("recvmsg = ", success, " ", errno);
        if (success > 0) {
            writeln("Got message from server: ",
                cast(string)(msg_string[0 .. success]));
        }
    }
}

// XXX To a library with thee!
void rxrpc_accept(int socket, ulong id) {
    auto msg = MessageHeader!(void, ulong)();

    {
        msg.ctrl!0.level = SOL_RXRPC;
        msg.ctrl!0.type = RXRPC_ACCEPT;
    }
    msg.setCallID!1(id);

    msg.name = null;
    msg.namelen = 0;
    msg.iov = null;
    msg.iovlen = 0;
    msg.flags = 0;

    ssize_t success = sendmsg(socket, cast(msghdr*)&msg, 0);
    writefln("RXRPC ACCEPT sendmsg = %d %d", success, errno);
}

struct RXRPCall {
    int                                socket;
    void function(RXRPCall *, ubyte[]) cb_data;
    void function(RXRPCall *)          cb_finalack;
    void function(RXRPCall *, long)    cb_err;
};


void setCallID(int idx, MessageHeader)(ref MessageHeader msg, ulong call_id)
{
    msg.ctrl!idx.level = SOL_RXRPC;
    msg.ctrl!idx.type = RXRPC_USER_CALL_ID;
    msg.ctrl!idx.data = call_id;
}

void pong(RXRPCall *c, ubyte[] arg) {
    writeln("PONG MESSAGE: ", c, ":", arg);

    auto msg = MessageHeader!ulong();
    setCallID!0(msg, cast(ulong)c);

    ubyte[] msg_string = cast(ubyte[])("PONG!  Thanks for using RX!");
    iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };

    msg.name = null;
    msg.namelen = 0;
    msg.iovlen = 1;
    msg.iov = &msg_contents;
    msg.flags = 0;

    ssize_t success = sendmsg(c.socket, cast(msghdr*)&msg, 0);
    writeln("PONG SENDMSG: ", success, " ", errno);
}

void pongfa(RXRPCall *c) {
    writeln("PONG FINAL ACK");
}

void pongerr(RXRPCall *c, long abrt) {
    writeln("PONG ABORT: ", c, ":", abrt);
}

void server()
{
    int server_socket = socket(AF_RXRPC, SOCK_DGRAM, AF_INET);
    uint next_call_id = 1024;

    sockaddr_rxrpc my_addr;
    my_addr.srx_family = AF_RXRPC;
    my_addr.srx_service = PING_SERVICE_ID; /* 0 indicates a client */
    my_addr.transport_type = SOCK_DGRAM;
    my_addr.transport_len = sockaddr_in.sizeof;
    my_addr.transport.family = AF_INET;
    my_addr.transport.sin.sin_port = htons(PING_SERVER_PORT);
    my_addr.transport.sin.sin_addr.s_addr = 0;
    bind(server_socket, cast(sockaddr*)&my_addr, cast(uint)typeof(my_addr).sizeof);

    listen(server_socket, 100);

    ubyte[128] msg_string;
    iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };

    ubyte[1024] msg_name;
    DynamicMessageHeader msg = DynamicMessageHeader(128);

    msg.iovlen = 1;
    msg.iov = &msg_contents;
    msg.flags = 0;

    // Wait for a message
    writeln("Looping...");
    pollfd poll_info;
    poll_info.fd = server_socket;
    poll_info.events = POLLIN;
    while(poll(&poll_info, 1, -1)) {

        msg.name = msg_name.ptr;
        msg.namelen = msg_name.length;
        msg.iov.iov_len = msg_string.length;
        msg.resetControlLength();
        /*msg.control = control.ptr;
        msg.controllen = control.length;*/

        ssize_t success = recvmsg(server_socket, cast(msghdr*)&msg, 0);
        if( success == -1 )
        {
            writeln("Receive failed!");
            writefln("Errno = %d", errno);
            return;
        }
        writeln("Success = ", success, " ", msg.controllen);

        writefln("CTRL MSGS = %d", msg.ctrl_list.length);
        Nullable!ulong this_call;
        Nullable!long this_abort;
        bool this_finack;
        foreach (ref const DynamicControlMessage ctrl_msg ; msg.ctrl_list)
        {
            writefln("CTRL MSG: %d %d %d",
                ctrl_msg.level,
                ctrl_msg.type,
                ctrl_msg.totalLength());
            if(ctrl_msg.level != SOL_RXRPC) { continue; }

            switch(ctrl_msg.type) {
                case RXRPC_NEW_CALL:
                    auto c = new RXRPCall;
                    writeln("new call c = ", c);
                    c.socket  = server_socket;
                    c.cb_data = &pong;
                    c.cb_finalack = &pongfa;
                    c.cb_err  = &pongerr;

                    GC.addRoot(cast(void*)c);
                    GC.setAttr(cast(void*)c, GC.BlkAttr.NO_MOVE);
                    rxrpc_accept(server_socket, cast(ulong)c);
                    break;
                case RXRPC_USER_CALL_ID:
                    this_call = ctrl_msg.to!ulong().data;
                    break;
                case RXRPC_ACK:
                    this_finack = true;
                    break;
                case RXRPC_ABORT:
                    writeln("Get the abort.");
                    this_abort = ctrl_msg.to!long.data;
                    break;
                default:
                    writeln("  Unknown control message");
                    break;
            }
        }
        writeln("Done with control messages.");

        if(!this_call.isNull) {
          RXRPCall *c = cast(RXRPCall *)(this_call.get());
          if(success > 0) {
            writeln("Dispatch data...");
            auto a = msg_string[0 .. success];
            c.cb_data(c,a);
          }
          if(this_finack) {
            writeln("Dispatch finalack...");
            c.cb_finalack(c);
          }
          if(!this_abort.isNull) {
            writeln("Dispatch abort...");
            auto a = this_abort.get();
            c.cb_err(c,a);
          }
          // XXX Yes?  Maybe?  Is this really when the kernel drops the ID?
          if(!this_abort.isNull || this_finack) {
            writeln("Enabling GC on ", cast(void *)c);
            GC.removeRoot(cast(void*)c);
          }
        }
    }

    writeln("Poll finished");
}
