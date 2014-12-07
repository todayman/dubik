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

module vibe.core.drivers.rx;

import core.stdc.errno;

import std.c.linux.rxrpc;
import std.c.linux.socket;

import std.exception : enforce;
import std.stdio;

import deimos.event2.event;
import deimos.event2.util : evutil_socket_t;

import vibe.core.core : yield;
import vibe.core.driver;// : DriverCore, getEventDriver;
import vibe.core.drivers.libevent2;// : Libevent2Driver;
import vibe.core.task : Task;

import message_headers;

struct sockaddr
{
    private sockaddr_rxrpc addr =
    {
        AF_RXRPC, 0, SOCK_DGRAM, sockaddr_in.sizeof,
            { sin: {AF_INET, 0, {0}} }
    };

    invariant {
        // We don't support IPv6 yet
        assert(addr.transport.family == AF_INET);
    }

    // TODO Ask about what the byte ordering of service is...
    ref inout(ushort) service() inout pure nothrow @nogc
    {
        return addr.srx_service;
    }

    auto family() const pure nothrow @nogc
    {
        return addr.transport.family;
    }

    void setIPv4(in_port_t new_port = 0, in_addr_t new_address = 0) pure nothrow @nogc @safe
    {
        addr.transport_len = sockaddr_in.sizeof;
        addr.transport.family = AF_INET;
        this.port = new_port;
        this.addrv4 = new_address;
    }

    // port is in the same location and has the same type
    // for both IPv4 and IPv6
    // Don't expose this as a ref so that we can do the htons internally
    void port(in_port_t new_port) pure nothrow @nogc @safe
    {
        addr.transport.sin.sin_port = htons(new_port);
    }

    in_port_t port() const pure nothrow @nogc @safe
    {
        return ntohs(addr.transport.sin.sin_port);
    }

    // FIXME endian change here?
    void addrv4(in_addr_t new_addr) pure nothrow @nogc @safe
    in {
        assert(addr.transport.family == AF_INET);
    }
    body {
        addr.transport.sin.sin_addr.s_addr = new_addr;
    }

    // FIXME endian change here?
    in_addr_t addrv4() const pure nothrow @nogc @safe
    in {
        assert(addr.transport.family == AF_INET);
    }
    body {
        return addr.transport.sin.sin_addr.s_addr;
    }

    void setIPv6() pure nothrow @nogc
    {
        addr.transport_len = sockaddr_in6.sizeof;
        addr.transport.family = AF_INET6;
        // From core.sys.posix.netinet.in_.d:
        // struct sockaddr_in6
        // {
        //     sa_family_t sin6_family;
        //     in_port_t   sin6_port;
        //     uint32_t    sin6_flowinfo; // I don't know what this is
        //     in6_addr    sin6_addr;
        //     uint32_t    sin6_scope_id; // I don't know what this is
        // }
        addr.transport.sin6.sin6_port = 0;
        addr.transport.sin6.sin6_addr.s6_addr32 = [0, 0, 0, 0];
    }

    // FIXME endian change here?
    void addrv6(in6_addr new_addr) pure nothrow @nogc @safe
    in {
        assert(addr.transport.family == AF_INET6);
    }
    body {
        addr.transport.sin6.sin6_addr = new_addr;
    }

    // FIXME endian change here?
    in6_addr addrv6() const pure nothrow @nogc @safe
    in {
        assert(addr.transport.family == AF_INET6);
    }
    body {
        return addr.transport.sin6.sin6_addr;
    }

    static assert(sockaddr.sizeof == sockaddr_rxrpc.sizeof);
}

enum SecurityLevel : int
{
    Plain   = RXRPC_SECURITY_PLAIN,
    Auth    = RXRPC_SECURITY_AUTH,
    Encrypt = RXRPC_SECURITY_ENCRYPT,
}

void setCallID(int idx, MessageHeader)(ref MessageHeader msg, ulong call_id)
{
    msg.ctrl!idx.level = SOL_RXRPC;
    msg.ctrl!idx.type = RXRPC_USER_CALL_ID;
    msg.ctrl!idx.data = call_id;
}

void setCallID(MessageHeader)(ref MessageHeader msg, size_t idx, ulong call_id)
{
    msg.ctrl!ulong(idx).level = SOL_RXRPC;
    msg.ctrl!ulong(idx).type = RXRPC_USER_CALL_ID;
    msg.ctrl!ulong(idx).data = call_id;
}

final class Call
{
    ClientSocket sock;
    MessageHeader!ulong msg;
    bool inProgress = false;
    Task owner;

    this(ClientSocket sock, ref sockaddr target)
    {
        this.sock = sock;
        msg = MessageHeader!ulong();
        msg.ctrl!0.level = SOL_RXRPC;
        msg.ctrl!0.type = RXRPC_USER_CALL_ID;
        // Nwf has an email from dhowells that says this is true
        // Something, something, "trust but verify", etc., etc.
        static assert(typeof(&this).sizeof <= ulong.sizeof);
        msg.ctrl!0.data = cast(ulong)&this;

        msg.name = &target;
        msg.namelen = sockaddr.sizeof;

        msg.flags = 0;
    }
    ~this()
    {
        if (inProgress)
        {
            abort(0);
        }
    }

