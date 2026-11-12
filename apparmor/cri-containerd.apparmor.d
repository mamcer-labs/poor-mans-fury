# containerd's default container profile, plus the stacked peer in the
# same-container signal and ptrace rules (the two lines marked "Workaround").
#
# Installed on rathma as /etc/apparmor.d/cri-containerd.apparmor.d.
#
# Why: Ubuntu 26.04 sets kernel.apparmor_restrict_unprivileged_unconfined=1, so
# runc's switch into this profile becomes a stack and container processes are
# labeled "cri-containerd.apparmor.d//&unconfined". containerd's rules only
# allow the plain name, so every signal between processes of one container is
# denied: Postgres can't signal its checkpointer ("could not signal for
# checkpoint: Permission denied"), gosu spins, and Go programs (Vault,
# Navidrome...) lose their SIGURG preemption signals.
#
#   https://github.com/containerd/containerd/issues/14485
#   https://github.com/k3s-io/k3s/issues/13625
#
# containerd only loads its built-in profile when none with this name is
# loaded yet, and apparmor.service loads /etc/apparmor.d at boot, before k3s,
# so this copy replaces it. Everything except the two "Workaround" lines is
# contrib/apparmor/template.go of containerd v2.3.2 (k3s v1.36.2+k3s1),
# rendered as containerd renders it here (abi 3.0, tunables/global,
# abstractions/base, k3s running unconfined, no rootlesskit).
#
# Remove it (and reboot) once the pinned k3s ships containerd with the fix
# (containerd PR #14487). If k3s upgrades containerd before that, diff this
# file against the new template.go and carry the changes over.

abi <abi/3.0>,

#include <tunables/global>

profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=unconfined,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=cri-containerd.apparmor.d,
  # Workaround: the same, for the stacked label of the container's processes.
  signal (send,receive) peer="cri-containerd.apparmor.d//&unconfined",

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,
  # Workaround: the same, for the stacked label of the container's processes.
  ptrace (trace,tracedby,read,readby) peer="cri-containerd.apparmor.d//&unconfined",
}
