#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// A one-request server for the acceptance client's transport contract.
int main(int argc, char **argv) {
    if (argc != 3 || strlen(argv[1]) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return 2;
    alarm(5);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strlcpy(address.sun_path, argv[1], sizeof(address.sun_path));
    if (server < 0 || bind(server, (struct sockaddr *)&address, sizeof(address)) || listen(server, 1)) return 3;
    int client = accept(server, NULL, NULL);
    if (client < 0) return 4;
    char buffer[4096];
    while (1) {
        ssize_t count = read(client, buffer, sizeof(buffer));
        if (count <= 0 || memchr(buffer, '\n', (size_t)count)) break;
    }
    const char *reply = "";
    if (!strcmp(argv[2], "ok")) reply = "{\"ok\":true,\"result\":{\"fixture\":true}}\n";
    if (!strcmp(argv[2], "false")) reply = "{\"ok\":false,\"error\":\"fixture failure\"}\n";
    if (!strcmp(argv[2], "invalid")) reply = "not-json\n";
    size_t remaining = strlen(reply);
    while (remaining) {
        ssize_t count = write(client, reply, remaining);
        if (count <= 0) return 5;
        reply += count;
        remaining -= (size_t)count;
    }
    close(client);
    close(server);
    unlink(argv[1]);
    return 0;
}
