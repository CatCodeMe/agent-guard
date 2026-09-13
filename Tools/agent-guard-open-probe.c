#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/*
 * A deliberately small, read-only helper for validating the macOS
 * EndpointSecurity path. Add the compiled executable as a protected CLI in
 * Agent Guard, add the same test file as a blocked rule, then run this helper.
 * It never creates or changes the target file.
 */
int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s /path/to/test-file\n", argv[0]);
        return 64;
    }

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("open");
        return errno == EACCES || errno == EPERM ? 13 : 1;
    }

    unsigned char byte = 0;
    ssize_t count = read(fd, &byte, 1);
    close(fd);
    if (count < 0) {
        perror("read");
        return 1;
    }
    printf("opened %s (%zd byte read)\n", argv[1], count);
    return 0;
}
