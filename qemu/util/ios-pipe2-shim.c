/*
 * Compatibility implementation for the pipe2 symbol referenced by the
 * prebuilt iOS GLib archive. The iPhoneOS SDK does not export pipe2.
 *
 * iOS provides pipe() and fcntl(); use those for O_CLOEXEC/O_NONBLOCK.
 * Unlike the Linux pipe2 syscall, setting the flags here is not atomic.
 */
#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

int pipe2(int fds[2], int flags)
{
    const int supported = O_CLOEXEC | O_NONBLOCK;
    if ((flags & ~supported) != 0) {
        errno = EINVAL;
        return -1;
    }

    if (pipe(fds) < 0) {
        return -1;
    }

    for (int i = 0; i < 2; ++i) {
        if (flags & O_CLOEXEC) {
            int fd_flags = fcntl(fds[i], F_GETFD);
            if (fd_flags < 0 || fcntl(fds[i], F_SETFD,
                                        fd_flags | FD_CLOEXEC) < 0) {
                goto error;
            }
        }

        if (flags & O_NONBLOCK) {
            int status = fcntl(fds[i], F_GETFL);
            if (status < 0 || fcntl(fds[i], F_SETFL,
                                      status | O_NONBLOCK) < 0) {
                goto error;
            }
        }
    }
    return 0;

error:
    {
        int saved_errno = errno;
        close(fds[0]);
        close(fds[1]);
        errno = saved_errno;
        return -1;
    }
}
#endif
