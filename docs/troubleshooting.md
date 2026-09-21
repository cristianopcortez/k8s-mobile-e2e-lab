# Troubleshooting (Windows + Docker Desktop kind)

Pitfalls from the first lab session: Compose E2E on the host, then Appium inside Docker Desktop Kubernetes (kind, 1 node, `desktop-control-plane`).

After a reboot, use the ordered checklist in [runbook.md](runbook.md). This file is the “why it broke” companion, not the daily start path.

Paths used in this machine (adjust if yours differ):

| Role | Path |
|---|---|
| Taxi Android app (source of `app-debug.apk`) | Clone of https://github.com/cristianopcortez/Taxi — e.g. `C:\workspaces\AndroidStudioProjects\Taxi` |
| TestNG + Compose | `C:\workspaces\JavaProjects\native-appium-demo` |
| This repo | `C:\workspaces\K8sProjects\k8s-mobile-e2e-lab` |

Do **not** commit `*.jks` or `*.apk`.

---

## Phase 0 — Compose / TestNG (before Kubernetes)

### How to create `my-debug-keystore.jks` (debug only)

Appium Espresso **re-signs** a test APK. That keystore must be the **same file** used to sign Taxi’s `app-debug.apk`. This is **not** a Play Store upload key. Never commit the `.jks`.

Skip this section if `native-appium-demo\config\my-debug-keystore.jks` already exists and you remember alias + passwords.

`keytool` ships with the JDK (17+). From PowerShell:

```powershell
keytool -genkeypair -v `
  -keystore C:\workspaces\JavaProjects\native-appium-demo\config\my-debug-keystore.jks `
  -storetype JKS `
  -alias my-debug-alias `
  -keyalg RSA -keysize 2048 -validity 10000 `
  -storepass mypassword -keypass mypassword `
  -dname "CN=Android Debug,O=Local,C=BR"
```

Those alias/password values match the defaults in `native-appium-demo` (`AndroidDriverManager`). If you pick others, set `KEYSTORE_PASSWORD`, `KEY_ALIAS`, and `KEY_PASSWORD` before `mvn test`, and use the same values in Android Studio **Generate Signed APK** / `SHARED_DEBUG_KEYSTORE_PATH` when building Taxi.

Check what you created:

```powershell
keytool -list -v -keystore C:\workspaces\JavaProjects\native-appium-demo\config\my-debug-keystore.jks
```

Do **not** mix this file with `%USERPROFILE%\.android\debug.keystore` (`android` / `androiddebugkey`) unless you also point Appium at that SDK debug store. Mismatched certificates break the Espresso server session.

---

### `copy-apk.bat` cannot find the APK

