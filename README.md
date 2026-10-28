# Vacite

A statically typed compile-time analysed scripting and config language, inspired by Lua and Zig.

## Why statically typed?

Most scripting languages are dynamically typed, with no way to enforce static typing. Dynamic types
are the default, and it takes effort to specify types, such as having to use comments in Lua. This
is a huge footgun, as almost always you will know exactly the shape of your data.

Vacite attempts to fix this with an approach similar to TypeScript, as well as all systems
languages, where all values have to have a definite type.

This removes a huge number of bugs, as type errors are now checked at compile time, and not at
runtime where bugs could go unidentified easily.

## Building from source

Dependencies:
- [Zig](https://ziglang.org) toolchain v0.17.x

Clone this repository locally, then build:

```sh
git clone https://github.com/SolarFlurry/vacite.git
zig build
```

The output will be in `zig-out/bin/vacite`

To build with release:

```sh
zig build --release=fast
```
