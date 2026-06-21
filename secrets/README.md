# ARM NDA GPU blobs

The Mali GPU userland drivers (Vulkan + OpenCL) for felix ship under an **ARM
NDA** and cannot be committed in the clear. This directory holds them as an
[age](https://age-encryption.org)-encrypted, rootfs-rooted overlay tarball.

Access uses age's **multi-recipient** mode: the blob is encrypted to every
public key in `recipients.txt`, and each builder decrypts with their **own**
private key. **No private key is ever shared.**

| File | Tracked? | What it is |
| --- | --- | --- |
| `arm-mali-blobs.tar.age` | ✅ committed | The encrypted blobs (a `.tar.gz` rooted at the rootfs `/`). |
| `recipients.txt` | ✅ committed | The public keys allowed to decrypt (SSH or age pubkeys — public, safe to commit). |
| *(your private key)* | ❌ never in repo | e.g. `~/.ssh/id_ed25519`. Stays on your machine. |

## How a builder decrypts

Nothing to install — if your **SSH public key** is in `recipients.txt`, your
existing `~/.ssh/id_ed25519` (or `id_rsa`) just works. `just all` runs the
install automatically. To decrypt manually:

```sh
age -d -i ~/.ssh/id_ed25519 secrets/arm-mali-blobs.tar.age | tar -tzvf -   # list
age -d -i ~/.ssh/id_ed25519 secrets/arm-mali-blobs.tar.age | tar -xzf - -C out  # extract
```

Point at a specific key with `ARM_NDA_KEY=/path/to/key just all` (overrides the
SSH-key default). A passphrase-protected SSH key will prompt on decrypt — use an
unencrypted build key, or `ARM_NDA_KEY` pointing at one, for unattended builds.

## Build behaviour (warn, never fail)

`just all` runs the `install_arm_blobs` stage on **every** build. If you're not
a recipient (or the blob/key is absent), it prints a loud yellow warning and
continues **without** the GPU drivers — it does not fail. Get added as a
recipient (below), pull the re-packed blob, and the next `just all` picks it up
automatically (the stage is not sentinel-gated, so there's nothing to reset).

## Granting / revoking access

Add (or remove) a builder's **public** key line in `recipients.txt`, then
re-pack so the blob is re-encrypted to the new recipient set:

```sh
# get the new builder's pubkey (they run this and send you the output):
cat ~/.ssh/id_ed25519.pub

# add the line to secrets/recipients.txt, then:
just pack_arm_blobs <staging-dir>          # re-encrypts to everyone in recipients.txt
git add secrets/recipients.txt secrets/arm-mali-blobs.tar.age
```

Removing a line revokes them from **future** blobs. The committed history still
contains the old blob, so for a true revocation also rotate the NDA content
(re-pack from a fresh source) — same caveat as any committed secret.

## Packing the blobs

Stage the `.so` files **in a tree that mirrors the on-device rootfs**, then
encrypt it. The tree is extracted at `/` in the rootfs:

```
staging/
  usr/lib/aarch64-linux-gnu/libmali.so          # the driver .so(s)
  etc/OpenCL/vendors/mali.icd                    # one line: /usr/lib/aarch64-linux-gnu/libmali.so
  usr/share/vulkan/icd.d/mali_icd.json           # Vulkan ICD manifest pointing at the .so
```

```sh
just pack_arm_blobs staging      # -> secrets/arm-mali-blobs.tar.age
git add secrets/arm-mali-blobs.tar.age
```

The `.icd` / `.json` manifests are what make the loader actually *find* a Vulkan
ICD / OpenCL platform; if you only ship the `.so` it installs but nothing loads
it. Include them in the staging tree so they're encrypted alongside.
