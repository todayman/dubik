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

struct ControlMessage
{
    int level;
    int type;
    ubyte[] data;

    this(cmsghdr * hdr)
    {
        level = hdr.cmsg_level;
        type = hdr.cmsg_type;
        data.length = (cast(ubyte*)(hdr) + hdr.cmsg_len) - CMSG_DATA(hdr);
        data = CMSG_DATA(hdr)[0 .. data.length];
    }

    void setData(T)(T value)
    {
        data.length = T.sizeof;
        (*cast(T*)data.ptr) = value;
    }

    @property package size_t totalLength() pure nothrow const
    {
        return CMSG_LEN(data.length);
    }
    void serialize(ubyte[] sink) pure const
    {
        cmsghdr* cmsg = cast(cmsghdr*)sink.ptr;
        cmsg.cmsg_len = CMSG_LEN(data.length);
        cmsg.cmsg_level = level;
        cmsg.cmsg_type = type;
        CMSG_DATA(cmsg)[0 .. data.length] = data[];
    }
}

// FIXME  When I do foreach over this, the list is empty afterwards.
// It would be nice to do a non-destructive loop.
struct ControlMessageList
{
    private ControlMessage[] _arr;

    this(msghdr* msg)
    {
        cmsghdr* current = CMSG_FIRSTHDR(msg);
        uint counter = 0;
        while(current != null)
        {
            current = CMSG_NXTHDR(msg, current);
            ++counter;
        }

        _arr.length = counter;
        current = CMSG_FIRSTHDR(msg);
        foreach( ref ControlMessage new_msg ; _arr )
        {
            new_msg = ControlMessage(current);
            current = CMSG_NXTHDR(msg, current);
        }
    }

    @property bool empty()
    {
        return _arr.length > 0;
    }

    @property ControlMessage front()
    {
        return _arr[0];
    }

    @property void popFront()
    {
        _arr = _arr[1..$];
    }

    @property ulong length()
    {
        return _arr.length;
    }

    ControlMessage opIndex(uint idx)
    {
        return _arr[idx];
    }

    void put(ControlMessage msg)
    {
        _arr ~= msg;
    }

    size_t totalLength() pure
    {
        size_t len = 0;
        foreach( msg ; _arr )
        {
            len += msg.totalLength;
        }
        return len;
    }

    void serialize(ubyte[] result) pure
    {
        result.length = totalLength();
        size_t startPoint = 0;
        foreach( const ref msg ; _arr )
        {
            msg.serialize(result[startPoint .. startPoint + msg.totalLength]);
            startPoint += msg.totalLength;
        }
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
        ControlMessageList ctrlMsgList;
        ControlMessage ctrlMsg;
        ctrlMsg.level = SOL_RXRPC;
        ctrlMsg.type = RXRPC_USER_CALL_ID;
        ctrlMsg.setData!ulong(1);
        ctrlMsgList.put(ctrlMsg);
        // ubyte[ctrlMsgList.totalLength] control;
        // DMD reports that the length is not an expression, which is wrong.
        // It's not a compile time expression , so it doesn't work when we
        // add the () at the end, but at the very least the message is not good.
        ubyte[] control;
        control.length = ctrlMsgList.totalLength;
        ctrlMsgList.serialize(control);

        string msg_string = "PING";
        iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };
        msghdr msg;
        msg.msg_name = &target_addr;
        msg.msg_namelen = sockaddr_rxrpc.sizeof;
        msg.msg_iov = &msg_contents;
        msg.msg_iovlen = 1;
        msg.msg_control = control.ptr;
        msg.msg_controllen = ctrlMsgList.totalLength;
        msg.msg_flags = 0;

        ssize_t success = sendmsg(send_socket, &msg, 0);
        assert(success == msg_string.length);
    }

    {
        ubyte[128] msg_string;
        ubyte[128] control;
        socklen_t controllen = control.length;
        iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };
        msghdr msg;
        msg.msg_name = null;
        msg.msg_namelen = 0;
        msg.msg_iov = &msg_contents;
        msg.msg_iovlen = 1;
        msg.msg_control = control.ptr;
        msg.msg_controllen = controllen;
        msg.msg_flags = 0;

        ssize_t success = recvmsg(send_socket, &msg, 0);
        writeln("recvmsg = ", success, " ", errno);
        if (success > 0) {
            writeln("Got message from server: ",
                cast(string)(msg_string[0 .. success]));
        }
    }
}

