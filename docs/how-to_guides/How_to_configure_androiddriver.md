# Run the Android driver with KVM in local KIND

The x86_64 Android emulator normally uses hardware acceleration. If it exits with
`/dev/kvm is not found`, check each layer from WSL to the pod:

```shell
# In the WSL distribution used for local development:
ls -ln /dev/kvm
docker info --format '{{.Name}} {{.OperatingSystem}}'
docker exec zeta-local-control-plane ls -ln /dev/kvm
docker exec zeta-local-control-plane stat -c '%g' /dev/kvm
kubectl -n zeta-local exec deployment/androiddriver -- ls -ln /dev/kvm
```

The Docker daemon may run in Docker Desktop's own WSL distribution, even
when the Docker CLI runs in Ubuntu WSL. Device access must work through the
daemon's Linux environment, the KIND node, and the emulator pod. KIND nodes
and ordinary pods are containers; they do not each add another hardware VM.
KIND nodes use privileged containers; if the device is already there, no
cluster recreation or extra KIND mount is needed.

If the node has `/dev/kvm` but the pod does not, enable passthrough in your
local values file. Replace `994` with the numeric group ID reported by
`stat` above:

```yaml
androidDriverEnabled: true
androiddriver:
  kvm:
    enabled: true
    hostPath: /dev/kvm
  podSecurityContext:
    supplementalGroups: [994]
  containerSecurityContext:
    privileged: true
    allowPrivilegeEscalation: true
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 1000
    capabilities:
      drop: ["ALL"]
```

The chart mounts a `CharDevice` hostPath at `/dev/kvm`. The supplemental
group permits the non-root user to open the device. Privileged mode permits
the device access through the container runtime; a hostPath mount alone
does not grant that access. Kubernetes requires privilege escalation to be
allowed with privileged mode. Privileged mode also overrides capability
and seccomp restrictions, so this is an explicit exception for local
emulator testing. It cannot run under the baseline or restricted Pod
Security Standards. KVM passthrough is disabled by default; clusters that
need tighter isolation should provision a KVM device plugin separately.

The chart starts the container in `/tmp`, which is backed by a writable
`emptyDir`. This avoids the image's inaccessible `/home/androidusr` when
the pod runs as UID 1000. The AVD template under `/opt/android/avd` remains
read-only and the image's entrypoint copies it to `/tmp/avd`.

The current local image, `c44f6cc1`, forwards the Android app through socat
on port `8080` and serves health at `/androiddriver-api/health`. Use these
settings alongside the KVM configuration above:

```yaml
androiddriver:
  image:
    tag: c44f6cc1
  containerPort: 8080
  readinessPath: /androiddriver-api/health
  authMode: "OIDC"
  command:
    - /bin/bash
    - -ec
    - |
      ulimit -n 1048576
      exec /opt/testdriver/entrypoint.sh
```

The Service targets the named `http` container port, so it follows
`containerPort`. Image `c44f6cc1` returns `200 OK` at
`/androiddriver-api/health` and `404` at `/health`. The command reduces the
inherited open-file limit before starting the image's entrypoint; the
QEMU troubleshooting section below explains why this is needed.
Set `authMode` explicitly for the intended flow and provide the existing
`oidcBaseUri`, `oidcIdpIss`, `oidcIdpAlias`, and `oidcTestKvnr` values.

After any existing Helm operation has finished, deploy the updated chart:

```shell
make deploy stage=local
kubectl -n zeta-local exec deployment/androiddriver -- emulator -accel-check
kubectl -n zeta-local logs deployment/androiddriver --tail=100
```

`emulator -accel-check` should report that KVM is installed and usable. The
startup log should then reach `emulator booted` and `app running`. The
emulator's increasing RAM requirement and read-only AVD template messages
are separate from the missing KVM device error.

If `/dev/kvm` is missing from WSL itself, verify nested virtualization and
KVM support first. If WSL has it but the Docker daemon's environment does
not, fix that layer before enabling the chart value. Increasing Helm's
timeout cannot fix a missing hardware acceleration device.

## QEMU hangs after KVM becomes available

A successful `emulator -accel-check` confirms hypervisor availability; it
does not prove that an Android guest can boot. On the tested Windows/WSL2
KIND setup, a second startup failure occurred after KVM became usable:
`detected a hanging thread 'QEMU2 CPU0 thread'` and `QEMU2 main loop`.

The cause was an excessively high inherited open-file limit (`RLIMIT_NOFILE`):

| Environment | Soft / hard open-file limit | Observed result |
| --- | --- | --- |
| Standalone Docker on the same WSL2 host | 1,048,576 / 1,048,576 | Android booted in 52 seconds. |
| KIND pod with inherited limits | 2,147,483,584 / 2,147,483,584 | QEMU's CPU0/main-loop watchdog aborted startup. |
| Same KIND test with only the open-file limit reduced | 1,048,576 / 1,048,576 | Android booted in 44 seconds; `sys.boot_completed` was `1`. |

