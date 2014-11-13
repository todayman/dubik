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

module rx;

private import std.c.linux.rxrpc;
private import std.c.linux.socket;

struct sockaddr
{
    private sockaddr_rxrpc addr =
    {
        AF_RXRPC, 0, SOCK_DGRAM, sockaddr_in.sizeof,
            { sin: {AF_INET, 0, {0}} }
    };

    // TODO Ask about what the byte ordering of service is...
    ref inout(ushort) service() inout pure nothrow @nogc
    {
        return addr.srx_service;
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

struct ClientSocket
{
    import std.conv : to;
    import core.stdc.errno : errno;
    import message_headers : DynamicMessageHeader;

    int sock;

    this(SecurityLevel security_level)
    {
        sockaddr addr; // sockaddr.init has the right values for a client

        sock = socket(AF_RXRPC, SOCK_DGRAM, addr.addr.transport.family);

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
    }

    void connect(in sockaddr addr)
    {
        int result = std.c.linux.socket.connect(sock, cast(std.c.linux.socket.sockaddr*)&addr.addr, typeof(addr.addr).sizeof);
        if (result < 0)
        {
            throw new Exception("connect failed with errno = " ~ to!string(errno));
        }
    }

    ssize_t send(MessageHeader)(in MessageHeader msg)
    {
        // TODO check connected
        return sendmsg(sock, cast(msghdr*)&msg, 0);
    }

    ssize_t recv(ref DynamicMessageHeader msg)
    {
        // TODO check connected
        return recvmsg(sock, cast(msghdr*)&msg, 0);
    }
}