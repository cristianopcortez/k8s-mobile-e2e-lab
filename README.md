# k8s-mobile-e2e-lab

Kubernetes lab for Android E2E: Appium + emulator as Deployment/Service, from Docker Compose to Docker Desktop Kubernetes (kind) and later a Linux VM.

The TestNG suite lives in [`native-appium-demo`](https://github.com/cristianopcortez/native-appium-demo) (adjust the URL if yours differs). This repo only describes the cluster side.

`app-debug.apk` is **not** built here. It comes from the Taxi Android app: [`cristianopcortez/Taxi`](https://github.com/cristianopcortez/Taxi) (`assembleDebug` / Android Studio **Build APK**). Copy that artifact into `native-appium-demo/apks/` (and later `kubectl cp` into the Pod). Sign it with the same debug keystore you keep in `native-appium-demo/config/` (never commit `*.jks` or `*.apk`). If you do not have `my-debug-keystore.jks` yet, see [docs/troubleshooting.md](docs/troubleshooting.md#how-to-create-my-debug-keystorejks-debug-only).

Windows + kind pitfalls from the first lab session: [docs/troubleshooting.md](docs/troubleshooting.md).

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

`emptyDir` volumes start empty (kind cannot bind-mount your Windows folders).

On Windows do **not** pass `C:\...` to `kubectl cp` (it is parsed as a pod name). `cd` and use a relative path:

```powershell
$pod = kubectl -n e2e get pod -l app=appium-emulator -o jsonpath="{.items[0].metadata.name}"

cd C:\workspaces\JavaProjects\native-appium-demo\apks
kubectl -n e2e cp .\app-debug.apk "${pod}:/home/androidusr/apks/app-debug.apk"

cd C:\workspaces\JavaProjects\native-appium-demo\config
kubectl -n e2e cp .\my-debug-keystore.jks "${pod}:/home/androidusr/config/my-debug-keystore.jks"
```

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
e2e/
  namespace.yaml
  appium-deployment.yaml
  appium-service.yaml
```

Course fundamentals YAMLs belong under `fundamentals/` later — not in the repo root.
