/*
 * Written by Paul O'Neil
 * Placed into public domain.
 */

module std.c.linux.rxrpc;

public import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;

extern(C):

/*
 * RxRPC socket address
 */
struct sockaddr_rxrpc
{
    sa_family_t    srx_family;    /* address family */
    ushort        srx_service;    /* service desired */
    ushort        transport_type;    /* type of transport socket (SOCK_DGRAM) */
    ushort        transport_len;    /* length of transport address */
    union TransportAddr
    {
        sa_family_t family;        /* transport address family */
        sockaddr_in sin;        /* IPv4 transport address */
        sockaddr_in6 sin6;    /* IPv6 transport address */
    }
    TransportAddr transport;
};

enum : int
{
    SOL_RXRPC = 272,
}

/*
 * RxRPC socket options
 */
enum : int
{
    RXRPC_SECURITY_KEY =            1,    /* [clnt] set client security key */
    RXRPC_SECURITY_KEYRING =        2,    /* [srvr] set ring of server security keys */
    RXRPC_EXCLUSIVE_CONNECTION =    3,    /* [clnt] use exclusive RxRPC connection */
    RXRPC_MIN_SECURITY_LEVEL =      4,    /* minimum security level */
}

/*
 * RxRPC control messages
 * - terminal messages mean that a user call ID tag can be recycled
 */
enum : int
{
    RXRPC_USER_CALL_ID =    1,    /* user call ID specifier */
    RXRPC_ABORT =           2,    /* abort request / notification [terminal] */
    RXRPC_ACK =             3,    /* [Server] RPC op final ACK received [terminal] */
    RXRPC_NET_ERROR =       5,    /* network error received [terminal] */
    RXRPC_BUSY =            6,    /* server busy received [terminal] */
    RXRPC_LOCAL_ERROR =     7,    /* local error generated [terminal] */
    RXRPC_NEW_CALL =        8,    /* [Server] new incoming call notification */
    RXRPC_ACCEPT =          9,    /* [Server] accept request */
}

/*
 * RxRPC security levels
 */
enum : int
{
    RXRPC_SECURITY_PLAIN =      0,    /* plain secure-checksummed packets only */
    RXRPC_SECURITY_AUTH =       1,    /* authenticated packets */
    RXRPC_SECURITY_ENCRYPT =    2,    /* encrypted packets */
}

/*
 * RxRPC security indices
 */
enum : int
{
    RXRPC_SECURITY_NONE =    0,    /* no security protocol */
    RXRPC_SECURITY_RXKAD =   2,    /* kaserver or kerberos 4 */
    RXRPC_SECURITY_RXGK =    4,    /* gssapi-based */
    RXRPC_SECURITY_RXK5 =    5,    /* kerberos 5 */
}

void addCallID(ubyte[] control, ulong id, ref uint ctrllen)
{
    cmsghdr * cmsg = cast(cmsghdr*)(control.ptr + ctrllen);
    ulong * data_ptr;
    cmsg.cmsg_len  = CMSG_LEN(typeof(id).sizeof);
    cmsg.cmsg_level = SOL_RXRPC;
    cmsg.cmsg_type = RXRPC_USER_CALL_ID;
    data_ptr = cast(ulong*)CMSG_DATA(cmsg);
    (*data_ptr) = id;
    ctrllen += cmsg.cmsg_len;
}
