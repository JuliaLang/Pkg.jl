# **5.** Making changes to an existing package

Julia's package manager is designed so that when you have a package installed, it makes it easy to download its source code and full development history. You are also able to make changes to packages, commit them using git, and easily contribute fixes and enhancements upstream.

## [Initial Setup](@id man-initial-setup)

Since packages are git repositories, before doing any package development you should setup the following standard global git configuration settings:

```jl
shell> git config --global user.name "FULL NAME"
shell> git config --global user.email "EMAIL"
```

where `FULL NAME` is your actual full name (spaces are allowed between the double quotes) and `EMAIL` is your actual email address. Although it isn't necessary to use [GitHub](https://github.com/) to create or publish Julia packages, most Julia packages as of writing this are hosted on GitHub and the package manager knows how to format origin URLs correctly and otherwise work with the service smoothly. We recommend that you create a [free account](https://github.com/join) on GitHub and then do:

```jl
shell> git config --global github.user "GITHUB_USERNAME"
```

where `GITHUB_USERNAME` is your actual GitHub user name. Once you do this, the package manager knows your GitHub user name and can configure things accordingly. You should also [upload](https://github.com/login?return_to=https%3A%2F%2Fgithub.com%2Fsettings%2Fssh) your public SSH key to GitHub and set up an [SSH agent](https://linux.die.net/man/1/ssh-agent) on your development machine so that you can push changes with minimal hassle. In the future, we will make this system extensible and support other common git hosting options like [BitBucket](https://bitbucket.org) and allow developers to choose their favorite.

### Documentation changes

If you want to improve the online documentation of a package, the easiest approach for small changes is to use GitHub's online editing functionality. First, navigate to the repository's GitHub "home page," find the file (e.g., `README.md`) within the repository's folder structure, and click on it. You'll see the contents displayed, along with a small "pencil" icon in the upper right hand corner. Clicking that icon opens the file in edit mode. Make your changes, write a brief summary describing the changes you want to make (this is your *commit message*), and then hit "Propose file change." Your changes will be submitted for consideration by the package owner(s) and collaborators.

For larger documentation changes--and especially ones that you expect to have to update in response to feedback--you might find it easier to use the procedure for code changes described below.

### Code changes

#### Executive summary

Here we assume you've already set up git on your local machine and have a GitHub account (see above). Let's imagine you're fixing a bug in the `Example` package. First, fork the project since you don't have permission to push directly to the repository: navigate to the [`Example.jl`](https://github.com/JuliaLang/Example.jl) GitHub page and fork the project using the botton on the top right hand side of the page. Then fix the code and make a pull request (or PR in short).

```jl
(v1.1) pkg> add Example#master           # check out the master branch
(v1.1) pkg> develop --local Example      # make a local copy
# change path to the directory
shell> cd(?)
shell> git remote add fork https://github.com/GITHUB_USERNAME/Example.jl.git  # you can only push changes to your fork
shell> git checkout -b fixbar          # create a branch for your changes
<edit code>                            # be sure to add a test for your bug
(v1.1) pkg> test Example               # make sure everything works now
shell> git commit -a -m "Fix foo by calling bar"   # write a descriptive message
shell> git push fork fixbar
```

Open now your GitHub fork of the project and you are presented with a button to submit a pull request for incorporating your changes into the upstream repository.

#### Detailed description

If you want to fix a bug, add new functionality or improve the documentation, you want to be able to test your changes before you submit them for consideration. You also need to have an easy way to update your proposal in response to the package owner's feedback. Consequently, in this case the strategy is to work locally on your own machine; once you are satisfied with your changes, you submit them for consideration. This process is called a *pull request* because you are asking to "pull" your changes into the project's main repository. Because the online repository can't see the code on your private machine, you first *push* your changes to a publicly-visible location, your own online *fork* of the package (hosted on your own personal GitHub account).

Let's assume you already have the `Example` package installed. In the description below, the prompt `v(1.1) pkg>` indicates the Pkg REPL that is entered from the Julia REPL by typing `]`; the prompt `shell>` (anything starting with `git`) is meant to be typed in [julia's shell mode](@ref Basic Usage) (entered by typing `;`), or using the shell that comes with your operating system. Within Julia, you can combine these two modes:

```jl
(v1.1) pkg> cd(?)          # go to Example's folder

shell> git command arguments...    # command will apply to Foo
```

Now suppose you're ready to make some changes to `Example`. While there are several possible approaches, here is one that is widely used:

  * From the pkg prompt, type [`add Example#master`](@ref repl-add). This ensures you're running the latest code (the `master` branch), rather than just whatever "official release" version you have installed. (If you're planning to fix a bug, at this point it's a good idea to check again whether the bug has already been fixed by someone else. If it has, you can request that a new official release be tagged so that the fix gets distributed to the rest of the community.) If you receive an error `Example is dirty, bailing`, see [Dirty packages](@ref) below.
  * Clone the full git repository for `Example.jl` into a local directory with [`develop --local Example.jl`](@ref repl-develop).
  * Create a branch for your changes: navigate to the package folder (the line starting with Info Path after the command above) and (in shell mode) create a new branch using `git checkout -b <newbranch>`, where `<newbranch>` might be some descriptive name (e.g., `fixbar`). By creating a branch, you ensure that you can easily go back and forth between your new work and the current `master` branch (see [https://git-scm.com/book/en/v2/Git-Branching-Branches-in-a-Nutshell](https://git-scm.com/book/en/v2/Git-Branching-Branches-in-a-Nutshell)).

    If you forget to do this step until after you've already made some changes, don't worry: see [more detail about branching](@ref man-branch-post-hoc) below.
  * Make your changes. Whether it's fixing a bug or adding new functionality, in most cases your change should include updates to both the `src/` and `test/` folders. If you're fixing a bug, add your minimal example demonstrating the bug (on the current code) to the test suite; by contributing a test for the bug, you ensure that the bug won't accidentally reappear at some later time due to other changes. If you're adding new functionality, creating tests demonstrates to the package owner that you've made sure your code works as intended.
  * Run the package's tests and make sure they pass. There are several ways to run the tests:

    + From Pkg-REPL, run [`test Example`](@ref): this will run your tests in a separate (new) `julia` process.
    + From Julia, `include("runtests.jl")` from the package's `test/` folder (it's possible the file has a different name, look for one that runs all the tests): this allows you to run the tests repeatedly in the same session without reloading all the package code; for packages that take a while to load, this can be much faster. With this approach, you do have to do some extra work to make [changes in the package code](@ref man-workflow-tips).
    + From the shell, run `julia ../test/runtests.jl` from within the package's `src/` folder.
  * If you are making substantial changes to the documentation, and the package documentation makes use of a dependency program to generate the documentation (e.g. Documenter.jl), you should test that your changes generate the correct documentation. For example, for `Documenter,jl`, from within the directory `Example.jl/docs`, you would invoke in shell mode `julia -e 'push!(LOAD_PATH,"../src/")' make.jl`
  * Commit your changes: see [https://git-scm.com/book/en/v2/Git-Basics-Recording-Changes-to-the-Repository](https://git-scm.com/book/en/v2/Git-Basics-Recording-Changes-to-the-Repository).
  * To make it easy to refer to your GitHub fork, create a "handle" for it with `git remote add fork https://github.com/GITHUB_USERNAME/Example.jl.git`, where the URL comes from the "clone URL" on your GitHub fork's page.
  * Submit your changes:
    ```
    shell> git push fork fixbar
    ...
    remote: Create a pull request for 'fixbar' on GitHub by visiting:
    remote:      https://github.com/GITHUB_USERNAME/Example.jl/pull/new/fixbar
    ...
    ```
    (If you encounter an error, [make sure you've set up your SSH keys](@ref man-initial-setup).)
    `git` reminds you to create a PR and will give you a hyperlink: open that link, edit the message, and then click "submit." At that point, the package owner will be notified of your changes and may initiate discussion.
    * Alternatively, for committing and pushinig changes, one use the graphical interface `git gui` that by default comes with `git`.
  * The package owner may suggest additional improvements. To respond to those suggestions, you can easily update the pull request (this only works for changes that have not already been merged; for merged pull requests, make new changes by starting a new branch):

    + If you've changed branches in the meantime, make sure you go back to the same branch with `git checkout fixbar` (from shell mode) or [`Pkg.checkout("Foo", "fixbar")`](@ref) (from the Julia prompt).
    + As above, make your changes, run the tests, and commit your changes.
    + From the shell, type `git push fork fixbar`. This will add your new commit(s) to the same pull request; you should see them appear automatically on the page holding the discussion of your pull request.

    One potential type of change the owner may request is that you squash your commits. See [Squashing](@ref man-squashing-and-rebasing) below.

### Dirty packages

If you can't change branches because the package manager complains that your package is dirty, it means you have some changes that have not been committed. From the shell, use `git diff` to see what these changes are; you can either discard them (`git checkout changedfile.jl`) or commit them before switching branches.  If you can't easily resolve the problems manually, as a last resort you can delete the entire `"Example"` folder and download a fresh copy with `develop --local Example`. Naturally, this deletes any changes you've made.

### [Making a branch *post hoc*](@id man-branch-post-hoc)

Especially for newcomers to git, one often forgets to create a new branch until after some changes have already been made. If you haven't yet staged or committed your changes, you can create a new branch with `git checkout -b <newbranch>` just as usual--git will kindly show you that some files have been modified and create the new branch for you. *Your changes have not yet been committed to this new branch*, so the normal work rules still apply.

However, if you've already made a commit to `master` but wish to go back to the official `master` (called `origin/master`), use the following procedure:

  * Create a new branch. This branch will hold your changes.
  * Make sure everything is committed to this branch.
  * `git checkout master`. If this fails, *do not* proceed further until you have resolved the problems, or you may lose your changes.
  * *Reset*`master` (your current branch) back to an earlier state with `git reset --hard origin/master` (see [Git Tools - Reset Demystified](https://git-scm.com/book/en/v2/Git-Tools-Reset-Demystifiedl)).

This requires a bit more familiarity with git, so it's much better to get in the habit of creating a branch at the outset.

### [Squashing and rebasing](@id man-squashing-and-rebasing)

Depending on the tastes of the package owner (s)he may ask you to "squash" your commits. This is especially likely if your change is quite simple but your commit history looks like this:

```jl
WIP: add new 1-line whizbang function (currently breaks package)
Finish whizbang function
Fix typo in variable name
Whoops, don't forget to supply default argument
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

Now let's assume you've rebased successfully. Since your `fixbar` repository has now diverged from the one in your GitHub fork, you're going to have to do a *force push* with `git push fork +fixbar`. The `+` indicates that this should replace the `fixbar` branch found at `fork`.