// XXX To a library with thee!
void rxrpc_accept(int socket, ulong id) {
    ubyte[128] cb;
    uint cl = 0;
    msghdr msg;

    {
        cmsghdr * cmsg = cast(cmsghdr*)(cb.ptr + cl);
        cmsg.cmsg_len  = CMSG_LEN(0);
        cmsg.cmsg_level = SOL_RXRPC;
        cmsg.cmsg_type = RXRPC_ACCEPT;
        cl += cmsg.cmsg_len;
    }
    addCallID(cb, id, cl);

    msg.msg_name = null;
    msg.msg_namelen = 0;
    msg.msg_iov = null;
    msg.msg_iovlen = 0;
    msg.msg_control = cb.ptr;
    msg.msg_controllen = cl;
    msg.msg_flags = 0;

    ssize_t success = sendmsg(socket, &msg, 0);
    writefln("RXRPC ACCEPT sendmsg = %d %d", success, errno);
}

struct RXRPCall {
    int                                socket;
    void function(RXRPCall *, ubyte[]) cb_data;
    void function(RXRPCall *)          cb_finalack;
    void function(RXRPCall *, long)    cb_err;
};


void pong(RXRPCall *c, ubyte[] arg) {
    writeln("PONG MESSAGE: ", c, ":", arg);

    ubyte[128] control;
    uint controllen = 0;
    addCallID(control, cast(ulong)c, controllen);

    ubyte[] msg_string = cast(ubyte[])("PONG!  Thanks for using RX!");
    iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };

    msghdr msg;
    msg.msg_name = null;
    msg.msg_namelen = 0;
    msg.msg_iovlen = 1;
    msg.msg_iov = &msg_contents;
    msg.msg_control = control.ptr;
    msg.msg_controllen = controllen;
    msg.msg_flags = 0;

    ssize_t success = sendmsg(c.socket, &msg, 0);
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

    ubyte[128] control;
    uint controllen = 0;

    ubyte[128] msg_string;
    iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };

    ubyte[1024] msg_name;
    msghdr msg;

    msg.msg_iovlen = 1;
    msg.msg_iov = &msg_contents;
    msg.msg_flags = 0;

    // Wait for a message
    writeln("Looping...");
    pollfd poll_info;
    poll_info.fd = server_socket;
    poll_info.events = POLLIN;
    while(poll(&poll_info, 1, -1)) {

        msg.msg_name = msg_name.ptr;
        msg.msg_namelen = msg_name.length;
        msg.msg_iov.iov_len = msg_string.length;
        msg.msg_control = control.ptr;
        msg.msg_controllen = control.length;

        ssize_t success = recvmsg(server_socket, &msg, 0);
        if( success == -1 )
        {
            writeln("Receive failed!");
            writefln("Errno = %d", errno);
            return;
        }
        writeln("Success = ", success, " ", msg.msg_controllen);

        ControlMessageList ctrl_msg_list = ControlMessageList(&msg);

        writefln("CTRL MSGS = %d", ctrl_msg_list.length);
        Nullable!ulong this_call;
        Nullable!long this_abort;
        bool this_finack;
        for(int cix = 0; cix < ctrl_msg_list.length; cix++)
        {
            ControlMessage ctrl_msg = ctrl_msg_list[cix];

            writefln("CTRL MSG: %d %d %d",
                ctrl_msg.level,
                ctrl_msg.type,
                ctrl_msg.totalLength());
            if(ctrl_msg.level != SOL_RXRPC) { continue; }

            switch(ctrl_msg.type) {
                case RXRPC_NEW_CALL:
                    auto c = new RXRPCall;
                    c.socket  = server_socket;
                    c.cb_data = &pong;
                    c.cb_finalack = &pongfa;
                    c.cb_err  = &pongerr;

                    GC.addRoot(cast(void*)c);
                    GC.setAttr(cast(void*)c, GC.BlkAttr.NO_MOVE);
                    rxrpc_accept(server_socket, cast(ulong)c);
                    break;
                case RXRPC_USER_CALL_ID:
                    this_call = *cast(ulong*)(ctrl_msg.data.ptr);
                    break;
                case RXRPC_ACK:
                    this_finack = true;
                    break;
                case RXRPC_ABORT:
                    this_abort = *cast(long*)(ctrl_msg.data.ptr);
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
