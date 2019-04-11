# **5.** Making changes to an existing package

Julia's package manager is designed so that when you have a package installed, you are already in a position to look at its source code and full development history. You are also able to make changes to packages, commit them using git, and easily contribute fixes and enhancements upstream. Similarly, the system is designed so that if you want to create a new package, the simplest way to do so is within the infrastructure provided by the package manager.

## [Initial Setup](@id man-initial-setup)

Since packages are git repositories, before doing any package development you should setup the following standard global git configuration settings:

```jl
shell> git config --global user.name "FULL NAME"
shell> git config --global user.email "EMAIL"
```

where `FULL NAME` is your actual full name (spaces are allowed between the double quotes) and `EMAIL` is your actual email address. Although it isn't necessary to use [GitHub](https://github.com/) to create or publish Julia packages, most Julia packages as of writing this are hosted on GitHub and the package manager knows how to format origin URLs correctly and otherwise work with the service smoothly. We recommend that you create a [free account](https://github.com/join) on GitHub and then do:

```jl
shell> git config --global github.user "USERNAME"
```

where `USERNAME` is your actual GitHub user name. Once you do this, the package manager knows your GitHub user name and can configure things accordingly. You should also [upload](https://github.com/login?return_to=https%3A%2F%2Fgithub.com%2Fsettings%2Fssh) your public SSH key to GitHub and set up an [SSH agent](https://linux.die.net/man/1/ssh-agent) on your development machine so that you can push changes with minimal hassle. In the future, we will make this system extensible and support other common git hosting options like [BitBucket](https://bitbucket.org) and allow developers to choose their favorite. Since the package development functions has been moved to the [PkgDev](https://github.com/JuliaLang/PkgDev.jl) package, you need to run `Pkg.add("PkgDev"); import PkgDev` to access the functions starting with `PkgDev.` in the document below.

### Documentation changes

If you want to improve the online documentation of a package, the easiest approach (at least for small changes) is to use GitHub's online editing functionality. First, navigate to the repository's GitHub "home page," find the file (e.g., `README.md`) within the repository's folder structure, and click on it. You'll see the contents displayed, along with a small "pencil" icon in the upper right hand corner. Clicking that icon opens the file in edit mode. Make your changes, write a brief summary describing the changes you want to make (this is your *commit message*), and then hit "Propose file change." Your changes will be submitted for consideration by the package owner(s) and collaborators.

For larger documentation changes--and especially ones that you expect to have to update in response to feedback--you might find it easier to use the procedure for code changes described below.

### Code changes

#### Executive summary

Here we assume you've already set up git on your local machine and have a GitHub account (see above). Let's imagine you're fixing a bug in the `Images` package:

```jl
Pkg.checkout("Images")           # check out the master branch
<here, make sure your bug is still a bug and hasn't been fixed already>
cd(Pkg.dir("Images"))
;git checkout -b myfixes         # create a branch for your changes
<edit code>                      # be sure to add a test for your bug
Pkg.test("Images")               # make sure everything works now
;git commit -a -m "Fix foo by calling bar"   # write a descriptive message
using PkgDev
PkgDev.submit("Images")
```

The last line will present you with a link to submit a pull request to incorporate your changes.

#### Detailed description

If you want to fix a bug or add new functionality, you want to be able to test your changes before you submit them for consideration. You also need to have an easy way to update your proposal in response to the package owner's feedback. Consequently, in this case the strategy is to work locally on your own machine; once you are satisfied with your changes, you submit them for consideration. This process is called a *pull request* because you are asking to "pull" your changes into the project's main repository. Because the online repository can't see the code on your private machine, you first *push* your changes to a publicly-visible location, your own online *fork* of the package (hosted on your own personal GitHub account).

Let's assume you already have the `Foo` package installed. In the description below, anything starting with `Pkg.` or `PkgDev.` is meant to be typed at the Julia prompt; anything starting with `git` is meant to be typed in [julia's shell mode](@ref man-shell-mode) (or using the shell that comes with your operating system). Within Julia, you can combine these two modes:

```jl
julia> cd(Pkg.dir("Foo"))          # go to Foo's folder

shell> git command arguments...    # command will apply to Foo
```

