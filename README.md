ssh_forward
=====

Fork of OTP `ssh` application with support for port forwarding.
Work in progress.

Current status:

- [x] remote port forwarding, ssh option `-R`
- [x] local port forwarding, server side, ssh option `-L`
- [x] local port forwarding, client side, ssh option `-L`
- [x] remote port forwarding, client side, ssh option `-R`

Build
-----

    $ rebar3 compile

Usage Examples
--------------

Setup for testing, generate host and user keys, OTP ssh doesn't support OpenSSH2 file formats yet,
so we convert them to PEM:

``` bash
function pem_rsa {
  ssh-keygen -t rsa -N '' -f ${1}
  cp ${1} ${1}_ossh2
  cp ${1}.pub ${1}.pub_ossh2
  ssh-keygen -p -m PEM -N '' -f ${1}
  pem=$(ssh-keygen -e -m PEM -f ${1}.pub)
  echo $pem > $1.pub
}

mkdir -p /tmp/ssh_daemon/
mkdir -p /tmp/otptest_user/.ssh
pem_rsa /tmp/ssh_daemon/ssh_host_rsa_key

pem_rsa /tmp/otptest_user/.ssh/id_rsa
cat /tmp/otptest_user/.ssh/id_rsa.pub_ossh2 > /tmp/otptest_user/.ssh/authorized_keys

```

We will use simple `netcat` echo server:

``` bash
ncat -e /bin/cat -k -l 9998
```

Start sshd in Erlang shell:

``` erlang
{ok, Sshd} = ssh:daemon(8989, [{system_dir, "/tmp/ssh_daemon/"}, {user_dir, "/tmp/otptest_user/.ssh"}]).
```

Start client in Erlang shell:

``` erlang
{ok, C} = ssh:connect(loopback, 8989, [{user_dir, "/tmp/otptest_user/.ssh/"}, {silently_accept_hosts, true}]).
```

**Forwarding remote ports**

Forward port `9999` from server to port `9998` on client:

``` erlang
{ok, AssignedPort} = ssh:tcpip_forward(C, "localhost", 9999, "localhost", 9998).
```
the same command in `ssh` would be:

``` bash
ssh -p 8989  -i /tmp/otptest_user/.ssh/id_rsa -o UserKnownHostsFile=/tmp/otptest_user/.ssh/known_hosts \
    -R 9999:localhost:9998 localhost
```

**Forwarding local ports**

Forward port `9999` from client to port `9998` on server:

``` erlang
{ok, AssignedPort} = ssh:direct_tcpip(C, "localhost", 9999, "localhost", 9998).
```

the same command in `ssh` would be:

``` bash
ssh -p 8989  -i /tmp/otptest_user/.ssh/id_rsa -o UserKnownHostsFile=/tmp/otptest_user/.ssh/known_hosts \
    -L 9999:localhost:9998 localhost
```

** Testing **

``` bash
time yes | ncat -v localhost 9999
```
