/* Rotate only the regular file actually attached to this stream. Called at a
 * coarse interval, under the stdio lock, so regular writes keep their ordering. */
#ifndef DS_LOG_ROTATION_H
#define DS_LOG_ROTATION_H
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
static int ds_rotate_log(FILE *stream, const char *path, size_t limit)
{
    if (!path || !*path) return 0;
    int result = 0; struct stat fdst, pst;
    flockfile(stream);
    int fd = fileno(stream);
    if (fstat(fd, &fdst) || !S_ISREG(fdst.st_mode) || (uint64_t)fdst.st_size < limit ||
        lstat(path, &pst) || !S_ISREG(pst.st_mode) || pst.st_ino != fdst.st_ino || pst.st_dev != fdst.st_dev) goto done;
    char *old = malloc(strlen(path) + 16);
    if (!old) { result = -1; goto done; }
    sprintf(old, "%s.previous", path);
    if (fflush(stream) || rename(path, old)) { free(old); result = -1; goto done; }
    int next = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, fdst.st_mode & 0777);
    if (next < 0 || dup2(next, fd) < 0) { rename(old, path); result = -1; }
    else { clearerr(stream); result = 1; }
    if (next >= 0) close(next);
    free(old);
done:
    funlockfile(stream);
    return result;
}
#endif
