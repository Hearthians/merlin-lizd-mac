# Share an HPC account using SSH public keys

Send `scripts/hpc-share-access.py` to the account owner. It runs on Linux/macOS with Python 3.6+ and OpenSSH (`ssh-keygen`); no pip packages or administrator access are needed.

## 1. Recipient A sends their public key

On A's computer, show an existing public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

If A does not already have a key, create a dedicated one. Choose a different filename if this already exists, and set a passphrase when prompted:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_hpc -C 'alice-hpc'
cat ~/.ssh/id_ed25519_hpc.pub
```

Send only the `.pub` file or its one-line contents. A keeps the matching private key on their own computer.

## 2. Account owner runs the script inside the target HPC account

Upload the script and A's `.pub` file, log in to the HPC account to be shared, and run:

```bash
python3 hpc-share-access.py add alice --key-file alice.pub
```

Or paste A's complete public key as a single quoted argument:

```bash
python3 hpc-share-access.py add alice --key 'ssh-ed25519 AAAA... alice-hpc'
```

`AAAA...` is a placeholder: replace the entire argument with A's actual public-key line. Use a distinct label for each person/device, such as `alice-laptop`. Add `--dry-run` to preview without changing account files.

The script edits the current Unix user's `~/.ssh/authorized_keys`, keeps other key entries, and saves a private backup before each replacement. It sets `.ssh` to mode `700` and the new key file to `600`. It never uses sudo or copies private keys. A repeated add with the same name/key is harmless; name/key collisions are rejected instead of replacing another authorization.

For several accounts or clusters, log in and repeat this step for each account to be shared. Login nodes with the same home directory normally share the authorized keys; separate HPC2/3/4 homes require separate runs. Their tmux sessions still live on individual nodes.

## 3. A connects using their own private key

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_hpc OWNER_USERNAME@HPC_HOST
```

Use the owner's HPC username and a reachable login hostname/IP. If A supplied `id_ed25519.pub`, use `~/.ssh/id_ed25519` instead. A key passphrase prompt unlocks A's local key; it is not the HPC account password.

A can then save an alias in their own `~/.ssh/config`:

```sshconfig
Host shared-hpc3
    HostName HPC_HOST
    User OWNER_USERNAME
    IdentityFile ~/.ssh/id_ed25519_hpc
    IdentitiesOnly yes
```

Connect with `ssh shared-hpc3`, or select the alias in TmuxHub/VS Code. A should verify the server host-key fingerprint with the owner before accepting it on first connection.

For a route through HPC2, A needs authorization on **both** the HPC2 jump account and the target HPC3 account:

```sshconfig
Host shared-hpc2
    HostName HPC2_HOST
    User HPC2_OWNER_USERNAME
    IdentityFile ~/.ssh/id_ed25519_hpc
    IdentitiesOnly yes

Host shared-hpc3
    HostName HPC3_LOGIN_NODE_IP
    User HPC3_OWNER_USERNAME
    IdentityFile ~/.ssh/id_ed25519_hpc
    IdentitiesOnly yes
    ProxyJump shared-hpc2
```

Use a fixed HPC3 login node when reconnecting to tmux sessions. Campus network/VPN reachability is still required; adding a public key does not fix a blocked SSH port or an unavailable login node. The SSH server must allow public-key login through `~/.ssh/authorized_keys`; site-managed authentication/MFA requirements still apply.

## Manage access

```bash
python3 hpc-share-access.py list
python3 hpc-share-access.py revoke alice --dry-run
python3 hpc-share-access.py revoke alice
```

`list` shows only keys labeled by this script. Revocation removes only that named entry; existing SSH sessions stay connected, and other keys/passwords remain valid. If the same public key is still listed elsewhere in the file, the script reports it. Backups retain the prior authorization state, so restoring a backup may restore revoked keys.

This shares the owner's full Unix account: files, running processes, job submission permissions, and computing quota. Labels help track keys but do not isolate people or enforce a spending limit. Because recipients can also edit account files and credentials, strict separation or reliable per-person revocation requires separate HPC accounts or administrator-managed access.
