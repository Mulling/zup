# zup

[zigup](https://github.com/marler8997/zigup) fork, download and manage zig compilers.

# How to Install

TODO:

# Usage

```sh
# fetch a compiler and set it as the default
zup <version>
zup master
zup 0.6.0

# fetch a compiler only (do not set it as default)
zup fetch <version>
zup fetch master

# print the default compiler version
zup default

# set the default compiler
zup default <version>

# set the default compiler from a path
zup default zig/build

# unset the default compiler (for using a global installation)
zup undefine

# list the installed compiler versions
zup list

# clean compilers that are not the default, not master, and not marked to keep. when a version is specified, it will clean that version
zup clean [<version>]

# mark a compiler to keep
zup keep <version>

# run a specific version of the compiler
zup run <version> <args>...
```

# How the compilers are managed

`zup` stores each compiler in `$ZIGUP_INSTALL_DIR`, in a versioned subdirectory. The default install directory is `$HOME/.zigup/cache`.

`zup` makes the zig available by creating a symlink at `$ZIGUP_INSTALL_DIR/<version>` and `$ZIGUP_DIR/default` which points to the current active default compiler.

Configuration on done during the first use of zup and the generated environment is installed at `$ZIGUP_DIR/env`.

# Building

Run `zig build` to build, `zig build test` to test and install with:
```sh
# install to a bin directory with
cp zig-out/bin/zup BIN_PATH
```

# Building Zigup

`zup` is currently built/tested using zig 0.13.0+.

# TODO

- [ ] Download to memory
- [ ] Use `std.tar` (Unix)
- [ ] `zup system` and `zup default system`

# Dependencies

On linux and macos, zigup depends on `tar` to extract the compiler archive files (this may change in the future).
