# Journey: native WireGuard between two Apple containers

This records the work performed in this session on October 23, 2026, including
the unsuccessful paths and gaps in the process. It is reconstructed from the
conversation, command results, and retained files, rather than a complete
timestamped terminal transcript. Commands below are representative of the actual
steps; the maintained scripts are the source for rerunning the final setup.

## Outcome and scope

Two Alpine Linux containers running under Apple's `container` CLI communicate
through native Linux kernel WireGuard. We built a custom ARM64 kernel and passed
it to each container with `--kernel`. We did not upgrade the installed CLI or
replace its default kernel.

| Property | Final value |
| --- | --- |
| macOS | 26.6.2, build 25G83 |
| CLI | `/usr/local/bin/container`, version 0.1.0, commit 0fd8692 |
| Architecture | ARM64 |
| Peer image | `alpine:3.22` |
| Guest kernel | `6.18.5-wg-testbed` |
| WireGuard implementation | Built into the guest kernel, `CONFIG_WIREGUARD=y` |
| Peer A | `wg-test-a`, eth0 `192.168.64.2`, wg0 `10.77.0.1/32` |
| Peer B | `wg-test-b`, eth0 `192.168.64.3`, wg0 `10.77.0.2/32` |
| Transport | UDP 51820 between the eth0 addresses |
| Tunnel settings | MTU 1420; persistent keepalive 5 seconds |
| Verified | Handshakes, native interface type, and three successful tunnel pings in each direction |

The eth0 addresses are observations from this run, not fixed assignments. The
script discovers them when configuring the tunnel. Only traffic to the other
peer's tunnel address uses wg0; this is not a full-tunnel VPN or a macOS VPN.

## 1. Establishing the goal

The initial question was whether WireGuard could run inside a Linux container
on macOS. The first answer described kernel WireGuard and `wireguard-go` as
possible approaches, then asked which container runtime was intended.

The user chose Apple's `container` CLI, then requested a testbed with two
containers talking to one another. Later, when I proposed a userspace fallback,
the user explicitly clarified that the requirement was a kernel with native
WireGuard. That clarification determined the final implementation.

**Gap:** I treated working VPN connectivity as sufficient and started pursuing
a userspace fallback. I should have resolved the implementation requirement
before spending effort on a replacement kernel that only supported TUN.

## 2. Discovering the actual local runtime

Initial checks found the CLI installed, but `container list` failed with:

```text
failed to list containers
XPC connection error: Connection invalid
```

Running `container system start` brought the API server up. A subsequent
`container list` succeeded and showed no containers.

Several help requests were misleading: `container run --help`,
`container run -h`, and `container system --help` returned top-level help in
this installation. `container help run` and `container help exec` returned
the useful subcommand-specific help. `container system status` was unsupported.

The local run help confirmed support for a per-container kernel:

```text
-k, --kernel <kernel>   Set a custom kernel path
```

It did not list the newer `--cap-add` option. Later inspection inside the
original peers showed a broad effective capability mask, so permissions were
not the observed blocker.

**Gap:** I initially relied on current upstream documentation describing
`CAP_NET_ADMIN` and a configuration with WireGuard enabled. Those facts did not
describe the installed 0.1.0 runtime or its running kernel. The installed
binary's help and the guest's `/proc/config.gz` were the relevant evidence.

## 3. Creating peers and discovering the stock kernel limitation

We created two detached containers:

```sh
container run --name wg-test-a -d alpine:3.22 sleep infinity
container run --name wg-test-b -d alpine:3.22 sleep infinity
```

They received `192.168.64.2` and `192.168.64.3`. We installed
`wireguard-tools`, `iproute2`, `iputils`, and `curl` inside each.

Creating a native interface failed:

```sh
ip link add wg0 type wireguard
# Error: Unknown device type.
```

The tools installed successfully; that did not make WireGuard available in the
guest kernel. Inspection showed:

```text
# CONFIG_WIREGUARD is not set
# CONFIG_TUN is not set
```

There was no `/dev/net/tun`. Creating the device node with `mknod` did not solve
the problem: `ip tuntap add` then failed with `open: No such device`. A device
node provides an entry point to an existing driver; it cannot supply a missing
kernel driver.

One diagnostic also used `rg` inside Alpine, where it was not installed. We
used `grep` for subsequent guest configuration checks.

Separately, A successfully pinged B's eth0 address: two packets sent, two
received. That established basic container-to-container reachability before
testing WireGuard.

**Lesson:** Check kernel features and ordinary peer reachability before
installing VPN packages or generating configuration. The failure was below
the WireGuard configuration layer.

## 4. The unsuccessful Kata kernel detour

I installed `wireguard-go` in the initial peers and investigated a kernel with
TUN support. Apple's current runtime configuration documentation referenced
a Kata kernel distribution, so I downloaded:

```text
kata-static-3.32.0-arm64.tar.zst
```

The archive was about 664 MiB. A host-side `curl` request could not resolve
`github.com`, while networking from the containers worked. To make progress,
we created a temporary `wg-kernel-fetch` container with the lab's `kernel/`
directory mounted at `/output`, then downloaded from inside it.