    bool send(iovec[] iovs, bool end = true)
    {
        msg.iov = iovs.ptr;
        msg.iovlen = iovs.length;
        inProgress = true;
        return sock.send(msg, end);
    }

    bool recv(iovec[] iovs, out bool end)
    {
       DynamicMessageHeader msg = DynamicMessageHeader(128);
       msg.iov = iovs.ptr;
       msg.iovlen = iovs.length;
       return sock.recv(this, msg) > 0;
    }

    void abort(int code)
    {
        MessageHeader!(ulong, int) abort_msg;
        abort_msg.ctrl!0 = msg.ctrl!0;
        abort_msg.ctrl!1.level = SOL_RXRPC;
        abort_msg.ctrl!1.type = RXRPC_ABORT;
        abort_msg.ctrl!1.data = code;
        sock.send(abort_msg);
    }
}

// Modeled after vibe.core.drivers.libevent2.UDPConnection
final class ClientSocket
{
    import std.conv : to;
    import core.stdc.errno : errno;
    import message_headers : DynamicMessageHeader;

    private {
        DriverCore core;
        Libevent2Driver driver;
        event_base* event_loop;
        event* recv_event;
        int sock;
        uint recvs_in_progress;
    }

    this(SecurityLevel security_level)
    {
        this.driver = cast(Libevent2Driver)getEventDriver();
        // Only compatible with the libevent2 driver
        assert(this.driver);
        this.core = getThreadLibeventDriverCore();
        event_loop = driver.eventLoop;
        sockaddr addr; // sockaddr.init has the right values for a client

        sock = socket(AF_RXRPC, SOCK_DGRAM, addr.addr.transport.family);
        enforce(evutil_make_socket_nonblocking(sock) == 0);

        int result = setsockopt(sock, SOL_RXRPC, RXRPC_MIN_SECURITY_LEVEL, &security_level, typeof(security_level).sizeof);
        if (result < 0)
        {
            throw new Exception("setsockopt failed with errno = " ~ to!string(errno));
        }

        result = bind(sock, cast(std.c.linux.socket.sockaddr*)&addr.addr, cast(uint)typeof(addr.addr).sizeof);
        if (result < 0)
        {
            throw new Exception("bind failed with errno = " ~ to!string(errno));
        }

        recv_event = event_new(event_loop, sock, EV_READ | EV_PERSIST, &onRecv, cast(void*)&this);
    }

    void connect(in sockaddr addr)
    {
        int result = std.c.linux.socket.connect(sock, cast(std.c.linux.socket.sockaddr*)&addr.addr, typeof(addr.addr).sizeof);
        if (result < 0)
        {
            throw new Exception("connect failed with errno = " ~ to!string(errno));
        }
    }

    ~this()
    {
        event_free(recv_event);
    }

    Call call(ref sockaddr addr)
    {
        return new Call(this, addr);
    }

    package bool send(MessageHeader)(in MessageHeader msg, bool end = true)
    {
        // TODO check connected, but this will err and set errno if we're not connected
        ssize_t success = sendmsg(sock, cast(msghdr*)&msg, 0);
        return success == msg.totalMessageLength;
    }

    package ssize_t recv(Call c, ref DynamicMessageHeader msg)
    {
        if (recvs_in_progress == 0)
        {
            event_add(recv_event, null);
        }
        recvs_in_progress += 1;

        scope(exit)
        {
            recvs_in_progress -= 1;

            if (recvs_in_progress == 0)
            {
                enforce(event_del(recv_event) == 0);
            }
        }

        c.owner = Task.getThis();

        while (true)
        {
            // Yielding here means that we wait for the socket to decide that
            // this fiber needs to run again It will do that *only* when there
            // is a message *for this call*.

            yield();
            core.yieldForEvent();
            ssize_t result = recvmsg(sock, cast(msghdr*)&msg, 0);
            if (result > 0)
            {
                return result;
            }
            else if (result < 0)
            {
                if (errno != EWOULDBLOCK)
                {
                    throw new Exception("Failure in recv");
                }
            }
        }
    }

    private static ulong getCallID(in DynamicMessageHeader hdr)
    {
        foreach (ref ctrl_msg; hdr.ctrl_list)
        {
            if (ctrl_msg.level != SOL_RXRPC || ctrl_msg.type != RXRPC_USER_CALL_ID)
            {
                continue;
            }

            return ctrl_msg.to!ulong.data;
        }
        assert(0);
    }

    private static extern(C) void onRecv(evutil_socket_t sock, short what, void* ctx) @system
    {
        ClientSocket* sock_obj = cast(ClientSocket*) ctx;

        auto hdr = DynamicMessageHeader(128);
        hdr.iov = null;
        hdr.iovlen = 0;
        recvmsg(sock, cast(msghdr*)&hdr, MSG_PEEK);

        Call * call = cast(Call*)getCallID(hdr);
        // Now, the hdr says which call this is associated with in the control
        // messages, so resume that task
        call.sock.core.resumeTask(call.owner);
    }
}
