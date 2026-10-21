/* Noninstalled fixture: prevent the real torrent engine from contacting any
 * non-loopback peer, tracker or discovery service during integration tests. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
static int local(const struct sockaddr *a) {
  if (!a || a->sa_family == AF_UNIX)
    return 1;
  if (a->sa_family == AF_INET)
    return (ntohl(((const struct sockaddr_in *)a)->sin_addr.s_addr) >> 24) ==
           127;
  if (a->sa_family == AF_INET6)
    return IN6_IS_ADDR_LOOPBACK(&((const struct sockaddr_in6 *)a)->sin6_addr);
  return 0;
}
int connect(int fd, const struct sockaddr *a, socklen_t n) {
  if (!local(a)) {
    errno = ENETUNREACH;
    return -1;
  }
  int (*real)(int, const struct sockaddr *, socklen_t) =
      dlsym(RTLD_NEXT, "connect");
  return real(fd, a, n);
}
int bind(int fd, const struct sockaddr *a, socklen_t n) {
  struct sockaddr_storage copy;
  if (n > sizeof copy) {
    errno = EINVAL;
    return -1;
  }
  memcpy(&copy, a, n);
  if (a->sa_family == AF_INET)
    ((struct sockaddr_in *)&copy)->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (a->sa_family == AF_INET6)
    ((struct sockaddr_in6 *)&copy)->sin6_addr = in6addr_loopback;
  int (*real)(int, const struct sockaddr *, socklen_t) =
      dlsym(RTLD_NEXT, "bind");
  return real(fd, (const struct sockaddr *)&copy, n);
}
ssize_t sendto(int fd, const void *p, size_t n, int f, const struct sockaddr *a,
               socklen_t l) {
  if (!local(a)) {
    errno = ENETUNREACH;
    return -1;
  }
  ssize_t (*real)(int, const void *, size_t, int, const struct sockaddr *,
                  socklen_t) = dlsym(RTLD_NEXT, "sendto");
  return real(fd, p, n, f, a, l);
}
ssize_t sendmsg(int fd, const struct msghdr *m, int f) {
  if (!local(m->msg_name)) {
    errno = ENETUNREACH;
    return -1;
  }
  ssize_t (*real)(int, const struct msghdr *, int) =
      dlsym(RTLD_NEXT, "sendmsg");
  return real(fd, m, f);
}
int sendmmsg(int fd, struct mmsghdr *m, unsigned int n, int f) {
  for (unsigned int i = 0; i < n; i++)
    if (!local(m[i].msg_hdr.msg_name)) {
      errno = ENETUNREACH;
      return -1;
    }
  int (*real)(int, struct mmsghdr *, unsigned int, int) =
      dlsym(RTLD_NEXT, "sendmmsg");
  return real(fd, m, n, f);
}
int setsockopt(int fd, int level, int option, const void *value,
               socklen_t size) {
  int (*real)(int, int, int, const void *, socklen_t) =
      dlsym(RTLD_NEXT, "setsockopt");
  if (level == SOL_SOCKET && option == SO_BINDTODEVICE)
    return real(fd, level, option, "lo", 3);
  return real(fd, level, option, value, size);
}
#include <netdb.h>
int getaddrinfo(const char *name, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
  if (name && strcmp(name, "localhost") && strcmp(name, "::1") &&
      strncmp(name, "127.", 4))
    return EAI_NONAME;
  int (*real)(const char *, const char *, const struct addrinfo *,
              struct addrinfo **) = dlsym(RTLD_NEXT, "getaddrinfo");
  return real(name, service, hints, result);
}
