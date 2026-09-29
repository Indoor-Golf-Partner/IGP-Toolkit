Setting up the igp_images SSH key
==================================

Create Restore USB (Modules\Tools\CreateRestoreUsb.ps1) needs the igp_images
private key to connect to deploy.igpartner.dk over SFTP. That key is never
stored in this repo - it's public on GitHub, and the key would give anyone
pull access to the deploy server. It has to be placed by hand, once, on the
master PC (every cloned machine inherits it automatically from there, same
as everything else in the Clonezilla deployment workflow - see the master
PC / cloning notes elsewhere in the project for that part).

Steps:

1. Get the igp_images private key file from wherever it's currently kept.
2. Copy it to `C:\ProgramData\Indoor Golf Partner\ssh\igp_images` (no file
   extension). Create the folder if it doesn't exist yet - or just run
   Create Restore USB once; it creates the folder automatically (with
   locked-down permissions) and tells you this exact path if the key is
   missing.
3. Run Create Restore USB again. It detects the key and automatically
   locks its permissions down to SYSTEM and Administrators only via
   icacls - you don't need to run any permission commands yourself.

That last step matters more than it sounds: Windows' OpenSSH client
refuses to use a private key file that other accounts can read
("UNPROTECTED PRIVATE KEY FILE"), so this isn't just tidiness - it's
required for the connection to work at all.

The known_hosts file in this same folder pins deploy.igpartner.dk's public
host keys, so the toolkit can verify the server's identity without an
interactive prompt or disabling host-key checking. That file only contains
the server's public keys, so - unlike the private key above - it's safe to
have committed in this public repo.
