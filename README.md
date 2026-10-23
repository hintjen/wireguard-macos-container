# Native WireGuard testbed on Apple container

Two Alpine Linux containers boot a custom ARM64 Linux kernel with
`CONFIG_WIREGUARD=y`. WireGuard runs in the Linux kernel; no `wireguard-go`
process is needed. The installed Apple CLI and API server are version 1.6.0
(commit `ca4884f`), upgraded from 0.1.0 on October 23, 2026. The lab uses
`--cap-add NET_ADMIN` to configure WireGuard interfaces under the newer
runtime's restricted capability defaults.

| Container | Tunnel address | UDP port |
| --- | --- | --- |
| wg-test-a | 10.77.0.1/32 | 51820 |
| wg-test-b | 10.77.0.2/32 | 51820 |

The script discovers the containers' eth0 addresses and uses them as peer
endpoints. Only the peer's tunnel address routes through wg0. Private keys
are generated inside each container with restrictive file permissions.

Validated on this Mac: both peers report `6.18.5-wg-testbed` and
`CONFIG_WIREGUARD=y`; wg0 reports interface type `wireguard`. Both peers
completed a handshake and received all three tunnel pings with zero loss,
averaging approximately 0.9 ms round trip on the original 0.1.0 runtime.
After upgrading to 1.6.0, fresh peers and a subsequent stop/start/reconfigure
cycle both passed all pings and handshake checks with zero packet loss.
Keys persisted across stop/start, while eth0 addresses changed and were
rediscovered. See [the upgrade record](JOURNEY.md#11-runtime-upgrade-to-160)
and [saved validation output](validation/).

From this directory:

```sh
./lab.sh test        # ping both directions, inspect native interfaces and handshakes
./lab.sh configure   # restore tunnel interfaces/routes after restarting both containers
./lab.sh down        # stop and remove the two lab containers
./lab.sh up          # recreate peers using the existing native kernel; creates new keys
```

After restarting macOS, run `container system start`, start both peers with
`container start wg-test-a` and `container start wg-test-b`, then run
`./lab.sh configure`. Interface state is recreated; keys persist in each
container's filesystem. Deleting containers deletes their keys.

## Kernel build

The builder uses Linux 6.18.5 and Apple's ARM64 container kernel configuration,
explicitly enabling built-in WireGuard and TUN. The source archive is checked
against kernel.org's SHA-256 listing. Input configuration, source checksum,
final configuration, build log and output checksum are retained under `kernel/`.
The kernel image and build records are included in Git. The downloaded Linux
source archive is excluded because of its size and is fetched by the builder.

```sh
mkdir -p kernel
container run -d --name wg-kernel-build --cpus 8 --memory 8g \
  -v "$PWD:/lab" -v "$PWD/kernel:/kernel" \
  alpine:3.22 sh /lab/build-kernel.sh
container logs wg-kernel-build
```

Wait for `Native WireGuard kernel built successfully.` before creating peers.
The build output is `kernel/vmlinux-native-wireguard`; `lab.sh up` passes it
with `--kernel`, so it does not change the runtime's default kernel.
To rebuild, delete the stopped builder container first. Keep `config-arm64`
to reuse the same configuration on subsequent builds.

References:
- [Apple's kernel build instructions](https://github.com/apple/containerization/tree/main/kernel)
- [Linux source releases](https://www.kernel.org/)