A process trace showed QEMU repeatedly calling `fcntl(F_GETFD)` and
`fcntl(F_SETFD)` on consecutive invalid descriptor numbers above 49 million.
This scan kept a thread busy until the watchdog fired. Lowering the process
limit resolved the hang in the original image, without changing the WSL
kernel, emulator version, system image, DNS, storage, or security settings.
The controlled test used emulator 37.1.11 and API 34 Google APIs x86_64
revision 14. DNS changes, copying the SDK out of the image filesystem, and
using RAM-backed AVD storage did not fix the inherited-limit failure.

The earlier image `752c4467` needed an additional ADB argument quoting
workaround. The following example is only for that older image; the current
`c44f6cc1` image uses the simpler command shown above:

```yaml
androiddriver:
  image:
    tag: 752c4467
  readinessPath: /health
  command:
    - /bin/bash
    - -ec
    - |
      ulimit -n 1048576
      mkdir -p /tmp/android-bin
      cat > /tmp/android-bin/adb <<'ADB_WRAPPER'
      #!/bin/bash
      set -euo pipefail
      if [[ $# -ge 3 && $1 == shell && $2 == am && $3 == start ]]; then
        shift
        printf -v remote_command '%q ' "$@"
        exec /opt/android/platform-tools/adb shell "$remote_command"
      fi
      exec /opt/android/platform-tools/adb "$@"
      ADB_WRAPPER
      chmod +x /tmp/android-bin/adb
      export PATH="/tmp/android-bin:$PATH"
      exec /opt/testdriver/entrypoint.sh
```

The chart's optional `command` override defaults to an empty list, which
uses the image's own entrypoint. Both command examples change only the
driver process and its descendants. They do not change the node's
container runtime or other workloads.

After deployment, inspect the running entrypoint's limits and the guest:

```shell
kubectl -n zeta-local exec deployment/androiddriver -- \
  sh -c "grep 'Max open files' /proc/1/limits"
kubectl -n zeta-local exec deployment/androiddriver -- \
  adb shell getprop sys.boot_completed
```

A new `kubectl exec` shell can retain the runtime's original limits, so
checking that shell's `ulimit` alone does not verify the wrapper. Inspect
PID 1 or the emulator process via `/proc/<pid>/limits` instead.

The later `cpufreq/scaling_cur_freq` errors came from crash reporting;
mounting CPU frequency files or increasing Helm's timeout does not address
this descriptor scan. These results demonstrate that the Android guest
can run inside KIND on this WSL2 host.

## App reports missing OIDC configuration after Android boots

Image `752c4467` starts the Android activity with `adb shell am start` and
string extras. Its entrypoint quotes the local shell arguments, but ADB
joins those arguments into another shell command on the device. Empty
values such as `REQUIRED_OID` or `OIDC_BINDING_EMAIL` can disappear at that
second shell boundary and shift the remaining arguments.

The observed launch included `pkg=OIDC_BASE_URI`, followed by
`OIDC_BASE_URI is required for OIDC mode`, even though the environment
variable was populated. The local ADB wrapper above preserves empty values
and shell-sensitive characters when launching the activity. All other ADB
commands use the real binary directly.

The chart also supplies `REQUIRED_OID` and `DISABLE_TLS_VERIFICATION`, the
environment names this image consumes, alongside the existing
`REQUIRED_ROLE_OID` and `DISABLE_SERVER_VALIDATION` names for older images.
Setting `authMode: "OIDC"` fixes the local Helm configuration and enables
its OIDC value validation. This particular image's entrypoint does not
forward `AUTH_MODE` to the activity, so changing that value alone does not
repair its malformed activity arguments.

After deploying the current `c44f6cc1` configuration, verify driver startup:

```shell
kubectl -n zeta-local rollout status deployment/androiddriver
kubectl -n zeta-local port-forward service/androiddriver 8080:80
# In another terminal:
curl --fail http://localhost:8080/androiddriver-api/health
```

HTTP readiness confirms that the driver server started. A complete OIDC
login and protected Fachdienst request require their own functional test.

The older `752c4467` configuration was verified in a temporary KIND pod
rendered from the chart and local values: Android reported
`sys.boot_completed=1`, Kubernetes readiness remained successful for over
30 seconds, and `/health` returned `200 OK` both directly and through a
temporary Service rendered from this chart. The emulator's effective soft
and hard open-file limits were both `1048576`. The test pod and Service
were removed afterward; this check did not upgrade the full Helm release.

## App rejects a quoted URL with newer images

Images `6898ddc4` and `c44f6cc1` quote activity extras in their own entrypoints
and skip empty extras. Remove the older ADB wrapper when using these images.
Applying both quoting steps sends literal quote characters to the app, which then fails
with `URLParserException` and `Illegal character in scheme at position 0`
for a URL such as `'https://zeta-kind.local/pep/'`.

Keep the open-file limit override needed by the emulator:

```yaml
androiddriver:
  command:
    - /bin/bash
    - -ec
    - |
      ulimit -n 1048576
      exec /opt/testdriver/entrypoint.sh
```

References:

- [Android emulator acceleration](https://developer.android.com/studio/run/emulator-acceleration#vm-linux)
- [WSL nested virtualization settings](https://learn.microsoft.com/en-us/windows/wsl/wsl-config#main-wsl-settings)
- [Kubernetes hostPath volumes](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath)
