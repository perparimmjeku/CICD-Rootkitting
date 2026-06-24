<p align="center">
  <img src="https://github.com/user-attachments/assets/726d7c51-90da-493f-8776-701723b669cd" alt="Cyber Academy" width="250">
</p>



# CI/CD Rootkit Lab — *When the Build System Betrays You*

[![supply-chain-demo](../../actions/workflows/supply-chain-demo.yml/badge.svg)](../../actions/workflows/supply-chain-demo.yml)


A small, self-contained lab that demonstrates a **build-time supply-chain attack** on a
real CI/CD pipeline: a clean Go web server, a clean git history, and a passing security
scan — yet the binary that comes out of the pipeline is **backdoored**.

The malicious code is **never in the repository**. It lives inside a "trusted" CI
builder image (`company/go-builder:latest`) and is compiled in silently at build time,
then erased from the source tree before anyone can see it. Same source, same commit,
SAST passed — different binary.

This is the same pattern behind **SolarWinds (2020)**, **XZ Utils (2024)** and the
**tj-actions (2025)** incident: the attacker never touches the code under review; they
poison the thing that builds it.

> [!WARNING]
> **For education and authorized testing only.** This repo reproduces a known attack
> class against build systems so engineers can understand and defend against it. Run it
> on a machine/account you own. Do **not** deploy the produced artifacts or point the
> backdoor at anything you don't control.
>
> **Safe by default:** servers bind to `127.0.0.1` only, the backdoor's remote command
> execution is a **dry-run** unless you set `LAB_ALLOW_RCE=1`, and the token is read from
> the environment (not hardcoded). See [`SECURITY.md`](SECURITY.md).

---

## ▶ Run it on GitHub Actions (the main event)

The attack and its defense run on **GitHub-hosted runners** — this is not a local-only
script. The whole point is to watch it happen in real CI.

### Fork-and-run walkthrough (≈2 minutes)

1. **Fork the repo.** Click **Fork** (top-right of this page) → **Create fork**. You now
   have your own copy at `github.com/<you>/CICD-Rootkitting`.
2. **Enable Actions on your fork.** Open the **Actions** tab. Forks have workflows
   disabled by default, so click the green **"I understand my workflows, enable them"**
   button. (You only do this once.)
3. **Trigger the pipeline**, either way:
   - In the **Actions** tab, select **supply-chain-demo** on the left → **Run workflow**
     → **Run workflow** (uses the `workflow_dispatch` trigger), **or**
   - make any commit (e.g. edit the README) — it runs automatically on push.
4. **Watch the three stages run** (click the run to open it):

   | Stage | What you see |
   |---|---|
   | **1 · Unit tests** | The application source is clean — green. |
   | **2 · Naive pipeline** | SAST passes, the build succeeds, and it **uploads a release artifact** — built on GitHub's runner, and **backdoored**. The victim's pipeline, unaware. |
   | **3 · Hardened gate** | An independent clean reference build + the reproducible-build gate **detect the tampering** and block it. |

5. **See the proof.** Open the run's **Summary** for a plain-English readout of each
   stage. Scroll to **Artifacts**, download **`release-binary`** (the binary GitHub's
   "clean" pipeline produced), and confirm the backdoor is baked in:

   ```bash
   strings server | grep __backdoor__   # present — in a binary built by trusted CI
   ```

That's the whole lesson in real CI: review and SAST pass, the artifact ships backdoored,
and only an independent reproducible-build check catches it.

> **Two workflows, on purpose:** the live pipeline is
> [`.github/workflows/supply-chain-demo.yml`](.github/workflows/supply-chain-demo.yml)
> (repo root — this is the one that runs). A second, *illustrative* file,
> [`clean_app/.github/workflows/build.yml`](clean_app/.github/workflows/build.yml), is the
> *victim's* naive pipeline as told in the story, with the hardened, digest-pinned fix as
> a commented job. GitHub only executes root-level workflows, so that one never runs —
> that's intended.

