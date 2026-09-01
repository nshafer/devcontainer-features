# shellcheck shell=bash
# Sourced, never executed. Unsets the variables that advertise the forwarded sockets.
#
# This file is the header only. install.sh appends one `unset` line per *blocked* channel at build
# time, so what ships is a template and what runs is generated. The list has to follow the blocks:
# a channel this feature leaves open needs its variable, and unsetting it would break the channel
# rather than harden it. See the scrub block in install.sh for the mapping.
#
# Be clear about what this is worth: it is the weakest of the three layers and it is not a control.
# VS Code re-injects these into every process it starts, and any program that wants a path can read
# it back out of /proc. The sockets being unusable is the control; this only stops a tool finding a
# path by accident and stops the paths showing up in a shell someone is looking at.
#
# It earns its place by covering shells the blog's ~/.bashrc edit does not: this file is reached
# from /etc/profile.d (login shells), /etc/bash.bashrc (interactive bash), /etc/zsh/zshenv (all
# zsh) and $BASH_ENV (non-interactive bash, set as the feature's containerEnv). All of those live
# in /etc rather than $HOME on purpose -- a persisted home volume masks whatever the image wrote
# into ~/.bashrc, and the whole scrub would silently vanish on the second rebuild.
#
# No set -u, no exit, nothing slow: $BASH_ENV means this is sourced by every non-interactive bash
# in the container, including the ones inside build scripts.
