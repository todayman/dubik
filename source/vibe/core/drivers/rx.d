/*
 *  Dubik - A D language implementation of the UBIK protocol
 *  Copyright (C) 2014-2015 Paul O'Neil
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

// TODO handle all errors from control messages properly
// I don't currently check for a bunch of things.

module vibe.core.drivers.rx;

import core.memory : GC;
import core.stdc.errno;

import std.c.linux.rxrpc;
import std.c.linux.socket;

import std.conv : to;
import std.exception : enforce;
import std.experimental.logger;
import std.stdio;
import std.typecons : Nullable;

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

class AbortException : Exception
{
    public long code;
    public this(long c)
    {
        super("RX RPC aborted with code " ~ to!string(c) ~ ".");
        code = c;
    }
}

class Call
{
    private UntypedMessageHeader[] messagebuffer;

    private bool awaitingData;
    private bool inProgress;
    private Socket sock;
    private Task owner;

    package this(Socket s)
    {
        awaitingData = false;

        sock = s;
    }

    private void recvFromBuffer(UntypedMessageHeader msg, out ssize_t result)
    in {
        assert(messagebuffer.length > 0);
    }
    body {
        // We're copying the first msg out of the buffer
        // Don't just copy because we basically need to preserve the semantics
        // of the syscall, specifically filling up the buffers that were
        // provided.
        socklen_t min_namelen = min(msg.namelen, messagebuffer[0].namelen);
        msg.namelen = min_namelen;
        msg.name[0 .. min_namelen] = msg.name[0 .. min_namelen];

        // Copy the iovecs
        ulong source_iovec_bytes_copied = 0;
        ulong target_iovec_bytes_copied = 0;
        for (uint source_iovec_idx = 0, target_iovec_idx = 0;
             source_iovec_idx < messagebuffer[0].iovlen && target_iovec_idx < msg.iovlen;
            )
        {
            if (source_iovec_bytes_copied == messagebuffer[0].iov[source_iovec_idx].iov_len)
            {
                source_iovec_idx += 1;
                continue;
            }
            if (target_iovec_bytes_copied == msg.iov[target_iovec_idx].iov_len)
            {
                target_iovec_idx += 1;
                continue;
            }

            ulong bytes_this_round = min(
                msg.iov             [target_iovec_idx].iov_len - target_iovec_bytes_copied,
                messagebuffer[0].iov[source_iovec_idx].iov_len - source_iovec_bytes_copied);
            msg.iov[target_iovec_idx].iov_base[target_iovec_bytes_copied .. target_iovec_bytes_copied + bytes_this_round] =
                messagebuffer[0].iov[source_iovec_idx].iov_base[target_iovec_bytes_copied .. target_iovec_bytes_copied + bytes_this_round];
            target_iovec_bytes_copied += bytes_this_round;
            source_iovec_bytes_copied += bytes_this_round;
        }

        msg.flags = messagebuffer[0].flags;


        // Take this message out of the buffer
        messagebuffer = messagebuffer[1 .. $];
    }

    private static UntypedMessageHeader buildMsgForIov(iovec[] iovs, uint cmsg_len = 128)
    {
        UntypedMessageHeader msg = UntypedMessageHeader(cmsg_len);
        msg.iov = iovs.ptr;
        msg.iovlen = iovs.length;

        return msg;
    }

    private static MessageHeader!(T) buildMsgForIov(T...)(iovec[] iovs)
    {
        auto msg = MessageHeader!(T)();
        msg.iov = iovs.ptr;
        msg.iovlen = iovs.length;

        return msg;
    }

    private bool isEndOfMessage(in UntypedMessageHeader msg)
    {
        return (msg.flags() & MSG_EOR) != 0;
    }

    private void recvMessage(UntypedMessageHeader msg, out ssize_t result)
    {
        if (messagebuffer.length > 0)
        {
            recvFromBuffer(msg, result);
        }
        else
        {
            result  = sock.recv(this, msg);
        }
    }

    protected void checkAbort(in UntypedMessageHeader msg)
    {
        foreach (ref const UntypedControlMessage ctrl_msg; msg.ctrl_list)
        {
            // We only care about RXRPC control messages
            if(ctrl_msg.level != SOL_RXRPC) { continue; }

            if (ctrl_msg.type == RXRPC_ABORT)
            {
                throw new AbortException(ctrl_msg.to!long.data);
            }
        }
    }

    public void abort(int code)
    {
        MessageHeader!(ulong, int) abort_msg;
        abort_msg.setCallID!0(cast(ulong)cast(void*)this);
        abort_msg.ctrl!1.level = SOL_RXRPC;
        abort_msg.ctrl!1.type = RXRPC_ABORT;
        abort_msg.ctrl!1.data = code;
        sock.send(abort_msg);
    }
}

final class ClientCall : Call
{
    MessageHeader!ulong msg;

    this(Socket sock, ref sockaddr target)
    {
        super(sock);
        inProgress = false;
        msg = MessageHeader!ulong();
        // Nwf has an email from dhowells that says this is true
        // Something, something, "trust but verify", etc., etc.
        // TODO change from ulong to whatever the binding for C ulong is
        static assert((void*).sizeof <= ulong.sizeof);
        setCallID!0(msg, cast(ulong)cast(void*)this);

        msg.name = &target;
        msg.namelen = sockaddr.sizeof;

        msg.flags = 0;
    }
    ~this()
    {
        // Don't actually abort here, because that allocates and
        // we're in a destructor.
        /*
        if (inProgress)
        {
            abort(0);
        }
        */
    }

    bool send(iovec[] iovs, bool end = true)
    {
        msg.iov = iovs.ptr;
        msg.iovlen = iovs.length;
        inProgress = true;
        return sock.send(msg, end);
    }

    private bool updateInProgress(in UntypedMessageHeader msg)
    {
        bool end = isEndOfMessage(msg);
        if (end)
        {
            inProgress = false;
        }
        return end;
    }

    ssize_t recv(iovec[] iovs, out bool end)
    {
        UntypedMessageHeader msg = buildMsgForIov(iovs);
        ssize_t result;

        scope(exit) awaitingData = false;
        awaitingData = true;

        recvMessage(msg, result);

        end = updateInProgress(msg);
        checkAbort(msg);

        return result;
    }
}