---

## How it works (30 seconds)

1. The pipeline builds inside a container: `container: image: company/go-builder:latest`.
2. Inside that image the real `go` compiler is renamed to `go.real` and replaced by a
   wrapper script.
3. On every `go build`, the wrapper copies a payload (`hook.go`) into the source
   directory, runs the real build (Go compiles **all** `.go` files in the package),
   then deletes the payload.
4. The backdoored binary registers a hidden, token-gated endpoint — `404` for everyone
   without the secret header, remote command execution for anyone with it (gated behind
   `LAB_ALLOW_RCE=1` in this lab).
5. PR diff, SAST, git log and CI logs all look clean. The source tree is pristine again.

See [`compromised_runner/Dockerfile.builder`](compromised_runner/Dockerfile.builder) and
[`compromised_runner/hook.go`](compromised_runner/hook.go) for the actual payload.

---

## Reproduce locally

Prefer the terminal? The same attack runs on your machine.

**Prerequisites:** Docker (running) and git — every build happens *inside* Docker, so you
do **not** need Go installed locally. **Works on macOS and Linux**; the scripts
auto-detect your OS and CPU (`GOOS`/`GOARCH`), no edits required.

> On Linux, Docker writes the built binaries as `root`; use `sudo rm` if you need to
> clean them up. You may also need to be in the `docker` group (or use `sudo`).

```bash
# 0. Get the code
git clone https://github.com/perparimmjeku/CICD-Rootkitting.git
cd CICD-Rootkitting

# 1. One-time setup — builds the poisoned image, inits git, builds both binaries
bash setup.sh

# 2. The two binaries are built from identical source but their hashes MUST differ
shasum -a 256 build_clean/server build_compromised/server

# 3. Run a guided demo
bash demo_compare.sh          # full walkthrough (recommended)
bash demo_reveal_runner.sh    # reveal the wrapper + payload inside the trusted image
bash demo_provenance_fail.sh  # how reproducible builds / SLSA L3 / cosign catch it
bash demo_clean.sh            # clean server only        → http://localhost:8080
bash demo_compromised.sh      # backdoored server only   → http://localhost:8081
```

### Trigger the backdoor (servers running)

```bash
curl http://localhost:8080/__backdoor__                                    # clean → 404
curl -H 'X-Backdoor-Token: secret' http://localhost:8081/__backdoor__      # → backdoor_active

# Remote command execution. The guided demos enable this (LAB_ALLOW_RCE=1) on a
# loopback-only server; without the opt-in it returns a safe dry-run.
curl -H 'X-Backdoor-Token: secret' 'http://localhost:8081/__backdoor__?cmd=id'
curl -H 'X-Backdoor-Token: secret' 'http://localhost:8081/__backdoor__?cmd=env'   # credential-exfil sim

# The token is configurable (not hardcoded):
LAB_BACKDOOR_TOKEN=hunter2 LAB_ALLOW_RCE=1 PORT=8081 ./build_compromised/server
```

---

## Tests & verification

```bash
# Unit tests — the application source is clean (run in Docker; no local Go needed)
docker run --rm -v "$PWD/clean_app":/app -w /app golang:1.22-alpine go test ./...

# Integration tests — full end-to-end invariants (run setup.sh first)
bash tests/run_tests.sh

# Reproducible-build gate — the detection control, drop it into any deploy pipeline
bash verify_reproducible.sh build_clean/server build_compromised/server   # exits 1 on tamper
```

The same unit tests and reproducible-build gate run automatically in CI (see above).

---

## Defenses — mechanisms that each catch this

