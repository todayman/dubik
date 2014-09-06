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

import std.stdio;
import std.c.linux.socket;
import std.c.linux.rxrpc;

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
        pong();
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

void ping()
{
    int send_socket = socket(AF_RXRPC, SOCK_DGRAM, AF_INET);

    sockaddr_rxrpc my_addr;
    my_addr.srx_family = AF_RXRPC;
    my_addr.srx_service = 0; /* 0 indicates a client */
    my_addr.transport_type = SOCK_DGRAM;
    my_addr.transport.family = AF_INET;
    my_addr.transport.sin.sin_port = htons(PING_CLIENT_PORT);
    my_addr.transport.sin.sin_addr.s_addr = 0;
    bind(send_socket, cast(sockaddr*)&my_addr, cast(uint)typeof(my_addr).sizeof);

    sockaddr_rxrpc target_addr;
    target_addr.srx_family = AF_RXRPC;
    target_addr.srx_service = PING_SERVICE_ID;
    target_addr.transport_type = SOCK_DGRAM;
    target_addr.transport.family = AF_INET;
    target_addr.transport.sin.sin_port = htons(PING_SERVER_PORT);
    target_addr.transport.sin.sin_addr.s_addr = LOCALHOST_IP;
    //target_addr.transport.sin_address =  htons(

    ubyte[128] control;
    uint controllen = 0;
    addCallID(control, 1, controllen);

    string msg_string = "PING";
    iovec msg_contents = { cast(void*)msg_string.ptr, msg_string.length };
    msghdr msg;
    msg.msg_namelen = 0;
    msg.msg_iovlen = 1;
    msg.msg_iov = &msg_contents;
    msg.msg_control = control.ptr;
    msg.msg_controllen = controllen;
    msg.msg_flags = 0;

    ssize_t success = sendmsg(send_socket, &msg, 0);
}

void pong()
{
    writeln("Sending pong!");
}
