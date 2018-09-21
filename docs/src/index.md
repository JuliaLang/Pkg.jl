# **1.** Introduction

Pkg is the standard package manager for Julia 1.0 and newer. Unlike traditional
package managers, which install and manage a single global set of packages, Pkg
is designed around “environments”: independent sets of packages that can be
local to an individual project or shared and selected by name. The exact set of
packages and versions in an environment is captured in a _manifest file_ which
can be checked into a project repository and tracked in version control,
significantly improving reproducibility of projects. If you’ve ever tried to run
code you haven’t used in a while only to find that you can’t get anything to
work because you’ve updated or uninstalled some of the packages your project was
using, you’ll understand the motivation for this approach. In Pkg, since each
project maintains its own independent set of package versions, you’ll never have
this problem again. Moreover, if you check out a project on a new system, you
can simply materialize the environment described by its manifest file and
immediately be up and running with a known-good set of dependencies.

Since environments are managed and updated independently from each other,
“dependency hell” is significantly alleviated in Pkg. If you want to use the
latest and greatest version of some package in a new project but you’re stuck on
an older version in a different project, that’s no problem – since they have
separate environments they can just use different versions, which are both
installed at the same time in different locations on your system. The location
of each package version is canonical, so when environments use the same versions
of packages, they can share installations, avoiding unnecessary duplication of
the package. Old package versions that are no longer used by any environments
are periodically “garbage collected” by the package manager.

Pkg’s approach to local environments may be familiar to people who have used
Python’s `virtualenv` or Ruby’s `bundler`. In Julia, instead of hacking the
language’s code loading mechanisms to support environments, we have the benefit
that Julia natively understands them. In addition, Julia environments are
“stackable”: you can overlay one environment with another and thereby have
access to additional packages outside of the primary environment. This makes it
easy to work on a project, which provides the primary environment, while still
having access to all your usual dev tools like profilers, debuggers, and so on,
just by having an environment including these dev tools later in the load path.

Last but not least, Pkg is designed to support federated package registries.
This means that it allows multiple registries managed by different parties to
interact seamlessly. In particular, this includes private registries which can
live behind corporate firewalls. You can install and update your own packages
from a private registry with exactly the same tools and workflows that you use
to install and manage official Julia packages. If you urgently need to apply a
hotfix for a public package that’s critical to your company’s product, you can
tag a private version of it in your company’s internal registry and get a fix to
your developers and ops teams quickly and easily without having to wait for an
upstream patch to be accepted and published. Once an official fix is published,
however, you can just upgrade your dependencies and you'll be back on an
official release again.