| Defense | What it does |
|---|---|
| **Reproducible builds** | Rebuild the same source on an independent toolchain and compare hashes. Same source, different binary → stop. Implemented here as [`verify_reproducible.sh`](verify_reproducible.sh) and enforced in CI. |
| **SLSA L3 provenance** | Platform-generated attestation records the full build environment, including the runner image digest — which won't match the expected base. |
| **Digest pinning** | Pin `golang@sha256:…` instead of a mutable tag. The pipeline fails the moment someone swaps the image. |
| **Signature verification** | Keyless Sigstore signing at upload, `cosign verify-blob` at deploy. A modified runner won't match the expected OIDC identity. |
| **Scan the builders** | `trivy image company/go-builder:latest`, plus post-build binary SCA with `syft` + `grype`. |
| **Constrain the runner** | Ephemeral runners and a read-only source mount, so a wrapper physically cannot drop a file into your package. |

**Monday-morning questions:** Who has push access to your builder images? When did you
last look inside one? Do your artifact hashes match across two independent builds? Are
your CI images pinned to a digest, or to `latest`?

---

## Project layout

```
.github/workflows/
  supply-chain-demo.yml     the REAL CI — attack on GitHub runners, then detection
clean_app/                  the clean Go web server (the "innocent" application)
  main.go                   plain HTTP server — no backdoor; loopback-bound
  main_test.go              unit tests proving the source is clean
  .github/workflows/        the victim's naive pipeline (illustrative) + hardened fix
compromised_runner/         the attacker's side
  Dockerfile.builder        builds company/go-builder:latest with the go wrapper
  hook.go                   the payload injected at compile time (configurable token, RCE opt-in)
  build_and_inject.sh       builds the compromised binary via the poisoned image
verify_reproducible.sh      reproducible-build verification gate (the detection control)
tests/run_tests.sh          end-to-end integration tests
setup.sh                    one-time setup: image + git + both binaries
demo_*.sh                   the live demo scripts
presenter.html              the visual walkthrough (open in a browser)
SECURITY.md                 safety boundaries & authorized-use policy
```

---

## License

[MIT](LICENSE) — for education and authorized testing only (see the note at the bottom
of the license file).

---

