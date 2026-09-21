# Runbook — after this machine reboots

Operational checklist to get Appium E2E talking to the kind cluster again. This is not a first-time setup guide.

Pitfalls (OOM, `kubectl cp` on Windows, `docker save` pipe): [troubleshooting.md](troubleshooting.md). First-time Phase 0/1: [README](../README.md).

## What is already on disk (do not redo)

| Thing | Path |
|---|---|
| APK | `C:\workspaces\JavaProjects\native-appium-demo\apks\app-debug.apk` |
| Keystore | `C:\workspaces\JavaProjects\native-appium-demo\config\my-debug-keystore.jks` |
| Manifests | `C:\workspaces\K8sProjects\k8s-mobile-e2e-lab\e2e\` |
| Docker image | `native-appium-demo-android:latest` (unless someone deleted it) |

Rebuild the APK, keystore, or Compose image only if one of those is missing. Keystore: [how to create `my-debug-keystore.jks`](troubleshooting.md#how-to-create-my-debug-keystorejks-debug-only). APK: [copy-apk.bat cannot find the APK](troubleshooting.md#copy-apkbat-cannot-find-the-apk).

After reboot the Deployment may recreate the Pod, but `emptyDir` is empty, `port-forward` is gone, and the AVD must boot again.

## Before you start

1. Close **IntelliJ IDEA** and **Android Studio**.
2. Close extra Chrome windows if you can.
3. **Do not** start Compose. Two emulators on this laptop compete for RAM.

```powershell
cd C:\workspaces\JavaProjects\native-appium-demo
docker compose --profile web down
```

RAM-heavy processes: [troubleshooting.md](troubleshooting.md#close-other-ram-heavy-programs-before-docker-save-and-the-emulator).

## 1. Docker Desktop + Kubernetes Ready

Start **Docker Desktop**. Settings → Kubernetes: **Enable Kubernetes**, provisioner **kind**, **1 node**. Do not pick kubeadm or extra nodes.

Settings → Resources → Advanced may show **no Memory slider** (WSL 2). Caps then live in `%USERPROFILE%\.wslconfig`, not in Docker Desktop. Dedicated-lab example and `wsl --shutdown`: [troubleshooting — WSL 2](troubleshooting.md#docker-desktop-has-no-memory-slider-wsl-2).

Wait until Docker is green and the node is Ready (can take a few minutes):

```powershell
kubectl get nodes
```

Expect `desktop-control-plane` `Ready`.

Do **not** use the `kind` CLI. Docker Desktop already runs the cluster; it does not install `kind`. [kind is not recognized](troubleshooting.md#kind-is-not-recognized).

## 2. Confirm the image is still on the kind *node*

Docker Desktop images are **not** visible to the cluster until they sit in the node’s containerd. After a normal reboot they usually persist; a Kubernetes reset wipes them.

```powershell
docker exec desktop-control-plane ctr -n k8s.io images ls | findstr native-appium
```

If you see `native-appium-demo-android:latest`, skip to step 3.

If empty, check Docker Desktop:

```powershell
docker images native-appium-demo-android:latest
```

If that is empty too, build first:

```powershell
cd C:\workspaces\JavaProjects\native-appium-demo
docker compose build
```

Import via a **file** (never pipe `docker save` through PowerShell):

```powershell
docker save native-appium-demo-android:latest -o $env:TEMP\native-appium.tar
docker cp $env:TEMP\native-appium.tar desktop-control-plane:/native-appium.tar
docker exec desktop-control-plane ctr -n k8s.io images import /native-appium.tar
docker exec desktop-control-plane ctr -n k8s.io images ls | findstr native-appium
docker exec desktop-control-plane rm -f /native-appium.tar
```

Save/import takes several minutes. Destination on the node must be `/native-appium.tar`, **not** `/tmp`. Why: [pipe OOM](troubleshooting.md#pipe-docker-save--docker-exec--ctr-import--out-of-memory) and [`/tmp` tmpfs](troubleshooting.md#ctr-open-tmpnative-appiumtar-no-such-file-or-directory).

## 3. Apply manifests and wait for `Running`

Use **three** PowerShell windows. Keep A and B open the whole session. [Which windows to leave open](troubleshooting.md#which-powershell-windows-to-leave-open).

**Window A — Pod watch (do not close):**

```powershell
cd C:\workspaces\K8sProjects\k8s-mobile-e2e-lab
kubectl apply -f e2e/
kubectl -n e2e get pods -w
```

Wait until `appium-emulator-*` is `1/1 Running`. If the Deployment already existed, apply only confirms it; after reboot the Pod is still a new process.

If you see `ImagePullBackOff`, the image is not on the node — go back to step 2. If namespace errors: [alphabetical apply](troubleshooting.md#kubectl-apply--f-e2e-namespace-created-deploymentservice-namespaces-e2e-not-found).

## 4. Copy APK and keystore again (required)

`emptyDir` starts empty on **every** Pod restart (reboot, OOM, rolling update).

**Window C:**

```powershell
cd C:\workspaces\K8sProjects\k8s-mobile-e2e-lab
.\scripts\copy-apk-and-keystore-to-pod.bat
```

Expect `app-debug.apk` (~24M) and `my-debug-keystore.jks`. Edit `DEMO` at the top of the `.bat` if `native-appium-demo` is not under `C:\workspaces\JavaProjects\`. Manual `kubectl cp` (Windows cannot use `C:\...`): [troubleshooting](troubleshooting.md#kubectl-cp-one-of-src-or-dest-must-be-a-local-file-specification).

## 5. Port-forward (required, leave it running)

Pick **one** layout below. Do not run the default command and the LAN `6080` forward at the same time — both bind port **6080** and the second process will fail.

### Default — Appium + noVNC on this machine only

**Window B — do not close:**

```powershell
kubectl -n e2e port-forward svc/appium 4723:4723 6080:6080
```

Wait for `Forwarding from 127.0.0.1:4723`. Ctrl+C in this window drops Appium and noVNC. noVNC: http://localhost:6080.

### Optional — noVNC on another computer on the LAN

Use when the host that runs `kubectl` has no browser (or you closed Chrome to save RAM). The default command above listens only on `127.0.0.1`, so **Ctrl+C** it first, then open **two** windows and leave both running:

**Window B1 — Appium for `mvn test` on the kubectl host:**

```powershell
kubectl -n e2e port-forward svc/appium 4723:4723
```

Wait for `Forwarding from 127.0.0.1:4723`.

**Window B2 — noVNC reachable on the LAN:**

```powershell
kubectl -n e2e port-forward --address 0.0.0.0 svc/appium 6080:6080
```

Wait for `Forwarding from 0.0.0.0:6080 -> 6080`. On the other computer, open `http://<lan-ip-of-kubectl-host>:6080/` (for example `http://192.168.15.162:6080/`). Allow inbound **TCP 6080** on Windows Firewall on the kubectl host. Ctrl+C in **B2** drops the remote screen only; **B1** keeps Appium on `http://localhost:4723`.

