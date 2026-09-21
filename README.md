# k8s-mobile-e2e-lab

Kubernetes lab for Android E2E: Appium + emulator as Deployment/Service, from Docker Compose to Docker Desktop Kubernetes (kind) and later a Linux VM.

## What this is for (GitHub / LinkedIn)

The TestNG process already drives **Selenium** (Chrome) and **Appium** (Android) over HTTP. This repo shows the **cluster shape** of that environment: same ports (`4723`, `6080`), same image, `kubectl apply`, `kubectl cp`, `port-forward`.

| Layer | What actually ran | What to say in a post |
|---|---|---|
| Selenium + Appium suite | Green on the **host** via Docker Compose in [`native-appium-demo`](https://github.com/cristianopcortez/native-appium-demo) (Chrome on the machine or Compose profile `web` on `:4444`) | One JVM, two drivers, no machine-specific paths |
| Kubernetes (this repo) | kind on Docker Desktop: image imported into the node, Pod `Running`, Service, noVNC tunnel | Manifests without fake KVM affinity; Windows limits documented |
| AVD inside kind | **OOMKilled** (~30–45 min, 4Gi then 6Gi) during / around `mvn test` | Orchestration worked; nested virt + RAM did not — next chapter is Linux + `/dev/kvm` |

Do **not** claim “full E2E green on Kubernetes” until a Linux node with KVM finishes the suite. Claiming Compose + honest kind results is stronger than a screenshot of a Pod that later dies.

Selenium Grid is **not** in `e2e/` yet (Compose `selenium-chrome` only). A follow-up YAML can pin `selenium/standalone-chrome` the same way as Appium.

The TestNG suite lives in [`native-appium-demo`](https://github.com/cristianopcortez/native-appium-demo) (adjust the URL if yours differs). This repo only describes the cluster side.

`app-debug.apk` is **not** built here. It comes from the Taxi Android app: [`cristianopcortez/Taxi`](https://github.com/cristianopcortez/Taxi) (`assembleDebug` / Android Studio **Build APK**). Copy that artifact into `native-appium-demo/apks/` (and later `kubectl cp` into the Pod). Sign it with the same debug keystore you keep in `native-appium-demo/config/` (never commit `*.jks` or `*.apk`). If you do not have `my-debug-keystore.jks` yet, see [docs/troubleshooting.md](docs/troubleshooting.md#how-to-create-my-debug-keystorejks-debug-only).

After this machine reboots, start here: [docs/runbook.md](docs/runbook.md). Windows + kind pitfalls from the first lab session: [docs/troubleshooting.md](docs/troubleshooting.md).

## Phase 0 (done on the host)

`docker compose up` in `native-appium-demo` + `mvn test`. Prove Appium on `:4723` and noVNC on `:6080` before using Kubernetes.

Stop Compose before starting the Pod so the emulator is not running twice:

```powershell
cd C:\workspaces\JavaProjects\native-appium-demo
docker compose --profile web down
```

## Phase 1 — Docker Desktop Kubernetes (kind, 1 node)

Cluster in this lab: **kind**, **1 node**, Kubernetes **v1.36.1**. Do not enable kubeadm or extra nodes on a laptop that already runs an Android emulator.

### 1. Load the local image into the kind *node*

Docker Desktop “Kubernetes = kind” does **not** install the `kind` CLI. `kind get clusters` will fail with “term not recognized”. `kubectl` is enough.

Images on Docker Desktop are **not** visible to the cluster until you import them into the node’s containerd. The node container has the same name as `kubectl get nodes` (`desktop-control-plane`):

Do **not** pipe `docker save` through PowerShell (OOM). Save to a file, `docker cp` to `/native-appium.tar` on the node (**not** `/tmp`), then `ctr import`. Details: [docs/troubleshooting.md](docs/troubleshooting.md).

```powershell
docker images native-appium-demo-android:latest
docker save native-appium-demo-android:latest -o $env:TEMP\native-appium.tar
docker cp $env:TEMP\native-appium.tar desktop-control-plane:/native-appium.tar
docker exec desktop-control-plane ctr -n k8s.io images import /native-appium.tar
```

If `docker images` is empty, build first:

```powershell
cd C:\workspaces\JavaProjects\native-appium-demo
docker compose build
```

Confirm the import:

```powershell
docker exec desktop-control-plane ctr -n k8s.io images ls | findstr native-appium
```

Optional: install the [kind CLI](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) later if you want `kind load docker-image ... --name desktop`. You do not need it for this lab.

### 2. Apply manifests

```powershell
cd C:\workspaces\K8sProjects\k8s-mobile-e2e-lab
# 00-namespace.yaml is applied first (directory order is alphabetical).
kubectl apply -f e2e/
kubectl -n e2e get pods -w
```

Wait until `appium-emulator-*` is `Running`. First emulator boot can take several minutes (software GPU, no `/dev/kvm` on Windows kind).

### 3. Copy APK and keystore into the Pod

`emptyDir` volumes start empty (kind cannot bind-mount your Windows folders). After every Pod restart / `OOMKilled` / rolling update, copy again.

```powershell
cd C:\workspaces\K8sProjects\k8s-mobile-e2e-lab
.\scripts\copy-apk-and-keystore-to-pod.bat
```

Edit `DEMO` at the top of the `.bat` if `native-appium-demo` is not under `C:\workspaces\JavaProjects\`. The script `cd`s before `kubectl cp` so Windows does not treat `C:` as a pod name. Manual commands: [docs/troubleshooting.md](docs/troubleshooting.md#kubectl-cp-one-of-src-or-dest-must-be-a-local-file-specification).

### 4. Port-forward and run tests on the host

```powershell
kubectl -n e2e port-forward svc/appium 4723:4723 6080:6080
```

Watch the emulator at http://localhost:6080. When the Android home is visible:

If the Pod is `OOMKilled` or replaced, copy APK/keystore again and restart port-forward. Which terminals to watch and how long to wait: [docs/troubleshooting.md](docs/troubleshooting.md#which-powershell-windows-to-leave-open).

```powershell
cd C:\workspaces\JavaProjects\native-appium-demo
$env:APPIUM_SERVER_URL="http://localhost:4723"
mvn test
```

For Chrome on the host, **do not** set `SELENIUM_REMOTE_URL`. That flag expects Selenium on `:4444` (Compose profile `web`), which is not in this cluster yet.

### Honest limits (interview talking point)

- Windows + kind: no reliable KVM; emulator uses `swiftshader_indirect` (slow, may be unusable).
- The same YAML without KVM affinity still **schedules**, exposes Appium via a Service, and is the shape you later take to a Linux VM with `/dev/kvm`.
- A Maven `Job` inside the cluster is the next increment after port-forward + host `mvn test` works.

## Layout

```
docs/
  runbook.md
  troubleshooting.md
e2e/
  00-namespace.yaml
  appium-deployment.yaml
  appium-service.yaml
scripts/
  copy-apk-and-keystore-to-pod.bat
```

Course fundamentals YAMLs belong under `fundamentals/` later — not in the repo root.