*Originally built for a BSides Porto 2026 talk. Further reading: [slsa.dev](https://slsa.dev),
[sigstore.dev](https://www.sigstore.dev).*

---

## How it works (30 seconds)

1. The pipeline builds inside a container: `container: image: company/go-builder:latest`.
2. Inside that image the real `go` compiler is renamed to `go.real` and replaced by a
   wrapper script.
3. On every `go build`, the wrapper copies a payload (`hook.go`) into the source
   directory, runs the real build (Go compiles **all** `.go` files in the package),
   then deletes the payload.
4. The backdoored binary registers a hidden, token-gated endpoint — `404` for everyone
   without the secret header, remote command execution for anyone with it (gated behind
   `LAB_ALLOW_RCE=1` in this lab).
5. PR diff, SAST, git log and CI logs all look clean. The source tree is pristine again.

See [`compromised_runner/Dockerfile.builder`](compromised_runner/Dockerfile.builder) and
[`compromised_runner/hook.go`](compromised_runner/hook.go) for the actual payload.

---

## Reproduce locally

Prefer the terminal? The same attack runs on your machine.

**Prerequisites:** Docker (running) and git — every build happens *inside* Docker, so you
do **not** need Go installed locally. **Works on macOS and Linux**; the scripts
auto-detect your OS and CPU (`GOOS`/`GOARCH`), no edits required.

> On Linux, Docker writes the built binaries as `root`; use `sudo rm` if you need to
> clean them up. You may also need to be in the `docker` group (or use `sudo`).

```bash
# 1. One-time setup — builds the poisoned image, inits git, builds both binaries
bash setup.sh

# 2. The two binaries are built from identical source but their hashes MUST differ
shasum -a 256 build_clean/server build_compromised/server

# 3. Run a guided demo
bash demo_compare.sh          # full walkthrough (recommended)
bash demo_reveal_runner.sh    # reveal the wrapper + payload inside the trusted image
bash demo_provenance_fail.sh  # how reproducible builds / SLSA L3 / cosign catch it
bash demo_clean.sh            # clean server only        → http://localhost:8080
bash demo_compromised.sh      # backdoored server only   → http://localhost:8081
```

### Trigger the backdoor (servers running)

```bash
curl http://localhost:8080/__backdoor__                                    # clean → 404
curl -H 'X-Backdoor-Token: secret' http://localhost:8081/__backdoor__      # → backdoor_active

# Remote command execution. The guided demos enable this (LAB_ALLOW_RCE=1) on a
# loopback-only server; without the opt-in it returns a safe dry-run.
curl -H 'X-Backdoor-Token: secret' 'http://localhost:8081/__backdoor__?cmd=id'
curl -H 'X-Backdoor-Token: secret' 'http://localhost:8081/__backdoor__?cmd=env'   # credential-exfil sim

# The token is configurable (not hardcoded):
LAB_BACKDOOR_TOKEN=hunter2 LAB_ALLOW_RCE=1 PORT=8081 ./build_compromised/server
```

---

## Tests & verification

```bash
# Unit tests — the application source is clean (run in Docker; no local Go needed)
docker run --rm -v "$PWD/clean_app":/app -w /app golang:1.22-alpine go test ./...

# Integration tests — full end-to-end invariants (run setup.sh first)
bash tests/run_tests.sh

# Reproducible-build gate — the detection control, drop it into any deploy pipeline
bash verify_reproducible.sh build_clean/server build_compromised/server   # exits 1 on tamper
```

The same unit tests and reproducible-build gate run automatically in CI (see above).

---

## Defenses — mechanisms that each catch this

| Defense | What it does |
|---|---|
| **Reproducible builds** | Rebuild the same source on an independent toolchain and compare hashes. Same source, different binary → stop. Implemented here as [`verify_reproducible.sh`](verify_reproducible.sh) and enforced in CI. |
| **SLSA L3 provenance** | Platform-generated attestation records the full build environment, including the runner image digest — which won't match the expected base. |
| **Digest pinning** | Pin `golang@sha256:…` instead of a mutable tag. The pipeline fails the moment someone swaps the image. |
| **Signature verification** | Keyless Sigstore signing at upload, `cosign verify-blob` at deploy. A modified runner won't match the expected OIDC identity. |
| **Scan the builders** | `trivy image company/go-builder:latest`, plus post-build binary SCA with `syft` + `grype`. |
| **Constrain the runner** | Ephemeral runners and a read-only source mount, so a wrapper physically cannot drop a file into your package. |

**Monday-morning questions:** Who has push access to your builder images? When did you
last look inside one? Do your artifact hashes match across two independent builds? Are
your CI images pinned to a digest, or to `latest`?

---

## Project layout

```
.github/workflows/
  supply-chain-demo.yml     the REAL CI — attack on GitHub runners, then detection
clean_app/                  the clean Go web server (the "innocent" application)
  main.go                   plain HTTP server — no backdoor; loopback-bound
  main_test.go              unit tests proving the source is clean
  .github/workflows/        the victim's naive pipeline (illustrative) + hardened fix
compromised_runner/         the attacker's side
  Dockerfile.builder        builds company/go-builder:latest with the go wrapper
  hook.go                   the payload injected at compile time (configurable token, RCE opt-in)
  build_and_inject.sh       builds the compromised binary via the poisoned image
verify_reproducible.sh      reproducible-build verification gate (the detection control)
tests/run_tests.sh          end-to-end integration tests
setup.sh                    one-time setup: image + git + both binaries
demo_*.sh                   the live demo scripts
presenter.html              the visual walkthrough (open in a browser)
SECURITY.md                 safety boundaries & authorized-use policy
```

---

## License

[MIT](LICENSE) — for education and authorized testing only (see the note at the bottom
of the license file).

---

*Originally built for a BSides Porto 2026 talk. Further reading: [slsa.dev](https://slsa.dev),
[sigstore.dev](https://www.sigstore.dev).*
