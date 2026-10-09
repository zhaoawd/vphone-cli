#include "Include/VphonedNative.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/vsock.h>
#include <unistd.h>

// Keep VSOCK writes blocking: B22's nonblocking native probe lost bytes after
// positive write returns. NIO owns only independent pipes, so its descriptor
// flags and gathered writes cannot change the transport's send semantics.
static _Atomic int active_connections = 0;
typedef struct Bridge Bridge;
typedef struct { Bridge *bridge; int receiving; } Direction;
struct Bridge {
    int socket_fd, to_nio, from_nio;
    _Atomic int references;
    Direction receive, send;
};

static void release_bridge(Bridge *bridge) {
    if (atomic_fetch_sub(&bridge->references, 1) == 1) {
        close(bridge->socket_fd);
        atomic_fetch_sub(&active_connections, 1);
        free(bridge);
    }
}

static void *forward_bytes(void *arg) {
    Direction direction = *(Direction *)arg;
    Bridge *bridge = direction.bridge;
    int input = direction.receiving ? bridge->socket_fd : bridge->from_nio;
    int output = direction.receiving ? bridge->to_nio : bridge->socket_fd;
    unsigned char bytes[16384];
    int failed = 0;
    for (;;) {
        ssize_t count = read(input, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { failed = count < 0; break; }
        size_t offset = 0;
        while (offset < (size_t)count) {
            ssize_t written = write(output, bytes + offset, (size_t)count - offset);
            if (written < 0 && errno == EINTR) continue;
            if (written < 0 && direction.receiving && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                struct pollfd ready = {.fd = output, .events = POLLOUT};
                int result;
                do { result = poll(&ready, 1, 10000); } while (result < 0 && errno == EINTR);
                if (result > 0 && (ready.revents & POLLOUT)) continue;
            }
            if (written <= 0) { failed = 1; break; }
            offset += (size_t)written;
        }
        if (failed) break;
    }
    if (failed) shutdown(bridge->socket_fd, SHUT_RDWR);
    if (direction.receiving) close(bridge->to_nio);
    else {
        // NIO has finished this connection. Also wake the receive thread
        // if the peer keeps its sending direction open after our response.
        shutdown(bridge->socket_fd, SHUT_RDWR);
        close(bridge->from_nio);
    }
    release_bridge(bridge);
    return NULL;
}

// Always consumes socket_fd. attach always consumes both pipe descriptors,
// including when it reports failure. At most 32 connections / 64 relay threads.
int vp_vsock_bridge(int socket_fd, int (*attach)(int, int)) {
    // Closed pipes must report EPIPE throughout this networking worker,
    // including the NIO event-loop threads.
    struct sigaction ignore = {.sa_handler = SIG_IGN};
    sigemptyset(&ignore.sa_mask);
    if (sigaction(SIGPIPE, &ignore, NULL) != 0) {
        close(socket_fd);
        return -1;
    }
    if (atomic_fetch_add(&active_connections, 1) >= 32) {
        atomic_fetch_sub(&active_connections, 1);
        close(socket_fd);
        return -1;
    }
    int input[2] = {-1, -1}, output[2] = {-1, -1};
    Bridge *bridge = calloc(1, sizeof(*bridge));
    pthread_attr_t attributes;
    int initialized = 0;
    struct timeval timeout = {.tv_sec = 10};
    if (!bridge || fcntl(socket_fd, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(socket_fd, F_SETFL, fcntl(socket_fd, F_GETFL) & ~O_NONBLOCK) < 0 ||
        setsockopt(socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0 ||
        pipe(input) || pipe(output)) goto fail;
    for (int i = 0; i < 2; i++) {
        if (fcntl(input[i], F_SETFD, FD_CLOEXEC) < 0 ||
            fcntl(output[i], F_SETFD, FD_CLOEXEC) < 0) goto fail;
    }
    // NIO writes output[1] on its own event-loop threads. A relay that has
    // closed output[0] must report EPIPE there without terminating the worker.
    if (fcntl(output[1], F_SETNOSIGPIPE, 1) < 0 ||
        fcntl(input[1], F_SETNOSIGPIPE, 1) < 0 ||
        fcntl(input[1], F_SETFL, O_NONBLOCK) < 0 || pthread_attr_init(&attributes)) goto fail;
    initialized = 1;
    if (pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED) ||
        pthread_attr_setstacksize(&attributes, 128 * 1024)) goto fail;
    bridge->socket_fd = socket_fd;
    bridge->to_nio = input[1];
    bridge->from_nio = output[0];
    atomic_init(&bridge->references, 3);
    bridge->receive = (Direction){bridge, 1};
    bridge->send = (Direction){bridge, 0};
    pthread_t receive, send;
    if (pthread_create(&receive, &attributes, forward_bytes, &bridge->receive)) goto fail;
    if (pthread_create(&send, &attributes, forward_bytes, &bridge->send)) {
        pthread_attr_destroy(&attributes);
        shutdown(socket_fd, SHUT_RDWR);
        close(input[0]); close(output[0]); close(output[1]);
        release_bridge(bridge); // send thread was not created
        release_bridge(bridge); // caller
        return -1;
    }
    pthread_attr_destroy(&attributes);
    int result = attach(input[0], output[1]);
    if (result != 0) shutdown(socket_fd, SHUT_RDWR);
    release_bridge(bridge); // caller retains the descriptor through attach
    return result;
fail:
    if (initialized) pthread_attr_destroy(&attributes);
    for (int i = 0; i < 2; i++) {
        if (input[i] >= 0) close(input[i]);
        if (output[i] >= 0) close(output[i]);
    }
    close(socket_fd);
    free(bridge);
    atomic_fetch_sub(&active_connections, 1);
    return -1;
}

int vp_native_api_open(void) {
    int listener = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    struct sockaddr_vm address = {.svm_len = sizeof(address), .svm_family = AF_VSOCK,
                                 .svm_port = 1339, .svm_cid = VMADDR_CID_ANY};
    if (fcntl(listener, F_SETFD, FD_CLOEXEC) < 0 ||
        bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 128)) {
        int error = errno;
        close(listener);
        errno = error;
        return -1;
    }
    return listener;
}

int vp_native_api_serve(int listener, int (*attach)(int, int)) {
    for (;;) {
        int peer = accept(listener, NULL, NULL);
        if (peer < 0 && errno == EINTR) continue;
        if (peer < 0) return -1;
        vp_vsock_bridge(peer, attach);
    }
}
