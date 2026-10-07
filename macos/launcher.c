// Herald.app's executable: runs its arguments as a child and waits.
//
//   Herald.app/Contents/MacOS/herald /path/to/ruby /path/to/bin/herald serve
//
// macOS remembers "may read the Messages database" (Full Disk Access) and
// "may control Messages" (Automation) against the code identity of the
// *responsible process*: for a launchd job, the program launchd started, on
// behalf of everything beneath it. Started bare, that is ruby, and a ruby
// from a version manager is ad-hoc signed: its identity is a hash of the
// binary, and the grants die with every rebuild. Started from here it is this
// bundle, signed with a certificate that does not change, and ruby and the
// osascript it runs inherit the grants as children.
//
// So the child is spawned, never exec'd: exec would turn this process into
// ruby and hand the questions back to ruby's identity. What is left is to be
// a transparent parent: pass signals down, and exit the way the child did.
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static volatile pid_t child = 0;
static const int forwarded[] = { SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2 };
#define FORWARDED (sizeof(forwarded) / sizeof(forwarded[0]))

static void forward(int sig) {
  if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s program [arguments...]\n", argv[0]);
    return 64;
  }

  // Hold the signals until there is a child to give them to; the child
  // itself starts with nothing blocked.
  sigset_t held, before, none;
  sigemptyset(&held);
  sigemptyset(&none);
  for (size_t i = 0; i < FORWARDED; i++) sigaddset(&held, forwarded[i]);
  sigprocmask(SIG_BLOCK, &held, &before);

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = forward;
  sigemptyset(&action.sa_mask);
  action.sa_flags = SA_RESTART;
  for (size_t i = 0; i < FORWARDED; i++) sigaction(forwarded[i], &action, NULL);

  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  posix_spawnattr_setsigmask(&attributes, &none);
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK);

  pid_t pid;
  int error = posix_spawnp(&pid, argv[1], NULL, &attributes, argv + 1, environ);
  posix_spawnattr_destroy(&attributes);
  if (error != 0) {
    fprintf(stderr, "herald: could not run %s: %s\n", argv[1], strerror(error));
    return error == ENOENT ? 127 : 126;
  }
  child = pid;
  sigprocmask(SIG_SETMASK, &before, NULL);

  int status;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      perror("herald: waitpid");
      return 70;
    }
  }
  return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status);
}