private ulong getCallID(in UntypedMessageHeader hdr)
{
    foreach (ref ctrl_msg; hdr.ctrl_list)
    {
        trace("Found a control message.  Maybe it's the RX call id.");
        trace("Message level = ", ctrl_msg.level, " (SOL_RXRPC = ", SOL_RXRPC, ").");
        trace("Message type = ", ctrl_msg.type, " (RXRPC_USER_CALL_ID = ", RXRPC_USER_CALL_ID, ").");
        if (ctrl_msg.level != SOL_RXRPC || ctrl_msg.type != RXRPC_USER_CALL_ID)
        {
            trace("It was not the call id");
            continue;
        }
        trace("It was the call id!");

        return ctrl_msg.to!ulong.data;
    }
    assert(0);
}

class Socket
{
    private
    {
        DriverCore core;
        Libevent2Driver driver;
        event_base* event_loop;
        event* recv_event;
        int sock;
        uint recvs_in_progress;
    }

    this()
    {
        this.driver = cast(Libevent2Driver)getEventDriver();
        // Only compatible with the libevent2 driver
        assert(this.driver);
        this.core = getThreadLibeventDriverCore();
        event_loop = driver.eventLoop;
    }

    package bool send(MessageHeader)(in MessageHeader msg, bool end = true)
    {
        // TODO check connected, but this will err and set errno if we're not connected
        // TODO check end
        ssize_t success = sendmsg(sock, cast(msghdr*)&msg, 0);
        return success == msg.totalMessageLength;
    }

    package ssize_t recv(Call c, ref UntypedMessageHeader msg)
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
                    throw new Exception("Failure in recv: " ~ to!string(errno));
                }
            }
        }
    }

    protected void deliverData(Call call)
    {
        trace("Entered deliverData");
        // TODO what if call is awaiting data and there is data in the buffer?
        // is that a real scenario?
        if (call.awaitingData)
        {
            call.sock.core.resumeTask(call.owner);
        }
        else
        {
            UntypedMessageHeader hdr = recvMessage();

            // TODO Fix postblit on UntypedMessageHeader
            call.messagebuffer ~= [hdr];
        }
    }

    private UntypedMessageHeader recvMessage(long payload_length = 1500)
    in {
        assert(payload_length >= 0);
    }
    body {
        UntypedMessageHeader hdr = UntypedMessageHeader(128);

        do
        {
            ubyte[] buffer = new ubyte[payload_length];
            iovec[] iovs = new iovec[1];
            iovs[0].iov_base = cast(void*)buffer.ptr;
            iovs[0].iov_len = buffer.length;
            hdr.iov = iovs.ptr;
            hdr.iovlen = iovs.length;

            ssize_t bytes_received = .recvmsg(sock, cast(msghdr*)&hdr, MSG_PEEK);

            if (bytes_received >= 0)
            {
                // Make sure to shorten the buffer to only the part that has
                // been filled.  Updating the base pointer should be a no-op.
                // TODO Maybe recvmsg changes the length automatically?

                buffer = buffer[0 .. bytes_received];
                iovs[0].iov_base = cast(void*)buffer.ptr;
                iovs[0].iov_len = buffer.length;
            }
            payload_length *= 2;
        }
        while ((hdr.flags & MSG_TRUNC) != 0);

        UntypedMessageHeader empty_hdr = UntypedMessageHeader(1);
        ssize_t total_bytes = recvmsg(sock, cast(msghdr*)&empty_hdr, 0);

        // We only query recvmsg when we have been notified that there is data
        // waiting, so there should not be an error here when we extract it.
        assert(total_bytes >= 0);

        return hdr;
    }
}

