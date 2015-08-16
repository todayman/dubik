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

import std.experimental.logger;

import core.memory;
import core.stdc.errno;
import core.sys.posix.poll;

import message_headers;
import vibe.core.core;
static import vibe.core.log;
import vibe.core.drivers.rx;

ServerSocket server_socket;
int main(string[] args)
{
    if( args.length != 2 )
    {
        writeln("Exactly one argument expected, either \"--ping\" or \"--pong\".");
        return 1;
    }

    sharedLog.logLevel = LogLevel.trace;
    vibe.core.log.setLogLevel(vibe.core.log.LogLevel.debug_);

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

void pong(vibe.core.drivers.rx.ServerCall call)
{
    trace("Entered PONG!");
    {
        ubyte[128] msg_string;
        iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };
        bool finished = false;
        call.recv([msg_contents], finished);

        writeln("PONG MESSAGE: ", cast(void*)call, ":", msg_string);
    }

    {
        ubyte[] msg_string = cast(ubyte[])("PONG!  Thanks for using RX!".dup);
        iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };

        ssize_t success = call.send([msg_contents], true);
        writeln("PONG SENDMSG: ", success, " ", errno);
    }

    {
        call.awaitFinalAck();
        writeln("PONG FINAL ACK");
    }
}

void server()
{
    vibe.core.drivers.rx.sockaddr my_addr;
    my_addr.service = PING_SERVICE_ID;
    my_addr.setIPv4(PING_SERVER_PORT, 0);

    trace("About to call listen on the server socket");
    server_socket = new ServerSocket();
    server_socket.listen(my_addr, vibe.core.drivers.rx.SecurityLevel.Plain, &pong);
}