If you only need the remote screen and will not run `mvn test` yet, **B2 alone** is enough. Add **B1** before step 7.

More detail: [troubleshooting — noVNC from another computer](troubleshooting.md#novnc-from-another-computer-on-the-lan).

If the Pod restarts, every forward dies: Ctrl+C each port-forward window, start step 5 again (same layout you chose), and **repeat step 4**.

## 6. Wait for Android home in noVNC

Open http://localhost:6080, or `http://<lan-ip>:6080/` if you used the optional **B2** layout in step 5.

`1/1 Running` only means the container process is up. The AVD still has to boot (no KVM, `swiftshader`).

| Time on noVNC | What to do |
|---|---|
| 0–5 min | Black screen / boot — normal. Keep **B** forwarding. |
| 5–15 min | Still reasonable on Windows kind. |
| 15–25 min | Check window **A** for `OOMKilled`. `kubectl -n e2e logs deploy/appium-emulator --tail=80` in **C**. |
| Over ~30 min with no launcher | Stop waiting. On this laptop the AVD may never become usable. |

Do not start Compose or the IDEs while waiting. Full table: [how long to wait](troubleshooting.md#how-long-to-wait-for-android-home-in-novnc).

## 7. Run tests on the host

**Window C** (forward still running in **B** or **B1**):

```powershell
cd C:\workspaces\K8sProjects\k8s-mobile-e2e-lab
.\scripts\run-mvn-test.bat
```

Same steps by hand (must run from `native-appium-demo`, not this repo):

```powershell
cd C:\workspaces\JavaProjects\native-appium-demo
$env:APPIUM_SERVER_URL="http://localhost:4723"
Remove-Item Env:SELENIUM_REMOTE_URL -ErrorAction SilentlyContinue
mvn test
```

Leave `SELENIUM_REMOTE_URL` unset. Selenium Grid (`:4444`) is not in this cluster. Chrome tests use the **host** browser.

## If the Pod dies (`OOMKilled`)

Window **A** shows `0/1 OOMKilled`, then `RESTARTS 1`. Then:

1. Wait until a **single** Pod is `1/1 Running` (no `Terminating` twin).
2. Repeat step 4 (copy files).
3. Restart the port-forward (step 5).
4. Wait for Android home again (step 6).
5. Only then `mvn test`.

This lab still hit OOM at **~30–45 min** on the **6Gi** limit during `mvn test`. Do not keep raising YAML limits on Windows kind. Honest result: the cluster **schedules** Appium; the AVD + Espresso rebuild does not stay within a laptop kind node. Next step is a Linux VM with KVM (or Compose on the host, which already passed Phase 0). Details: [Pod OOMKilled](troubleshooting.md#pod-oomkilled-after-many-minutes-running).

To halt the restart loop and free RAM:

```powershell
kubectl -n e2e scale deploy/appium-emulator --replicas=0
```

## Terminal map

| Window | Command | Keep open? |
|---|---|---|
| **A** | `kubectl -n e2e get pods -w` | Yes, until you are done |
| **B** (default) | `port-forward svc/appium 4723:4723 6080:6080` | Yes; otherwise `:4723` and `:6080` die |
| **B1 + B2** (LAN noVNC) | `4723:4723` in one window; `--address 0.0.0.0` + `6080:6080` in another | Yes; both. Do not also run the default **B** command (6080 conflict). |
| **C** | `.bat`, `kubectl logs`, `mvn test` | Reuse |

Browser noVNC is not a terminal: it works only while **B** (or **B2**) is forwarding.