// Modeled after vibe.core.drivers.libevent2.UDPConnection
final class ClientSocket : Socket
{
    import std.conv : to;
    import core.stdc.errno : errno;
    import message_headers : UntypedMessageHeader;

    this(SecurityLevel security_level)
    {
        super();
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

        recv_event = event_new(event_loop, sock, EV_READ | EV_PERSIST, &onRecv, cast(void*)this);
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
        /*
           Figure out if this is necessary after event_del()
        if (recvs_in_progress > 0)
        {
            event_free(recv_event);
        }*/
    }

    ClientCall call(ref sockaddr addr)
    {
        return new ClientCall(this, addr);
    }

    private static extern(C) void onRecv(evutil_socket_t sock, short what, void* ctx) @system
    {
        ClientSocket socket_object = cast(ClientSocket) ctx;

        auto hdr = UntypedMessageHeader(128);
        // Put 1 byte in the iovec so we can see if data is coming in
        iovec i;
        ubyte[1] buffer;
        i.iov_base = buffer.ptr;
        i.iov_len = 1;
        hdr.iov = &i;
        hdr.iovlen = 1;

        ssize_t success = .recvmsg(sock, cast(msghdr*)&hdr, MSG_PEEK);

        if (success < 0)
        {
            error("Peek Receive failed!");
            error("Errno = ", errno);
            return; // TODO this is probably incorrect, since there are tasks
                    // running and an event loop and things.
        }

        ClientCall call = cast(ClientCall)cast(void*)getCallID(hdr);

        trace("About to deliver data");
        trace("Socket object = ", cast(void*)socket_object);
        trace("Call = ", cast(void*)call);
        socket_object.deliverData(call);
    }
}

class ServerCall : Call
{
    private ServerSocket.CallResponse entrypoint;

    this(ServerSocket s, ServerSocket.CallResponse ep)
    {
        super(s);
        inProgress = true;

        entrypoint = ep;
    }

    void start()
    {
        trace("Servercall.start()");
        entrypoint(this);
    }

    ssize_t recv(iovec[] iovs, out bool end)
    {
        UntypedMessageHeader msg = buildMsgForIov(iovs);
        ssize_t result;

        scope (exit) awaitingData = false;
        awaitingData = true;

        recvMessage(msg, result);
        checkAbort(msg);

        end = isEndOfMessage(msg);
        return result;
    }

    bool send(iovec[] iovs, bool end = true)
    {
        MessageHeader!ulong msg = buildMsgForIov!ulong(iovs);
        // TODO change from ulong to whatever the binding for C ulong is
        static assert((void*).sizeof <= ulong.sizeof);
        msg.setCallID!0(cast(ulong)cast(void*)this);

        bool result = sock.send(msg, end);

        if (end)
        {
            inProgress = false;
        }
        return result;
    }

    void awaitFinalAck()
    {
        UntypedMessageHeader msg = buildMsgForIov([]);
        ssize_t result;
        scope (exit) awaitingData = false;
        awaitingData = true;

        while (inProgress)
        {
            recvMessage(msg, result);
            // Check the control messages for the final ACK
            foreach (ref const UntypedControlMessage ctrl_msg ; msg.ctrl_list)
            {
                if (ctrl_msg.level != SOL_RXRPC) { continue; }

                if (ctrl_msg.type == RXRPC_ACK)
                {
                    return;
                }
            }
            // TODO check that this does terminate all the time.
        }
    }
}

// Modeled after vibe.core.drivers.libevent2.TCPConnection
final class ServerSocket : Socket
{
    import core.stdc.errno : errno;
    import message_headers : UntypedMessageHeader;

    public alias CallResponse = void delegate(ServerCall);
    private {
        CallResponse response;
    }

    void listen(in sockaddr addr, SecurityLevel security_level, void function(ServerCall) resp)
    {
        this.listen(addr, security_level, (ServerCall r) => resp(r));
    }

