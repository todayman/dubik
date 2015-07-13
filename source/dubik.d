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

import message_headers;
import vibe.core.core;
import vibe.core.drivers.rx;

int main(string[] args)
{
    if( args.length != 2 )
    {
        writeln("Exactly one argument expected, either \"--ping\" or \"--pong\".");
        return 1;
    }

    if( args[1] == "--ping" )
    {
        runTask(() => ping());
    }
    else if( args[1] == "--pong" )
    {
        runTask(() => server());
    }
    else
    {
        writeln("Expected argument to be either \"--ping\" or \"--pong\".");
        return 1;
    }

    runEventLoop();

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

void ping()
{
    auto send_socket = new vibe.core.drivers.rx.ClientSocket(vibe.core.drivers.rx.SecurityLevel.Plain);

    vibe.core.drivers.rx.sockaddr target_addr;
    target_addr.service = PING_SERVICE_ID;
    target_addr.setIPv4(PING_SERVER_PORT, LOCALHOST_IP);

    auto c = send_socket.call(target_addr);
    {
        string msg_string = "PING";
        iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };

        bool success = c.send([msg_contents]);

        if (!success)
        {
            writeln("error ", errno);
        }
        assert(success);
    }

    {
        ubyte[128] msg_string;
        iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };

        bool finished;
        ssize_t success = c.recv([msg_contents], finished);
        writeln("recvmsg = ", success, " ", errno);
        if (success > 0) {
            writeln("Got message from server: ",
                cast(string)(msg_string[0 .. success]));
            writeln("Finished = ", finished);
        }
    }

    exitEventLoop();
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

void pong(RXRPCall *c, ubyte[] arg) {
    writeln("PONG MESSAGE: ", c, ":", arg);

    auto msg = MessageHeader!ulong();
    setCallID(msg, 0, cast(ulong)c);

    ubyte[] msg_string = cast(ubyte[])("PONG!  Thanks for using RX!".dup);
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

    vibe.core.drivers.rx.sockaddr my_addr;
    my_addr.service = PING_SERVICE_ID;
    my_addr.setIPv4(PING_SERVER_PORT, 0);
    bind(server_socket, cast(std.c.linux.socket.sockaddr*)&my_addr, cast(uint)typeof(my_addr).sizeof);

    listen(server_socket, 100);

    ubyte[128] msg_string;
    iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };

    ubyte[1024] msg_name;
    UntypedMessageHeader msg = UntypedMessageHeader(128);

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
        foreach (ref const UntypedControlMessage ctrl_msg ; msg.ctrl_list)
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
    exitEventLoop();
}