Now suppose you're ready to make some changes to `Foo`. While there are several possible approaches, here is one that is widely used:

  * From the Julia prompt, type [`Pkg.checkout("Foo")`](@ref). This ensures you're running the latest code (the `master` branch), rather than just whatever "official release" version you have installed. (If you're planning to fix a bug, at this point it's a good idea to check again whether the bug has already been fixed by someone else. If it has, you can request that a new official release be tagged so that the fix gets distributed to the rest of the community.) If you receive an error `Foo is dirty, bailing`, see [Dirty packages](@ref) below.
  * Create a branch for your changes: navigate to the package folder (the one that Julia reports from [`Pkg.dir("Foo")`](@ref)) and (in shell mode) create a new branch using `git checkout -b <newbranch>`, where `<newbranch>` might be some descriptive name (e.g., `fixbar`). By creating a branch, you ensure that you can easily go back and forth between your new work and the current `master` branch (see [https://git-scm.com/book/en/v2/Git-Branching-Branches-in-a-Nutshell](https://git-scm.com/book/en/v2/Git-Branching-Branches-in-a-Nutshell)).

    If you forget to do this step until after you've already made some changes, don't worry: see [more detail about branching](@ref man-branch-post-hoc) below.
  * Make your changes. Whether it's fixing a bug or adding new functionality, in most cases your change should include updates to both the `src/` and `test/` folders. If you're fixing a bug, add your minimal example demonstrating the bug (on the current code) to the test suite; by contributing a test for the bug, you ensure that the bug won't accidentally reappear at some later time due to other changes. If you're adding new functionality, creating tests demonstrates to the package owner that you've made sure your code works as intended.
  * Run the package's tests and make sure they pass. There are several ways to run the tests:

      * From Julia, run [`Pkg.test("Foo")`](@ref): this will run your tests in a separate (new) `julia` process.
      * From Julia, `include("runtests.jl")` from the package's `test/` folder (it's possible the file has a different name, look for one that runs all the tests): this allows you to run the tests repeatedly in the same session without reloading all the package code; for packages that take a while to load, this can be much faster. With this approach, you do have to do some extra work to make [changes in the package code](@ref man-workflow-tips).
      * From the shell, run `julia ../test/runtests.jl` from within the package's `src/` folder.

  * Commit your changes: see [https://git-scm.com/book/en/v2/Git-Basics-Recording-Changes-to-the-Repository](https://git-scm.com/book/en/v2/Git-Basics-Recording-Changes-to-the-Repository).
  * Submit your changes: From the Julia prompt, type `PkgDev.submit("Foo")`. This will push your changes to your GitHub fork, creating it if it doesn't already exist. (If you encounter an error, [make sure you've set up your SSH keys](@ref man-initial-setup).) Julia will then give you a hyperlink; open that link, edit the message, and then click "submit." At that point, the package owner will be notified of your changes and may initiate discussion. (If you are comfortable with git, you can also do these steps manually from the shell.)
  * The package owner may suggest additional improvements. To respond to those suggestions, you can easily update the pull request (this only works for changes that have not already been merged; for merged pull requests, make new changes by starting a new branch):

      * If you've changed branches in the meantime, make sure you go back to the same branch with `git checkout fixbar` (from shell mode) or [`Pkg.checkout("Foo", "fixbar")`](@ref) (from the Julia prompt).
      * As above, make your changes, run the tests, and commit your changes.
      * From the shell, type `git push`.  This will add your new commit(s) to the same pull request; you should see them appear automatically on the page holding the discussion of your pull request.

    One potential type of change the owner may request is that you squash your commits. See [Squashing](@ref man-squashing-and-rebasing) below.

### Dirty packages

If you can't change branches because the package manager complains that your package is dirty, it means you have some changes that have not been committed. From the shell, use `git diff` to see what these changes are; you can either discard them (`git checkout changedfile.jl`) or commit them before switching branches.  If you can't easily resolve the problems manually, as a last resort you can delete the entire `"Foo"` folder and reinstall a fresh copy with [`Pkg.add("Foo")`](@ref). Naturally, this deletes any changes you've made.

### [Making a branch *post hoc*](@id man-branch-post-hoc)

Especially for newcomers to git, one often forgets to create a new branch until after some changes have already been made. If you haven't yet staged or committed your changes, you can create a new branch with `git checkout -b <newbranch>` just as usual--git will kindly show you that some files have been modified and create the new branch for you. *Your changes have not yet been committed to this new branch*, so the normal work rules still apply.

However, if you've already made a commit to `master` but wish to go back to the official `master` (called `origin/master`), use the following procedure:

  * Create a new branch. This branch will hold your changes.
  * Make sure everything is committed to this branch.
  * `git checkout master`. If this fails, *do not* proceed further until you have resolved the problems, or you may lose your changes.
  * *Reset*`master` (your current branch) back to an earlier state with `git reset --hard origin/master` (see [https://git-scm.com/blog/2011/07/11/reset.html](https://git-scm.com/blog/2011/07/11/reset.html)).

This requires a bit more familiarity with git, so it's much better to get in the habit of creating a branch at the outset.

### [Squashing and rebasing](@id man-squashing-and-rebasing)

Depending on the tastes of the package owner (s)he may ask you to "squash" your commits. This is especially likely if your change is quite simple but your commit history looks like this:

```jl
WIP: add new 1-line whizbang function (currently breaks package)
Finish whizbang function
Fix typo in variable name
Oops, don't forget to supply default argument
Split into two 1-line functions
Rats, forgot to export the second function
...
```

This gets into the territory of more advanced git usage, and you're encouraged to do some reading ([https://git-scm.com/book/en/v2/Git-Branching-Rebasing](https://git-scm.com/book/en/v2/Git-Branching-Rebasing)). However, a brief summary of the procedure is as follows:

  * To protect yourself from error, start from your `fixbar` branch and create a new branch with `git checkout -b fixbar_backup`.  Since you started from `fixbar`, this will be a copy. Now go back to the one you intend to modify with `git checkout fixbar`.
  * From the shell, type `git rebase -i origin/master`.
  * To combine commits, change `pick` to `squash` (for additional options, consult other sources). Save the file and close the editor window.
  * Edit the combined commit message.

If the rebase goes badly, you can go back to the beginning to try again like this:

```jl
shell> git checkout fixbar
shell> git reset --hard fixbar_backup
```

Now let's assume you've rebased successfully. Since your `fixbar` repository has now diverged from the one in your GitHub fork, you're going to have to do a *force push*:

  * To make it easy to refer to your GitHub fork, create a "handle" for it with `git remote add myfork https://github.com/myaccount/Foo.jl.git`, where the URL comes from the "clone URL" on your GitHub fork's page.
  * Force-push to your fork with `git push myfork +fixbar`. The `+` indicates that this should replace the `fixbar` branch found at `myfork`.
