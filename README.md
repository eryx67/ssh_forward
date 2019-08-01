ssh_forward
=====

Fork of OTP `ssh` application with support for port forwarding.
Work in progress.

Current status:

- [x] remote port forwarding, ssh option `-R`
- [x] local port forwarding, server side, ssh option `-L`
- [ ] local port forwarding, client side, ssh option `-L`

Build
-----

    $ rebar3 compile