**Symptom:** `[ERROR] APK not found at ...\app\debug\app-debug.apk`. Explorer under `app\build\outputs` only shows test folders, no `apk\`.

**Cause:** The APK was never built, **or** Gradle wrote it to `app\build\outputs\apk\debug\` while the script expects `app\debug\` (Android Studio **Build APK**).

**Fix:**

1. Set `ANDROID_PROJECT` in `copy-apk.bat` to your [Taxi](https://github.com/cristianopcortez/Taxi) clone (example: `C:\workspaces\AndroidStudioProjects\Taxi`).
2. Generate a **debug** APK from that project, signed with `native-appium-demo\config\my-debug-keystore.jks` (same file Appium mounts).
3. Confirm `Taxi\app\debug\app-debug.apk` **or** copy from `app\build\outputs\apk\debug\`.
4. Run `copy-apk.bat` from `native-appium-demo`.

Studio **Generate Signed APK** must use that `config\*.jks`, not `Documents\Taxi\my-debug-keystore.jks`. Espresso rebuilds a test APK; certificates must match.

The `.jks` is gitignored (`config/*.jks`). Keep it local. Defaults in `AndroidDriverManager` are alias `my-debug-alias` and password `mypassword` unless you override `KEYSTORE_*` env vars.

---

### TestNG: 2 pass, 3 skip — thought it was a new intermediate screen

**Symptom:** `SessionNotCreatedException` / `ConnectException` on `RemoteWebDriver`. Suite summary like `Passes: 2, Skips: 3`. Stack starts at `WebDriverFactory.createChromeDriver` / `ChromeTest` / `BaseMixedDriverTest`. JVM has `-DSELENIUM_REMOTE_URL=http://localhost:4444/wd/hub`.

**Cause:** Not the Android gate/splash. Android tests already reached `.MainActivity`. Chrome tests talk to **Selenium Grid on 4444**. That container is Compose profile `web`. If it is down, TestNG **skips** those methods after a config failure.

**Fix (Phase 0, host Chrome):** remove `SELENIUM_REMOTE_URL` from the IntelliJ TestNG run (VM options / Parameters / Maven profile `dockerized-web`). Screenshot of VM options can show only `-ea` while the **actual** java command still has `-DSELENIUM_REMOTE_URL`.

**Fix (Chrome in Docker):** `docker compose --profile web up -d`, wait until `http://localhost:4444/status` is ready, then run with that `-D` flag.

A real intermediate-screen failure would be Android asserting `travelRequestTitle` / “Travel Request”, not Chrome `ConnectException`.

---

## Phase 1 — kind on Docker Desktop

### Docker Desktop Kubernetes options

Use: **Enable Kubernetes**, provisioning **kind**, **1 node**, version as offered (e.g. 1.36.1). Do **not** pick kubeadm or extra nodes on a laptop that also runs an emulator. Leave **Show system containers** off.

`kubectl get nodes` should show `desktop-control-plane` `Ready`. Stop Compose (`docker compose --profile web down`) so two emulators are not competing for RAM.

### Close other RAM-heavy programs (before `docker save` and the emulator)

The kind node, a ~4 GiB image tar, `ctr import`, and the Android emulator in the Pod all share the same Windows machine. This session ran out of memory with IntelliJ IDEA and Android Studio still open.

**Before** `docker save` / `docker cp` / `ctr import` / waiting for Android home in noVNC:

- Close **IntelliJ IDEA** and **Android Studio**.
- Close extra Chrome windows if you can.
- Keep Compose **down** (no second emulator).
- Do **not** retry the PowerShell `docker save | docker exec` pipe; use the file-based import below even after freeing RAM.

You can reopen the IDEs after the image is imported and the Pod is `Running`, if the laptop still has headroom.

---

### `kind` is not recognized

**Symptom:** PowerShell `kind : O termo 'kind' não é reconhecido`.

**Cause:** Docker Desktop **runs** a kind cluster. It does **not** install the `kind` CLI. `kubectl` is enough.

**Fix:** do not install kind unless you want it. Load the image with `docker` + `ctr` on the node container `desktop-control-plane` (same name as the node).

---

### Pipe `docker save | docker exec ... ctr import` — out of memory

**Symptom:** `Memória insuficiente para continuar a execução do programa` / `NativeCommandFailed`. Image is ~16 GiB virtual (`docker images`), tar on disk ~4.3 GiB.

**Cause:** PowerShell pipes are not a raw byte stream. Buffering a multi-gigabyte tar blows RAM. Closing IDEs (section above) helps; **retrying the same pipe will fail again**.

**Fix:** write a file, then copy, then import. `docker save -o` can run from **any** directory (`$env:TEMP` is already absolute):

```powershell
docker save native-appium-demo-android:latest -o $env:TEMP\native-appium.tar
```

Need ~5+ GiB free on `C:`. The save takes many minutes. Do **not** delete this tar until import succeeds.

---

### `ctr: open /tmp/native-appium.tar: no such file or directory`

**Symptom:** `docker cp ... desktop-control-plane:/tmp/native-appium.tar` reports success (e.g. 4.56 GB) then `ctr import /tmp/...` cannot see the file.

**Cause:** on the kind node, `/tmp` is a **tmpfs**. `docker cp` writes **under** that mount; `ctr` lists the empty tmpfs.

**Fix:** copy to a path that is not `/tmp` (repo root of the node). Do **not** delete `%TEMP%\native-appium.tar` first — that is the source.

```powershell
docker exec desktop-control-plane rm -f /tmp/native-appium.tar
docker cp $env:TEMP\native-appium.tar desktop-control-plane:/native-appium.tar
docker exec desktop-control-plane ls -lh /native-appium.tar
docker exec desktop-control-plane ctr -n k8s.io images import /native-appium.tar
```

Import can take ~6 minutes. `Importing ... 0.0 B/s` at the end is a ctr progress quirk. Confirm:

```powershell
docker exec desktop-control-plane ctr -n k8s.io images ls | findstr -i native
```

Expect `docker.io/library/native-appium-demo-android:latest` (matches the Deployment). Then free space:

```powershell
docker exec desktop-control-plane rm -f /native-appium.tar
```

Optional fallback (**cmd.exe**, not PowerShell):

```bat
docker exec -i desktop-control-plane ctr -n k8s.io images import - < %TEMP%\native-appium.tar
```

---

### `kubectl apply -f e2e/`: namespace created, Deployment/Service `namespaces "e2e" not found`

**Cause:** apply on a directory is alphabetical. `appium-*.yaml` ran before `namespace.yaml` was ready (or in parallel).

**Fix:** namespace file is `e2e/00-namespace.yaml` so it sorts first. If you already saw `namespace/e2e created`, apply again:

```powershell
kubectl apply -f e2e/
kubectl -n e2e get pods -w
```

---

### `kubectl cp`: `one of src or dest must be a local file specification`

**Cause:** on Windows, `C:\...` is parsed as remote `pod=C` + path. Both arguments look remote.

**Fix:** `cd` into the folder and use a relative source (no drive letter). Re-set `$pod` in that shell:

```powershell
$pod = kubectl -n e2e get pod -l app=appium-emulator -o jsonpath="{.items[0].metadata.name}"

cd C:\workspaces\JavaProjects\native-appium-demo\apks
kubectl -n e2e cp .\app-debug.apk "${pod}:/home/androidusr/apks/app-debug.apk"

cd C:\workspaces\JavaProjects\native-appium-demo\config
kubectl -n e2e cp .\my-debug-keystore.jks "${pod}:/home/androidusr/config/my-debug-keystore.jks"

kubectl -n e2e exec $pod -- ls -lh /home/androidusr/apks /home/androidusr/config
```

Expect `app-debug.apk` (~24M) and `my-debug-keystore.jks`. `emptyDir` is wiped if the Pod restarts — copy again.

---

### Pod `OOMKilled` after many minutes `Running`

**Symptom:** `kubectl -n e2e get pods -w` stays `1/1 Running` (10–30 min), then `0/1 OOMKilled`, then `Running` with `RESTARTS 1`.

**Cause:** the kubelet killed the container for exceeding its **memory limit**. The emulator plus a large tmpfs `/dev/shm` (memory-backed `emptyDir`) both count toward that limit. On Windows kind this is expected under software rendering; it is not a failed `kubectl apply`.

**Fix:**

1. Confirm: `kubectl -n e2e describe pod -l app=appium-emulator` — look for `OOMKilled` / `Last State`.
2. Raise Docker Desktop **Memory** if the VM is tight; keep IDEs closed while the emulator is up.
3. This repo now uses a **6Gi** container limit and **512Mi** `/dev/shm` (was 4Gi + 2Gi shm). Apply and wait for a new Pod:

```powershell
cd C:\workspaces\K8sProjects\k8s-mobile-e2e-lab
kubectl apply -f e2e/
kubectl -n e2e get pods -w
```

4. **Re-copy APK and keystore** into the **new** Pod name (`emptyDir` is empty again). Ctrl+C the old `port-forward` (it will error or hang on the dead Pod) and start a new one against `svc/appium`. Details in the two sections below.

A rolling update looks like **two** rows (`Running` + `Terminating`). That is one new emulator replacing the old one, not two AVDs you should keep. Wait until only the new name is `Running`, then copy files. `get pods -w` reprinting the **same** name with a newer AGE is still one Pod.

If it `OOMKilled` again (this lab: still killed at **~45 min** on the **6Gi** limit during `mvn test`), stop raising YAML limits on Windows kind. The honest result is: the cluster **schedules** Appium and noVNC can work for a while; the AVD + Espresso rebuild does not stay within a laptop kind node. Next step is a Linux VM with KVM (or Compose on the host, which already passed Phase 0), not another `kubectl apply` on this node.

To halt the restart loop so it stops eating RAM:

```powershell
kubectl -n e2e scale deploy/appium-emulator --replicas=0
```

---

### Which PowerShell windows to leave open

Use **three** terminals. Closing the wrong one drops the tunnel or hides `OOMKilled`.

| Window | Command | Keep it open? |
|---|---|---|
| **A — Pod watch** | `kubectl -n e2e get pods -w` | Yes, until you are done. This is how you see `OOMKilled`, `RESTARTS`, `Terminating`, or a new Pod name. The same name printed twice is AGE updating, not a second emulator. |
| **B — Port-forward** | `kubectl -n e2e port-forward svc/appium 4723:4723 6080:6080` | Yes, the whole time you use noVNC or `mvn test`. Ctrl+C stops `localhost:4723` / `:6080`. After any Pod **restart or replace**, this process dies or forwards to nothing — start it again in this window. |
| **C — Copy / tests / logs** | `kubectl cp`, `kubectl exec ls`, `kubectl logs`, `mvn test` | No. Run, finish, reuse. After memory kill or rolling update, run **`cp` again here** before `mvn test`. |

Browser noVNC is not a terminal: it works only while **B** is forwarding (or **B2** if you use the LAN layout in [runbook step 5](runbook.md#5-port-forward-required-leave-it-running)).

---

### noVNC from another computer on the LAN

**Symptom:** `http://<lan-ip>:6080/` on another laptop does not load, but `kubectl port-forward` is running on the Docker/kubectl host.

**Cause:** The default forward binds **6080** only on `127.0.0.1`. Other machines never reach it. The Service is `ClusterIP`, not a published NodePort on `192.168.x.x`.

**Fix:** On the host that runs `kubectl`, **stop** the combined command if it is still running (`4723:4723 6080:6080`). Do **not** add `--address 0.0.0.0` for `6080` in the same session as that combined command — both forward port **6080** and the second process fails.

Use two windows (full steps in [runbook step 5](runbook.md#5-port-forward-required-leave-it-running)):

| Window | Command | Purpose |
|---|---|---|
| **B1** | `kubectl -n e2e port-forward svc/appium 4723:4723` | `mvn test` → `http://localhost:4723` on the kubectl host |
| **B2** | `kubectl -n e2e port-forward --address 0.0.0.0 svc/appium 6080:6080` | noVNC on `http://<lan-ip>:6080/` from any PC on the LAN |

Remote screen only (no tests yet): **B2** alone is enough. Before `mvn test`, start **B1** as well.

Allow inbound **TCP 6080** on Windows Firewall on the kubectl host. After Pod restart or OOM, restart **every** port-forward window you use (**B**, or **B1** + **B2**), then copy APK/keystore again.

---

### After OOM, restart, or rolling update: `cp` + new port-forward

Do this whenever the Pod **name** changes, `RESTARTS` increases, or you applied a new Deployment:

1. Window **A**: wait until a single Pod is `1/1 Running` (no `Terminating` twin).
2. Window **C** — refresh the name and copy. Prefer:

```powershell
cd C:\workspaces\K8sProjects\k8s-mobile-e2e-lab
.\scripts\copy-apk-and-keystore-to-pod.bat
```

Or the same `kubectl cp` steps by hand (Windows: relative paths only):

```powershell
$pod = kubectl -n e2e get pod -l app=appium-emulator -o jsonpath="{.items[0].metadata.name}"
echo $pod

cd C:\workspaces\JavaProjects\native-appium-demo\apks
kubectl -n e2e cp .\app-debug.apk "${pod}:/home/androidusr/apks/app-debug.apk"

cd C:\workspaces\JavaProjects\native-appium-demo\config
kubectl -n e2e cp .\my-debug-keystore.jks "${pod}:/home/androidusr/config/my-debug-keystore.jks"

kubectl -n e2e exec $pod -- ls -lh /home/androidusr/apks /home/androidusr/config
```

3. Window **B** (or **B1** + **B2** if you use LAN noVNC): Ctrl+C each forward, then start the same layout as [runbook step 5](runbook.md#5-port-forward-required-leave-it-running). Default:

```powershell
kubectl -n e2e port-forward svc/appium 4723:4723 6080:6080
```

Wait until you see `Forwarding from 127.0.0.1:4723`. Then reload http://localhost:6080 (or the LAN URL if you use **B2**).

---

### How long to wait for Android home in noVNC

`1/1 Running` only means the container process is up. The AVD can take much longer (no KVM, `swiftshader`).

| Time on http://localhost:6080 | What to do |
|---|---|
| 0–5 min | Normal (black screen, boot animation). Keep **B** forwarding. |
| 5–15 min | Still reasonable on Windows kind. |
| 15–25 min | Check window **A** for `OOMKilled`. `kubectl -n e2e logs deploy/appium-emulator --tail=80` in **C**. |
| Over ~30 min with no launcher | Stop waiting; treat “Pod + Service work, AVD may not” as the lab result. |

Do not start Compose or IntelliJ/Android Studio while waiting.

---

### Why `kubectl cp` and `port-forward` at all?

Compose bind-mounts Windows folders into the container. kind cannot do that. APK and keystore start empty until `kubectl cp`.

Appium (`4723`) and noVNC (`6080`) live on the cluster network. `kubectl port-forward svc/appium 4723:4723 6080:6080` must **stay running**. Browser: http://localhost:6080. Tests:

```powershell
cd C:\workspaces\JavaProjects\native-appium-demo
$env:APPIUM_SERVER_URL="http://localhost:4723"
mvn test
```

Leave `SELENIUM_REMOTE_URL` unset (no Chrome grid in this cluster yet). Emulator home on software rendering (`swiftshader`, no `/dev/kvm`) can take many minutes or stay unusable — that is expected on Windows kind.

---

## What we did *not* copy from the Kubernetes course YAML

`appium-android-node-with-emulator-budtmo-deployment.yaml` requires KVM `nodeAffinity` and `/dev/kvm`. On Docker Desktop Windows the Pod would never schedule (or would crash). This lab’s Deployment matches Compose env (`privileged`, ports, software GPU) **without** those constraints.
