# Mail

Email lives under `SPC a e`: mu4e reads a Maildir that `mbsync` fills from Proton Mail Bridge, and `smtpmail` sends through Bridge's SMTP port.

## Setup checklist

1. Run Proton Mail Bridge (needs a paid Proton plan and gnome-keyring).
2. Put the Bridge password in `~/.authinfo.gpg` as two lines, for ports 1143 (IMAP) and 1025 (SMTP). `smtpmail` and mbsync both read it from there.
3. `cp mbsyncrc.example ~/.mbsyncrc`.
4. Set `rata-mail-address` in `local.el`.
5. Install `mu` and `mbsync`.

`SPC a e d` (`rata-mail-doctor`) reports each piece as present or missing and prints the exact commands for your host.

## Notes

- mu4e is not installed through elpaca: its Lisp is version-locked to the `mu` binary, so the config finds it beside that binary and skips the mail block when `mu` is absent. The leader keys stay live and say what is missing.
- Proton specifics are already configured: Bridge files sent mail itself, "All Mail" and "Labels/*" are excluded in the mbsync template because they repeat the same messages, and Bridge's self-signed certificate is trusted so sending never prompts.
- `rata-mail-update` checks that Bridge is listening before running mbsync.