The archive's SHA-256 matched the digest listed in the Apple documentation:

```text
8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5
```

The first extraction failed because the requested archive member omitted its
leading `./`. Listing the archive with `tar -tf` revealed the exact path; using
that path extracted `vmlinux-6.18.35-197-debug` successfully.

We stopped and deleted the initial peers and recreated them with this kernel.
The kernel booted, but native interface creation still failed. Its live
configuration showed:

```text
# CONFIG_WIREGUARD is not set
CONFIG_TUN=y
```

A temporary TUN interface could now be created and deleted. This kernel could
support a userspace implementation, but it did not meet the native WireGuard
requirement. `wireguard-go` was installed in these intermediate peers; no
working userspace tunnel was established before the user interrupted and
specified native WireGuard.

**Gaps:** The download was large and did not provide the required feature. A
bootable replacement kernel is not evidence that it enables WireGuard. I
should have inspected the candidate's configuration before treating it as a
solution, and should have avoided changing the implementation target.

The temporary downloader was deleted. The Kata archive and extracted kernel
were removed after the native build succeeded; an empty directory hierarchy
may remain under `kernel/opt/`.

## 5. Script failures encountered along the way

The first `lab.sh up` reached peer creation and package installation, then
failed when calling itself to configure the tunnel:

```text
./wireguard-testbed/lab.sh: No such file or directory
```

The script had changed into its own directory and then invoked the original
relative `$0`, which no longer resolved there. It was corrected to invoke
`./lab.sh configure` after the directory change.

An initial scripted teardown returned `Operation not permitted`. Its cause
was not established. The subsequent startup failed because `wg-test-a`
already existed. Explicit `container stop` and `container delete` commands
then succeeded for both peers. This is evidence of incomplete teardown, not
evidence that an approval escalation or runtime upgrade was required.

Some tunnel tests were started while the setup had already failed; those
pings did not have a configured tunnel to test. Later validation was performed
after a successful setup exit.

**Lesson:** Keep setup and validation sequential, and make lifecycle scripts
clear about partial state. The final script fixes the path bug but still
does not automatically recover from every partial creation or teardown.

## 6. Building the native WireGuard kernel

After the user's correction, we consulted Apple's kernel build instructions,
Makefile, build script, and ARM64 configuration. The upstream Makefile used
Linux 6.18.5. We used that version and adapted the build to an Alpine builder
instead of reproducing Apple's Ubuntu-based toolchain image.

The host reported 32 GiB of memory and 10 CPUs. We launched a dedicated
`wg-kernel-build` container with 8 CPUs and 8 GiB of memory:

```sh
container run -d --name wg-kernel-build --cpus 8 --memory 8g \
  -v /Users/balaa/codex/wireguard-testbed:/lab \
  -v /Users/balaa/codex/wireguard-testbed/kernel:/kernel \
  alpine:3.22 sh /lab/build-kernel.sh
```

The builder:

1. Installed compilation tools and dependencies.
2. Downloaded `linux-6.18.5.tar.xz` from kernel.org.
3. Checked the archive against kernel.org's SHA-256 listing.
4. Downloaded Apple's `config-arm64` from the containerization repository.
5. Unpacked source into the builder's `/kbuild` filesystem.
6. Enabled built-in WireGuard and TUN and set a recognizable kernel suffix.
7. Ran `olddefconfig` and asserted that `CONFIG_WIREGUARD=y` remained enabled.
8. Compiled the ARM64 `Image`, retaining the build log.
9. Copied the image and final configuration to the shared host directory.

The key configuration and build steps were:

```sh
scripts/config --enable WIREGUARD --enable TUN \
  --set-str LOCALVERSION '-wg-testbed'
make ARCH=arm64 olddefconfig
grep -qx 'CONFIG_WIREGUARD=y' .config
make ARCH=arm64 -j8 Image
```

The output is an ARM64 boot `Image` stored with the filename
`kernel/vmlinux-native-wireguard`; the filename does not mean it is the
unstripped ELF build output. The retained image is about 27 MiB.

Recorded hashes:

| Artifact | SHA-256 |
| --- | --- |
| Linux source archive | `189d1f409cef8d0d234210e04595172df392f8cb297e14b447ed95720e2fd940` |
| Downloaded Apple config | `dedb03de6d686534efbca3a90bac304721e818bd96bc421b4d2213724a4e260b` |
| Native kernel image | `241bd538d3dfa6eb741b7aa14aa35afb13840e574a6b50e4a2dc66022626d92b` |

**Reproducibility gaps:** The source version is pinned, but the first config
download uses Apple's mutable `main` branch. The retained config and hash
identify this run's input, but a fresh download may differ. `alpine:3.22` and
its package repositories also move; the compiler and image are not pinned by
digest. We compared a checksum fetched over HTTPS; we did not verify a kernel
maintainer's signature. The build is reproducible as a procedure, not proven
bit-for-bit reproducible.

## 7. Recreating the peers and configuring the tunnel

