# Secrets

Every secret this cluster needs is committed to this repository, encrypted.
There is one exception, described at the bottom. Apart from that, no secret is
ever created by typing `kubectl create secret` at a terminal.

The reason is simple: a secret created by hand exists only in the cluster. It
does not show up in a diff, nobody knows it is there, and the next time the
cluster is rebuilt it is quietly missing. Then something fails at three in the
morning for a reason nobody can see.

Encryption uses [SOPS](https://github.com/getsops/sops) with an
[age](https://github.com/FiloSottile/age) key. Both are pinned in
[`//tools`](../../../tools/README.md).

## The key

The age key for this cluster lives at `~/.config/sops/age/foundry.txt`.

It has two halves. The public half is in `.sops.yaml` at the root of the repo
and is not sensitive; it is what encrypts. The private half decrypts, and it is
the only thing that can.

If you lose the private half, nothing in this repository can be decrypted
again. There is no recovery process and no support line to call. You would have
to generate a fresh key and then rebuild every secret from its original source:
a new GitHub App private key, a new Tailscale OAuth client, a new Cloudflare
token, and so on. Everything still works afterwards, but it is a bad afternoon.

So keep a copy somewhere that is none of the following: this repository, this
laptop, or a backup of the cluster. A backup that dies with the thing it is
backing up is not a backup.

### Where to keep the copy

Apple Passwords works well and is end-to-end encrypted through iCloud Keychain.
There is no way to import a key file, so add it by hand. Put the key on the
clipboard without displaying it:

```
tail -1 ~/.config/sops/age/foundry.txt | tr -d '\n' | pbcopy
```

Then in Passwords.app, add a new entry with the public key as the username, the
private key pasted into the password field, and a note saying what it unlocks.
Clear the clipboard afterwards with `pbcopy < /dev/null`.

Avoid the CSV import path. It needs a plaintext file on disk containing the key,
which is the thing you are trying to avoid.

Any other password manager is fine. So is a printed copy in a drawer; the key is
74 characters.

## Adding a secret

Name the file `*.sops.yaml` and `.sops.yaml` takes care of the rest — you do not
pass recipients on the command line, so you cannot accidentally encrypt to the
wrong key.

Never write the plaintext to disk first. Build the manifest and pipe it straight
into `sops`:

```
kubectl create secret generic NAME \
  --namespace=NAMESPACE \
  --from-file=key=/path/to/secret-file \
  --dry-run=client -o yaml \
| sops --encrypt --input-type yaml --output-type yaml \
       --filename-override infra/platform/COMPONENT/NAME.sops.yaml /dev/stdin \
> infra/platform/COMPONENT/NAME.sops.yaml
```

Then check the result before committing. It should contain a `sops:` block, and
it should not contain anything recognisable:

```
grep -c 'PRIVATE KEY' infra/platform/COMPONENT/NAME.sops.yaml   # expect 0
```

If the secret came from a file, confirm the encrypted copy is a faithful
replacement before you delete the original. Compare hashes rather than reading
them:

```
sops --decrypt FILE.sops.yaml \
  | python3 -c 'import sys,yaml,base64,hashlib; print(hashlib.sha256(base64.b64decode(yaml.safe_load(sys.stdin)["data"]["key"])).hexdigest())'
shasum -a 256 /path/to/original
```

Once those match, delete the original. A private key sitting in `~/Downloads` is
world-readable and gets picked up by whatever syncs that folder.

## Reading and changing a secret

```
sops --decrypt infra/platform/arc/github-app.sops.yaml    # prints it, so be careful where
sops infra/platform/arc/github-app.sops.yaml              # opens an editor, re-encrypts on save
```

Editing in place is better. It never leaves a decrypted file behind.

## What is encrypted

Only the `data` and `stringData` fields. `apiVersion`, `kind`, `metadata` and
the key *names* stay readable.

This is deliberate. Kustomize and Flux can treat these files as ordinary
manifests, and a diff shows that a secret changed without showing what it
changed to. A fully encrypted blob would be opaque to both tooling and review.

## How the cluster decrypts

Flux needs the private half of the age key to decrypt anything, so it lives
in-cluster as a Secret. Flux `Kustomization`s that reference encrypted files
point at it:

```yaml
decryption:
  provider: sops
  secretRef:
    name: sops-age
```

That secret is the one exception to everything above. It cannot be committed
encrypted, because it is the key the cluster would need in order to decrypt it.
So it is created directly, once per cluster:

```
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/foundry.txt
```

That is the whole bootstrap. One command, one secret, and everything else
follows from git.

## Rotating the key

Do this if the private key is exposed, or if someone who had it should no longer
have it.

1. Generate a new key: `age-keygen -o ~/.config/sops/age/foundry-new.txt`
2. Add its public half to `.sops.yaml` alongside the old one.
3. Re-encrypt every secret to both: `sops updatekeys FILE.sops.yaml` for each.
4. Replace the in-cluster `sops-age` secret with the new key and let Flux
   reconcile.
5. Once everything is working, remove the old public key from `.sops.yaml` and
   run `sops updatekeys` again.

Keep both keys valid in the middle steps. If you cut over in one move and
something was missed, the cluster stops being able to decrypt and you find out
from a failing reconcile.

## If a secret leaks

Rotate the secret itself, at the source. Do not try to scrub it from git
history and call it handled.

Anything pushed to a public repository should be assumed copied within minutes.
Revoke the GitHub App key on its settings page and generate a new one. Delete
and recreate the Tailscale OAuth client. Issue a new Cloudflare token. The old
value has to stop working; making it hard to find is not the same thing.

Cleaning history afterwards is fine, but it is tidying, not remediation.

## Rules

- No plaintext secret is ever committed, in any branch, even briefly.
- No secret is created with `kubectl create secret`, except `sops-age`.
- The age private key never enters this repository.
- Secrets are encrypted straight from their source, never via a temporary file.
- Every secret is scoped as narrowly as the tool allows. A token that can do one
  thing to one repository is a much smaller problem when it goes wrong.