    void listen(in sockaddr addr, SecurityLevel security_level, CallResponse resp)
    {
        trace("made it into the serversocket listen function");
        response = resp;

        sock = socket(AF_RXRPC, SOCK_DGRAM, addr.addr.transport.family);
        enforce(evutil_make_socket_nonblocking(sock) == 0);
        trace("created the socket (", sock, ")");

        int result = setsockopt(sock, SOL_RXRPC, RXRPC_MIN_SECURITY_LEVEL, &security_level, typeof(security_level).sizeof);
        if (result < 0)
        {
            throw new Exception("setsockopt failed with errno = " ~ to!string(errno));
        }
        trace("set the security level option on the socket.");

        // TODO check return code
        result = .bind(sock, cast(std.c.linux.socket.sockaddr*)&addr, cast(uint)typeof(addr).sizeof);
        if (result < 0)
        {
            throw new Exception("bind failed with errno = " ~ to!string(errno));
        }
        trace("socket is bound");

        .listen(sock, 100);
        trace("listening on the socket");

        // TODO look at the socket options that vibe.d sets on this in the TCP listener
        // TODO allow incoming calls to go to multiple threads if the right options are set

        auto evloop = getThreadLibeventEventLoop();
        recv_event = event_new(evloop, sock, EV_READ | EV_PERSIST, &onRecv, cast(void*)this);
        event_add(recv_event, null);
        trace("created a new libevent event");
    }

    extern(C) private static void onRecv(evutil_socket_t sock, short evtype, void* arg)
    {
        trace("onRecv!");
        ServerSocket socket_object = cast(ServerSocket)arg;
        auto hdr = UntypedMessageHeader(128);

        // Put 1 byte in the iovec so we can see if data is coming in
        iovec i;
        ubyte[1] buffer;
        i.iov_base = buffer.ptr;
        i.iov_len = 1;
        hdr.iov = &i;
        hdr.iovlen = 1;

        ssize_t success = .recvmsg(sock, cast(msghdr*)&hdr, MSG_PEEK);

        if (success < 0)
        {
            error("Peek Receive failed!");
            error("Errno = ", errno);
            return; // TODO this is probably incorrect, since there are tasks
                    // running and an event loop and things.
        }

        trace("Success = ", success, " ", hdr.controllen);

        trace("CTRL MSGS = ", hdr.ctrl_list.length);
        Nullable!ulong this_call;
        Nullable!long this_abort;
        bool this_finack;
        foreach (ref const UntypedControlMessage ctrl_msg ; hdr.ctrl_list)
        {
            trace("CTRL MSG: ",
                ctrl_msg.level, " ",
                ctrl_msg.type, " ",
                ctrl_msg.totalLength());
            // We only care about RXRPC control messages
            if(ctrl_msg.level != SOL_RXRPC) { continue; }

            switch(ctrl_msg.type) {
                case RXRPC_NEW_CALL:
                    socket_object.createAndAcceptCall();
                    break;
                case RXRPC_USER_CALL_ID:
                    this_call = ctrl_msg.to!ulong().data;
                    break;
                case RXRPC_ACK:
                    this_finack = true;
                    break;
                case RXRPC_ABORT:
                    info("Get the abort code.");
                    this_abort = ctrl_msg.to!long.data;
                    break;
                default:
                    warning("  Unknown control message");
                    break;
            }
        }
        trace("Done with control messages.");

        if(!this_call.isNull) {
            ServerCall call = cast(ServerCall)cast(void*)(this_call.get());
            trace("Found call ", cast(void*)call);
            if(success > 0 || this_finack || !this_abort.isNull) {
                socket_object.deliverData(call);
            }

            // XXX Yes?  Maybe?  Is this really when the kernel drops the ID?
            if(!this_abort.isNull || this_finack) {
              writeln("Enabling GC on ", cast(void *)call);
              GC.removeRoot(cast(void*)call);
            }
        }
    }

    private ServerCall createCall()
    {
        // Create the metadata for this call
        ServerCall c = new ServerCall(this, response);
        tracef("new call c = ", cast(void*)c);

        GC.addRoot(cast(void*)c);
        GC.setAttr(cast(void*)c, GC.BlkAttr.NO_MOVE);

        return c;
    }

    private void acceptCall(ServerCall c)
    {
        // And tell the kernel to accept the call
        auto msg = MessageHeader!(void, ulong)();

        {
            msg.ctrl!0.level = SOL_RXRPC;
            msg.ctrl!0.type = RXRPC_ACCEPT;
        }
        ulong id = cast(ulong)cast(void*)c;
        msg.setCallID!1(id);

        msg.name = null;
        msg.namelen = 0;
        msg.iov = null;
        msg.iovlen = 0;
        msg.flags = 0;

        // Since we only peeked at it before, make sure to read it out of the
        // socket
        recvMessage(0);
        ssize_t success = sendmsg(sock, cast(msghdr*)&msg, 0);
        trace("RXRPC ACCEPT sendmsg = ", success, " ", errno);
    }

    private void startCall(ServerCall c)
    {
        trace("Starting call ", cast(void*)c);
        import vibe.core.core : runTask;
        runTask(() => c.start());
    }

    private void createAndAcceptCall()
    {
        ServerCall call = createCall();
        acceptCall(call);
        startCall(call);
    }
}