We removed the intermediate Kata-kernel peers and changed `lab.sh` to pass
the native kernel to each new container. No `wireguard-go` package was
installed in the final peers.

Each peer generated a private key inside `/etc/wireguard` under `umask 077`.
Only public keys were retrieved for peer configuration. For each peer, the
script created wg0 with `ip link add ... type wireguard`, assigned its /32
tunnel address, configured the other peer's public key and eth0 endpoint,
set MTU 1420, brought the interface up, and added a /32 route to its peer.

Allowed IPs are deliberately narrow:

```text
A allows B: 10.77.0.2/32
B allows A: 10.77.0.1/32
```

Each peer listens on UDP 51820 and sends keepalives every five seconds. This
interval was a lab choice, not a value established by tuning. The script saves
`wg showconf wg0` to a restricted file in each peer. That output saves
WireGuard settings; addresses and routes are restored by `lab.sh configure`,
not by treating that file as a complete `wg-quick` configuration.

## 8. Evidence that the final result met the requirement

The successful run of `lab.sh test` exited with status 0 and checked:

- Three pings from A to `10.77.0.2`: three received, zero loss, average 0.924 ms.
- Three pings from B to `10.77.0.1`: three received, zero loss, average 0.918 ms.
- Both live guest configurations reported `CONFIG_WIREGUARD=y`.
- `ip -d link show wg0` reported interface type `wireguard` on both peers.
- `wg show` displayed completed handshakes and nonzero send/receive counters.
- Both peers' handshake timestamp checks passed.

The guests reported `6.18.5-wg-testbed`. The output image's SHA-256 was also
verified on the host. The first host checksum command ran from the workspace
root and could not resolve the checksum file's relative artifact path;
rerunning from `kernel/` returned `vmlinux-native-wireguard: OK`.

These results establish native kernel WireGuard connectivity in this lab.
The latency figures are six small pings, not a performance benchmark.

## 9. What was not tested or finished

The following remain review items, rather than claims of verified behavior:

- macOS reboot and container stop/start recovery. The README describes the
  intended manual sequence, but we did not exercise it end to end.
- A complete teardown/recreate cycle after the final successful configuration.
- Sustained traffic, throughput, packet loss under load, TCP application traffic,
  large packets, path MTU behavior, or IPv6.
- Handshake recovery after a peer or endpoint changes. The test only requires
  a nonzero handshake timestamp; it does not enforce freshness or all-peer
  health in a larger topology.
- Automatic startup, key backup, or key rotation. Deleting a peer deletes its
  locally generated keys; `up` creates new ones.
- A custom network, firewall policy, or proof of packet contents via capture.
- Production kernel update policy or testing on other CLI/macOS versions.

The detached builder exited after its build and was left available as a
stopped container. Build outputs remain under `kernel/`, which was initially
ignored in full. During preparation for GitHub publication, the ignore rules
were narrowed to include the kernel image, configs, checksums, and build log.
The downloaded Linux source archive remains excluded because it exceeds
GitHub's 100 MiB per-file limit; the build script downloads it again.
The installed runtime service was started during this work, and the final two
peers were left running.

## 10. A better sequence for the next attempt

1. Establish native-versus-userspace as an acceptance criterion up front.
2. Inventory the installed CLI, start its service, and read its actual help.
3. Start a small probe container; inspect live kernel config and capabilities.
4. Verify ordinary network reachability independently of the tunnel.
5. Inspect candidate kernel configuration before downloading large artifacts.
6. If building, pin source, config commit, builder image, and toolchain inputs;
   preserve checksums and build metadata.
7. Probe the built kernel with `ip link add ... type wireguard` before creating
   the complete lab.
8. Configure peers, then run validation only after setup succeeds.
9. Validate lifecycle recovery and preserve a timestamped test transcript.

The central lesson is to distinguish three independent requirements: the CLI
must boot the guest, the guest kernel must implement WireGuard, and the peers
must have working keys, routes, and network reachability. Installing userspace
tools or successfully booting an arbitrary kernel proves only part of that.

## Files and references

- [README.md](README.md): operating and rebuilding the lab.
- [lab.sh](lab.sh): peer creation, tunnel configuration, checks, and teardown.
- [build-kernel.sh](build-kernel.sh): native kernel build procedure.
- `kernel/native.config`: configuration used for the successful build.
- `kernel/build.log`: compilation output.
- `kernel/*.sha256`: recorded input/output checksums.
- [Apple kernel build instructions](https://github.com/apple/containerization/tree/main/kernel)
- [Apple CLI 0.1.0 how-to](https://github.com/apple/container/blob/0.1.0/docs/how-to.md)
- [Apple current runtime configuration](https://github.com/apple/container/blob/main/docs/runtime-configuration.md)
- [Apple current default kernel configuration](https://github.com/apple/container/blob/main/docs/container-system-config.md)
- [Linux source distributions](https://cdn.kernel.org/pub/linux/kernel/v6.x/)

The upstream `main` links explain what was consulted; they may evolve and are
not immutable evidence of the local installation's behavior.
